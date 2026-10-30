import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTesting
@testable import RemoteServerCore
import Testing

/// Critique round 2: every audit-writing path on an unauthenticated request is
/// bounded under flood; the owner's pending sign-in survives junk at the cap
/// rate; X-Forwarded-For is parsed strictly.
struct OAuthFloodTests {
    private func counts(_ harness: OAuthHarness) -> [String: Int] {
        var out: [String: Int] = [:]
        for line in harness.auditLines {
            out[line["event"] as? String ?? "?", default: 0] += 1
        }
        return out
    }

    // MARK: critic experiment A

    @Test func authorizeCapRefusalsAreAuditedOncePerStreak() async throws {
        try await OAuthHarness.run(authPerMinute: 10, workPerMinute: 20) { harness, client in
            var refused = 0
            for _ in 0 ..< 300 {
                if try await harness.authorize(client, .init()).status == .tooManyRequests {
                    refused += 1
                }
            }
            #expect(refused == 280)
            let lines = harness.events("auth.ratelimited").filter { $0["reason"] as? String == "authorizations" }
            #expect(lines.count == 1)
        }
    }

    // MARK: 1000-request floods, one per audit-writing path

    /// Global mode: each flood's audit volume is bounded per event type.
    @Test func everyUnauthenticatedPathIsBoundedUnderFlood() async throws {
        try await OAuthHarness.run(authPerMinute: 10, workPerMinute: 20) { harness, client in
            let n = 1000
            for _ in 0 ..< n { // valid-looking /authorize past the cap
                _ = try await harness.authorize(client, .init())
            }
            for _ in 0 ..< n { // junk /authorize
                _ = try await client.execute(uri: "/authorize?client_id=junk", method: .get)
            }
            for _ in 0 ..< n {
                _ = try await client.execute(uri: "/auth/google/callback?state=junk&code=x", method: .get)
            }
            for _ in 0 ..< n {
                _ = try await harness.consent(client, token: OAuthCrypto.token())
            }
            for _ in 0 ..< n {
                _ = try await harness.refresh(client, OAuthCrypto.token())
            }
            for _ in 0 ..< n {
                _ = try await harness.post(client, "/revoke", [("token", OAuthCrypto.token())])
            }
            for index in 0 ..< n { // /mcp 401s: missing and garbage bearer
                _ = try await harness.mcpStatus(client, index.isMultiple(of: 2) ? nil : "garbage")
            }
            let seen = counts(harness)
            let total = seen.values.reduce(0, +)
            #expect(total <= 200, "\(seen)")
            for (event, count) in seen {
                #expect(count <= 120, "\(event): \(count)")
            }
        }
    }

    /// Per-IP mode with a fresh client IP per request (nothing to tarpit by IP):
    /// the audit log's own per-event cap bounds it, then one summary line.
    @Test func rotatingClientIPsAreBoundedByTheAuditCap() async throws {
        try await OAuthHarness.run(env: ["NR_TRUST_FORWARDED_FOR": "1"], authPerMinute: 10) { harness, client in
            func ip(_ index: Int) -> HTTPFields {
                [HTTPField.Name("X-Forwarded-For")!: "10.\(index / 65536).\(index / 256 % 256).\(index % 256)"]
            }
            for index in 0 ..< 1000 {
                _ = try await harness.post(client, "/token", [("grant_type", "refresh_token")], headers: ip(index))
            }
            for index in 0 ..< 1000 {
                var headers = ip(index)
                headers[.contentType] = "application/json"
                headers[.accept] = "application/json"
                _ = try await client.execute(
                    uri: "/mcp",
                    method: .post,
                    headers: headers,
                    body: ByteBuffer(string: "{}")
                )
            }
            var seen = counts(harness)
            #expect(seen["token.rejected"] == 120)
            #expect(seen["auth.missing"] == 120)
            #expect(seen.values.reduce(0, +) <= 250, "\(seen)")
            // Next window: one summary line per capped event type carries the count.
            harness.clock.advance(61)
            _ = try await harness.post(client, "/token", [("grant_type", "refresh_token")], headers: ip(5000))
            seen = counts(harness)
            let summaries = harness.events("audit.suppressed")
            #expect(summaries.count == 2)
            let suppressed = Dictionary(uniqueKeysWithValues: summaries.compactMap { line in
                (line["reason"] as? String).map { ($0, line["result_count"] as? Int ?? -1) }
            })
            #expect(suppressed["token.rejected"] == 880)
            #expect(suppressed["auth.missing"] == 880)
        }
    }

