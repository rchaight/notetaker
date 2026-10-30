import Foundation
import GRDB
import HummingbirdTesting
@testable import RemoteServerCore
import Testing

/// Spec 07 test 13: `scripts/remote-vault/oauth-probe.sh`.
struct OAuthProbeScriptTests {
    static let script = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("scripts/remote-vault/oauth-probe.sh")

    static func which(_ tool: String) -> String? {
        for directory in (ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin").split(separator: ":") {
            let path = "\(directory)/\(tool)"
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }
        return nil
    }

    static var endToEndToolsPresent: Bool {
        ["bash", "curl", "openssl", "nc"].allSatisfy { which($0) != nil }
    }

    @discardableResult
    static func run(_ executable: String, _ arguments: [String],
                    env: [String: String] = [:]) throws -> (Int32, String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging(env) { _, new in new }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    @Test(.enabled(if: which("bash") != nil, "bash is not installed"))
    func scriptParses() throws {
        #expect(FileManager.default.isExecutableFile(atPath: Self.script.path))
        let (status, output) = try Self.run(#require(Self.which("bash")), ["-n", Self.script.path])
        #expect(status == 0, "\(output)")
    }

    @Test(.enabled(if: which("shellcheck") != nil, "shellcheck is not installed"))
    func scriptIsShellcheckClean() throws {
        let (status, output) = try Self.run(#require(Self.which("shellcheck")), [Self.script.path])
        #expect(status == 0, "\(output)")
    }

    @Test(.enabled(if: endToEndToolsPresent, "needs bash, curl, openssl and nc; skipped"))
    func probeRunsEndToEndAgainstTheServerAndFakeGoogle() async throws {
        let clock = TestClock()
        let google = FakeGoogle(clock: clock)
        try await google.run { google in
            let harness = try await OAuthHarness.make(
                google: google, clock: clock, env: ["NR_ALLOW_LOOPBACK": "1"], authPerMinute: 1000
            )
            defer { harness.fixture.cleanUp() }
            try await harness.app().test(.live) { client in
                let base = try "http://localhost:\(#require(client.port))"
                // Below both ephemeral ranges (macOS 49152+, Linux 32768+), so the
                // listener never collides with a client socket's source port.
                let probePort = Int.random(in: 20000 ... 29999)
                let output = FileManager.default.temporaryDirectory
                    .appendingPathComponent("probe-\(UUID().uuidString).log")
                FileManager.default.createFile(atPath: output.path, contents: nil)
                defer { try? FileManager.default.removeItem(at: output) }

                let process = Process()
                process.executableURL = try URL(fileURLWithPath: #require(Self.which("bash")))
                process.arguments = [Self.script.path, base, OAuthHarness.clientID]
                process.environment = ProcessInfo.processInfo.environment.merging([
                    "PROBE_PORT": String(probePort), "PROBE_TIMEOUT": "60",
                ]) { _, new in new }
                let handle = try FileHandle(forWritingTo: output)
                process.standardOutput = handle
                process.standardError = handle
                try process.run()
                defer {
                    if process.isRunning {
                        process.terminate()
                    }
                }

                func log() -> String {
                    (try? String(contentsOf: output, encoding: .utf8)) ?? ""
                }
                // Wait until the script reports its listener is in LISTEN (it checks
                // the socket state, never by connecting) and prints the authorize URL.
                var authorizeURL: String?
                let ready = ContinuousClock.now + .seconds(30)
                while authorizeURL == nil, process.isRunning, ContinuousClock.now < ready {
                    let lines = log().split(separator: "\n")
                    if lines.contains("LISTENING 127.0.0.1:\(probePort)") {
                        authorizeURL = lines.first { $0.hasPrefix("AUTHORIZE_URL ") }
                            .map { String($0.dropFirst("AUTHORIZE_URL ".count)) }
                    }
                    if authorizeURL == nil {
                        try await Task.sleep(for: .milliseconds(50))
                    }
                }
                let start = try #require(authorizeURL, "probe listener never became ready:\n\(log())")

                // Play the browser: /authorize → Google → callback → consent → loopback.
                let http = URLSessionOIDCClient()
                let toGoogle = try await http.get(#require(URL(string: start)))
                #expect(toGoogle.status == 302)
                let googleLocation = try #require(toGoogle.headers["location"])
                let fromGoogle = try await http.get(#require(URL(string: googleLocation)))
                let callback = try #require(fromGoogle.headers["location"])
                    .replacingOccurrences(of: OAuthHarness.publicURL, with: base)
                let page = try await http.get(#require(URL(string: callback)))
                #expect(page.status == 200)
                let html = String(decoding: page.body, as: UTF8.self)
                let marker = try #require(html.range(of: "name=\"consent_token\" value=\""))
                let consentToken = String(html[marker.upperBound...].prefix { $0 != "\"" })
                let consent = try await http.postForm(
                    #require(URL(string: base + "/consent")), [("consent_token", consentToken), ("action", "allow")]
                )
                #expect(consent.status == 302)
                let loopback = try #require(consent.headers["location"])
                #expect(loopback.hasPrefix("http://127.0.0.1:\(probePort)/cb?code="))
                // Deliver the redirect. The listener is already in LISTEN, so the only
                // retryable failure is a refused connection while the script re-arms
                // after a stray connection; anything else fails at once.
                let loopbackURL = try #require(URL(string: loopback))
                var delivery: Result<Int, any Error> = .failure(URLError(.cannotConnectToHost))
                let deliveryDeadline = ContinuousClock.now + .seconds(10)
                while ContinuousClock.now < deliveryDeadline {
                    do {
                        delivery = try await .success(http.get(loopbackURL).status)
                        break
                    } catch let error as URLError where error.code == .cannotConnectToHost {
                        delivery = .failure(error)
                        try await Task.sleep(for: .milliseconds(50))
                    } catch {
                        delivery = .failure(error)
                        break
                    }
                }
                switch delivery {
                case let .success(status):
                    #expect(status == 200, "\(log())")
                case let .failure(error):
                    Issue.record("loopback delivery failed: \(error)\n--- probe log ---\n\(log())")
                }

                for _ in 0 ..< 600 where process.isRunning {
                    try await Task.sleep(for: .milliseconds(100))
                }
                let log = log()
                #expect(!process.isRunning, "probe still running:\n\(log)")
                #expect(process.terminationStatus == 0, "\(log)")
                let lines = log.split(separator: "\n")
                #expect(lines.last == "reuse detected: invalid_grant; family revoked: 401", "\(log)")
                // Nothing but the last four characters of any token was printed.
                let tokens = try await harness.store.withDatabase { db in
                    try String.fetchAll(db, sql: "SELECT hash FROM token")
                }
                #expect(tokens.count == 4) // two pairs: exchange + rotation
                #expect(!log.contains("access_token"))
                for line in lines where !line.hasPrefix("AUTHORIZE_URL ") {
                    var run = 0
                    for scalar in line.unicodeScalars {
                        run = Base64URL.isAlphabet(scalar) ? run + 1 : 0
                        #expect(run < 40, "a token-length secret was printed: \(line.prefix(20))")
                    }
                }
                #expect(harness.events("refresh.reuse").count == 1)
            }
            await harness.mcp.stop()
        }
    }
}
