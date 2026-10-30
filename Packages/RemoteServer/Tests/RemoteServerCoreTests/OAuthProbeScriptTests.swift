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
                let probePort = Int.random(in: 30000 ... 60000)
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

                // Wait for the authorize URL the script prints.
                var authorizeURL: String?
                for _ in 0 ..< 300 where authorizeURL == nil {
                    let text = (try? String(contentsOf: output, encoding: .utf8)) ?? ""
                    authorizeURL = text.split(separator: "\n").first { $0.hasPrefix("AUTHORIZE_URL ") }
                        .map { String($0.dropFirst("AUTHORIZE_URL ".count)) }
                    if authorizeURL == nil {
                        try await Task.sleep(for: .milliseconds(100))
                    }
                }
                let start = try #require(authorizeURL, "probe never printed the authorize URL")

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
                var delivered = false
                var lastError = ""
                let loopbackURL = try #require(URL(string: loopback))
                for _ in 0 ..< 25 where !delivered {
                    do {
                        delivered = try await http.get(loopbackURL).status == 200
                    } catch {
                        lastError = "\(error)"
                    }
                    if !delivered {
                        try await Task.sleep(for: .milliseconds(200))
                    }
                }
                #expect(delivered, "\(lastError.prefix(300))")

                for _ in 0 ..< 600 where process.isRunning {
                    try await Task.sleep(for: .milliseconds(100))
                }
                let log = (try? String(contentsOf: output, encoding: .utf8)) ?? ""
                #expect(!process.isRunning)
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