    @Test func googleExchangeCapRefusalsAreAuditedOncePerStreak() async throws {
        try await OAuthHarness.run(authPerMinute: 10, workPerMinute: 1000, googlePerMinute: 20) { harness, client in
            // Authorizations are plentiful here; only the Google cap holds the line.
            for _ in 0 ..< 1000 {
                let authorize = try await harness.authorize(client, .init())
                guard let location = authorize.headers[.location],
                      let gstate = OAuthHarness.query(location)["state"] else { continue }
                _ = try await client.execute(uri: "/auth/google/callback?state=\(gstate)&code=junk", method: .get)
            }
            let seen = counts(harness)
            #expect(harness.google.counters.token == 20)
            #expect(seen["login.denied"] == 20)
            #expect(harness.events("auth.ratelimited").filter { $0["reason"] as? String == "google_exchange" }
                .count == 1)
            #expect(seen.values.reduce(0, +) <= 250, "\(seen)")
        }
    }

    // MARK: AuditLog bounds (unit)

    @Test func auditLogCapsEachEventTypeAndSummarises() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("audit-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("audit.jsonl")
        let clock = TestClock()
        var limits = AuditLog.Limits()
        limits.linesPerEventPerMinute = 5
        let log = AuditLog(url: url, limits: limits, now: clock.clock)
        for _ in 0 ..< 100 {
            await log.record(AuditEvent(event: "junk"))
            await log.record(AuditEvent(event: "kill")) // never capped
        }
        clock.advance(60)
        await log.record(AuditEvent(event: "other"))
        let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map(String.init)
        #expect(lines.count(where: { $0.contains("\"event\":\"junk\"") }) == 5)
        #expect(lines.count(where: { $0.contains("\"event\":\"kill\"") }) == 100)
        let summary = try #require(lines.first { $0.contains("audit.suppressed") })
        #expect(summary.contains("\"result_count\":95") && summary.contains("\"reason\":\"junk\""))
    }

    @Test func auditLogStopsAtItsSizeCeilingAndResumesAfterRotation() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("audit-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("audit.jsonl")
        var limits = AuditLog.Limits()
        limits.maxFileBytes = 4000
        limits.linesPerEventPerMinute = 100_000
        let log = AuditLog(url: url, limits: limits)
        for index in 0 ..< 500 {
            await log.record(AuditEvent(event: "line", reason: "n\(index)"))
        }
        let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int ?? .max
        #expect(size <= 4000 + 200)
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.components(separatedBy: "audit.truncated").count == 2) // exactly one marker
        // logrotate copytruncate: the file shrinks and writing resumes.
        try Data().write(to: url)
        await log.record(AuditEvent(event: "line", reason: "after-rotation"))
        #expect(try String(contentsOf: url, encoding: .utf8).contains("after-rotation"))
    }

    // MARK: critic experiment B

    @Test func ownersPendingSignInSurvivesJunkAtTheCapRateForTheWholeTTL() async throws {
        // Production caps: 30 authorizations/min, 10-minute pending TTL.
        try await OAuthHarness.run(authPerMinute: 10, workPerMinute: 30) { harness, client in
            let owner = try await harness.authorize(client, .init())
            #expect(owner.status == .found)
            let location = try #require(owner.headers[.location])
            var accepted = 0
            for _ in 0 ..< 299 { // one every 2 s = exactly 30/min, until 598 s
                harness.clock.advance(2)
                if try await harness.authorize(client, .init()).status == .found {
                    accepted += 1
                }
            }
            #expect(accepted == 299)
            #expect(await harness.server.pending.pendingCount == 300)
            #expect(await harness.server.pending.capacity >= 400)
            let callback = try await harness.googleApprove(location)
            let page = try await client.execute(uri: callback, method: .get)
            #expect(page.status == .ok)
            #expect(OAuthHarness.consentToken(in: page) != nil)
        }
    }

    @Test func pendingMemoryStaysBounded() async {
        let clock = TestClock()
        let store = PendingStore(now: clock.clock)
        #expect(store.capacity == 400)
        var first = ""
        for index in 0 ..< 1000 {
            let gstate = OAuthCrypto.token()
            if index == 0 {
                first = gstate
            }
            await store.insert(PendingAuthorization(
                gstate: gstate, nonce: "n", googleVerifier: "v", clientState: "s", redirectURI: "r",
                codeChallenge: "c", resource: "x", createdAt: clock.now
            ))
            clock.advance(0.01)
        }
        #expect(await store.pendingCount == 400)
        #expect(await store.take(gstate: first) == nil)
    }

    // MARK: X-Forwarded-For (strict)

    @Test func forwardedForIsParsedStrictly() {
        let accepted: [(String, String)] = [
            ("1.2.3.4", "1.2.3.4"), ("1.2.3.4:5678", "1.2.3.4"), ("[2001:db8::1]:443", "2001:db8::1"),
            ("[2001:db8::1]", "2001:db8::1"), ("2001:DB8:0:0::1", "2001:db8::1"), ("::1", "::1"),
        ]
        for (raw, expected) in accepted {
            #expect(ForwardedFor.parse(raw) == expected, "\(raw)")
        }
        for raw in [
            "unknown", "evil.example", "1.2.3", "1.2.3.4.5", "256.1.1.1", "1.2.3.4:0", "1.2.3.4:99999",
            "1.2.3.4:", "[2001:db8::1]x", "[2001:db8::1]:", "[1.2.3.4]:80", "2001:db8::1:80:zz", "", " ",
            "1.2.3.4 5", "[::1", "_",
        ] {
            #expect(ForwardedFor.parse(raw) == nil, "\(raw)")
        }
        // Ports never make the limiter key per-connection.
        #expect(ForwardedFor.lastHop(["9.9.9.9, 1.2.3.4:1111"]) == ForwardedFor.lastHop(["1.2.3.4:2222"]))
    }

    @Test func unparseableForwardedForIsCountedAndReported() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("xff-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("audit.jsonl")
        let audit = AuditLog(url: url)
        _ = ForwardedFor.drainUnparseable()
        for value in ["unknown", "1.1.1.1, nope", "[v6]:1"] {
            #expect(ForwardedFor.lastHop([value]) == nil)
        }
        let reporter = Task { await Commands.reportUnparseableForwardedFor(audit: audit, every: .milliseconds(20)) }
        defer { reporter.cancel() }
        for _ in 0 ..< 200 where ForwardedFor.unparseableInAudit(at: url) < 3 {
            try await Task.sleep(for: .milliseconds(20))
        }
        // Other tests may add to the process-wide counter in parallel: at least ours.
        #expect(ForwardedFor.unparseableInAudit(at: url) >= 3)
    }

    @Test func portsInForwardedForDoNotEvadePerIPLimits() async throws {
        try await OAuthHarness.run(env: ["NR_TRUST_FORWARDED_FOR": "1"], authPerMinute: 10) { harness, client in
            var limited = 0
            for index in 0 ..< 40 {
                let response = try await harness.post(
                    client, "/token", [("grant_type", "refresh_token")],
                    headers: [HTTPField.Name("X-Forwarded-For")!: "203.0.113.7:\(40000 + index)"]
                )
                if response.status == .tooManyRequests {
                    limited += 1
                }
            }
            #expect(limited == 30)
        }
    }
}
