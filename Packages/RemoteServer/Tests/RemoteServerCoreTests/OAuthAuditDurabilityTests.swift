import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTesting
@testable import RemoteServerCore
import Testing

/// Critique round 3: the anomaly cues survive the size ceiling, rotation (both
/// logrotate modes) resumes writing, summaries are flushed on stop, junk revokes
/// cannot hide real ones, and `status` reports truncation.
struct OAuthAuditDurabilityTests {
    private static func tempAudit() -> (URL, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("audit-\(UUID().uuidString)")
        return (directory, directory.appendingPathComponent("audit.jsonl"))
    }

    private static func events(in url: URL) -> [String] {
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        return text.split(separator: "\n").compactMap { line in
            (try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])?["event"] as? String
        }
    }

    /// Critic experiment 1a.
    @Test func forensicEventsAreWrittenPastTheCeilingWhileJunkIsDropped() async {
        let (directory, url) = Self.tempAudit()
        defer { try? FileManager.default.removeItem(at: directory) }
        var limits = AuditLog.Limits()
        limits.maxFileBytes = 30000
        limits.linesPerEventPerMinute = 100_000
        let log = AuditLog(url: url, limits: limits)
        for _ in 0 ..< 400 {
            await log.record(AuditEvent(
                event: "token.rejected", status: "400", clientID: "nr-x", ip: "203.0.113.9", reason: "refresh_unknown"
            ))
        }
        for event in ["refresh.reuse", "login.denied", "code.reuse", "kill", "auth.tarpit"] {
            await log.record(AuditEvent(event: event, status: "400", reason: "real"))
        }
        await log.record(AuditEvent(event: "token.rejected", reason: "after"))
        let seen = Self.events(in: url)
        for forensic in ["refresh.reuse", "login.denied", "code.reuse", "kill"] {
            #expect(seen.contains(forensic), "\(forensic) dropped at the ceiling")
        }
        #expect(!seen.contains("auth.tarpit")) // not forensic: dropped like the junk
        #expect(seen.count { $0 == "audit.truncated" } == 1)
        #expect(seen.count { $0 == "token.rejected" } < 400)
        #expect(AuditLog.forensicEvents == ["login.denied", "refresh.reuse", "code.reuse", "kill"])
    }

    /// Critic experiment 1d: logrotate's default rename+create mode.
    @Test func renameRotationResumesWritingInTheNewFile() async throws {
        let (directory, url) = Self.tempAudit()
        defer { try? FileManager.default.removeItem(at: directory) }
        let rotated = directory.appendingPathComponent("audit.jsonl.1")
        let clock = TestClock()
        var limits = AuditLog.Limits()
        limits.maxFileBytes = 3000
        limits.linesPerEventPerMinute = 100_000
        let log = AuditLog(url: url, limits: limits, now: clock.clock)
        for _ in 0 ..< 100 {
            await log.record(AuditEvent(event: "junk"))
        }
        #expect(Self.events(in: url).contains("audit.truncated"))
        // Over the ceiling, then rotated by rename (a new file may or may not exist yet).
        try FileManager.default.moveItem(at: url, to: rotated)
        await log.record(AuditEvent(event: "kill"))
        await log.record(AuditEvent(event: "junk", reason: "fresh-file"))
        #expect(Self.events(in: url) == ["kill", "junk"])
        #expect(!Self.events(in: rotated).contains("kill"))

        // Below the ceiling, a rename is picked up within the minute check.
        let second = directory.appendingPathComponent("audit.jsonl.2")
        try FileManager.default.moveItem(at: url, to: second)
        FileManager.default.createFile(atPath: url.path, contents: nil) // logrotate `create`
        clock.advance(61)
        await log.record(AuditEvent(event: "after-rename"))
        #expect(Self.events(in: url) == ["after-rename"])
    }

    @Test func copytruncateResumesWriting() async throws {
        let (directory, url) = Self.tempAudit()
        defer { try? FileManager.default.removeItem(at: directory) }
        var limits = AuditLog.Limits()
        limits.maxFileBytes = 3000
        limits.linesPerEventPerMinute = 100_000
        let log = AuditLog(url: url, limits: limits)
        for _ in 0 ..< 100 {
            await log.record(AuditEvent(event: "junk"))
        }
        try Data().write(to: url) // copytruncate: same inode, size 0
        await log.record(AuditEvent(event: "junk", reason: "after"))
        #expect(Self.events(in: url) == ["junk"])
    }

    @Test func pendingSummariesAreFlushedOnStop() async throws {
        let (directory, url) = Self.tempAudit()
        defer { try? FileManager.default.removeItem(at: directory) }
        var limits = AuditLog.Limits()
        limits.linesPerEventPerMinute = 2
        let log = AuditLog(url: url, limits: limits)
        for _ in 0 ..< 50 {
            await log.record(AuditEvent(event: "junk"))
        }
        await log.flush() // what `serve` does after a graceful SIGTERM
        await log.flush() // idempotent
        let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
        let summaries = lines.filter { $0.contains("audit.suppressed") }
        #expect(summaries.count == 1)
        #expect(summaries.first?.contains("\"result_count\":48") == true)
    }

    @Test func junkRevokesCannotCrowdOutRealOnes() async throws {
        let (directory, url) = Self.tempAudit()
        defer { try? FileManager.default.removeItem(at: directory) }
        var limits = AuditLog.Limits()
        limits.linesPerEventPerMinute = 5
        let log = AuditLog(url: url, limits: limits)
        for _ in 0 ..< 100 {
            await log.record(AuditEvent(event: "revoke", status: "200", reason: "unknown"))
        }
        await log.record(AuditEvent(event: "revoke", status: "200", tokenFamily: "fam", reason: "refresh"))
        await log.flush()
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.contains("\"reason\":\"refresh\""))
        #expect(text.contains("\"reason\":\"revoke|unknown\"") && text.contains("\"result_count\":95"))
    }

    @Test func reuseIsStillAuditedAfterAJunkRefreshFlood() async throws {
        try await OAuthHarness.run(authPerMinute: 10, workPerMinute: 30) { harness, client in
            let tokens = try await harness.tokens(client)
            for _ in 0 ..< 500 {
                _ = try await harness.refresh(client, OAuthCrypto.token())
            }
            let rotated = try await harness.refresh(client, tokens.refresh)
            #expect(rotated.status == .ok)
            let newAccess = try #require(try OAuthHarness.json(rotated)["access_token"] as? String)
            // The junk spent the failure budget, yet a real reuse still gets its
            // invalid_grant (not a junk 429), is audited, and kills the family.
            let reuse = try await harness.refresh(client, tokens.refresh)
            #expect(reuse.status == .badRequest)
            #expect(try OAuthHarness.json(reuse)["error"] as? String == "invalid_grant")
            #expect(harness.events("refresh.reuse").count == 1)
            #expect(try await harness.mcpStatus(client, newAccess).status == .unauthorized)
        }
    }

    @Test func statusReportsTruncationAndSuppressedCounts() throws {
        let (directory, url) = Self.tempAudit()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        func line(_ event: String, _ count: Int?, _ at: Date) -> String {
            var object: [String: Any] = ["event": event, "ts": DateParsing.string(at)]
            if let count {
                object["result_count"] = count
            }
            return String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self)
        }
        let clean = [line("token.rejected", nil, now), line("audit.suppressed", 7, now.addingTimeInterval(-60))]
        try (clean.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        var summary = AuditFileSummary.scan(url, now: now)
        #expect(summary == AuditFileSummary(truncated: false, suppressedLastDay: 7))
        #expect(summary.statusLine.hasPrefix("audit: not truncated, 7 line(s) suppressed"))
        let dirty = clean + [
            line("audit.suppressed", 1000, now.addingTimeInterval(-2 * 86400)), // older than a day
            line("audit.truncated", nil, now), line("audit.suppressed", 5, now),
        ]
        try (dirty.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        summary = AuditFileSummary.scan(url, now: now)
        #expect(summary == AuditFileSummary(truncated: true, suppressedLastDay: 12))
        #expect(summary.statusLine.contains("TRUNCATED"))
        #expect(AuditFileSummary.scan(directory.appendingPathComponent("missing"), now: now) == AuditFileSummary())
    }

    @Test func ipv4MappedAddressesShareTheIPv4Key() {
        #expect(ForwardedFor.parse("::ffff:1.2.3.4") == "1.2.3.4")
        #expect(ForwardedFor.parse("::FFFF:1.2.3.4") == "1.2.3.4")
        #expect(ForwardedFor.parse("[::ffff:1.2.3.4]:443") == "1.2.3.4")
        #expect(ForwardedFor.parse("2001:db8::1") == "2001:db8::1")
    }
}
