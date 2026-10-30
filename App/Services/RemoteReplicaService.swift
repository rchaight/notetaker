#if os(macOS)
    import CalendarKit
    import EventKit
    import Foundation
    import MarkdownKit
    import Observation
    import os
    import VaultKit

    /// Keeps the remote replica image fresh on the Mac and pushes it to the
    /// user's own container over ssh/rsync on a Tailscale address
    /// (specs/remote-vault/04, design 00 §3, §4.6).
    ///
    /// Everything here is OFF by default. Turning `remoteAccessEnabled` off is
    /// the Mac-side kill switch: cancel work (even a wedged job), replace the
    /// local staging image with the DISABLED image, and push it to EVERY
    /// container that ever received a push (rsync `--delete` empties each inbox).
    ///
    /// Sharing is bound to the vault it was enabled for; a different active
    /// vault pauses it (no export, no push) until the user re-enables.
    ///
    /// Logging: counts, durations and exit codes only. Note text and note
    /// paths are never logged at a public privacy level.
    @MainActor
    @Observable
    final class RemoteReplicaService {
        static let shared = RemoteReplicaService()
        private typealias Support = RemoteReplicaSupport

        // MARK: Settings keys (UserDefaults.standard; none secret)

        enum Key {
            static let enabled = "remoteAccessEnabled"
            static let host = "remoteHost"
            static let user = "remoteUser"
            static let rsyncPath = "remoteRsyncPath"
            static let includeCalendar = "remoteIncludeCalendar"
            static let excludedFolders = "remoteExcludedFolders"
            static let hostKeyTrusted = "remoteHostKeyTrusted"
            /// Internal: "user@host" of every container that may hold a copy.
            static let pushedTargets = "remotePushedTargets"
            /// Internal: canonical path of the vault sharing was enabled for.
            static let boundVault = "remoteBoundVaultRoot"
            static let all = [enabled, host, user, rsyncPath, includeCalendar, excludedFolders, hostKeyTrusted]
        }

        nonisolated static let defaultUser = "replica"
        nonisolated static let defaultRsync = "/usr/bin/rsync"

        private nonisolated static let log = Logger(subsystem: "com.rchaight.notetaker", category: "RemoteReplica")
        private static let debounceSettle: TimeInterval = 30
        private static let debounceCalendar: TimeInterval = 2
        private static let debounceConfig: TimeInterval = 2
        /// A pending request never waits longer than this, however busy the index is.
        private static let maxDebounceAge: TimeInterval = 120
        private static let timerInterval: TimeInterval = 300
        private static let failureBackoff: TimeInterval = 60
        private static let processTimeout: TimeInterval = 120

        // MARK: Observable state (Settings)

        struct LastPush: Codable, Equatable {
            var at: Date
            /// The push (not just the export) succeeded.
            var ok: Bool
            var pushed: Bool
            var disabled: Bool
            var bytesSent: Int?
            var notes: Int
            var lockedExcluded: Int
            var indexExcluded: Int
            var otherExcluded: Int
            var notDownloaded: Int
            var calendarIncluded: Bool
            var exportedAt: Date?
            var message: String
        }

        private(set) var lastPush: LastPush?
        private(set) var busy = false
        private(set) var publicKey = ""
        private(set) var hostFingerprint: String?
        private(set) var hostKeyMessage: String?
        private(set) var verifyMessage: String?
        private(set) var wipePending = false
        private(set) var pausedMessage: String?
        /// Containers that may still hold a copy ("user@host").
        private(set) var pushedTargets: [String] = []

        // MARK: Private state

        private weak var indexService: VaultIndexService?
        private var started = false
        private var lastEnabled = false
        private var lastConfig = ""
        private var lastHost = ""
        private var triggers: [Task<Void, Never>] = []
        private var debounce: Task<Void, Never>?
        private var firstPendingAt: Date?
        private var loop: Task<Void, Never>?
        private var current: Task<Void, Never>?
        /// Bumped by the kill switch so a wedged loop can never touch state again.
        private var generation = 0
        private var planner = JobPlanner()
        private var pendingHostLine: String?
        private var pendingHost: String?
        private var prepareTask: Task<Void, Never>?

        // MARK: Paths

        static var baseDirectory: URL {
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Notetaker", isDirectory: true)
                .appendingPathComponent("RemoteExport", isDirectory: true)
        }

        static var stagingURL: URL {
            baseDirectory.appendingPathComponent("staging", isDirectory: true)
        }

        /// Disabled image used to wipe stale containers while sharing stays on.
        private static var disabledStagingURL: URL {
            baseDirectory.appendingPathComponent("staging-disabled", isDirectory: true)
        }

        private static var keyURL: URL {
            baseDirectory.appendingPathComponent("id_ed25519")
        }

        private static var knownHostsURL: URL {
            baseDirectory.appendingPathComponent("known_hosts")
        }

        private static var lastPushURL: URL {
            baseDirectory.appendingPathComponent("last-push.json")
        }

        // MARK: Settings accessors

        private static var defaults: UserDefaults {
            .standard
        }

        static var isEnabled: Bool {
            defaults.bool(forKey: Key.enabled)
        }

        /// Lowercased: ssh matches known_hosts case-insensitively but stores what we give it.
        private static var host: String {
            (defaults.string(forKey: Key.host) ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }

        private static var user: String {
            let value = (defaults.string(forKey: Key.user) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? defaultUser : value
        }

        private static var rsyncPath: String {
            let value = (defaults.string(forKey: Key.rsyncPath) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? defaultRsync : value
        }

        private static var includeCalendar: Bool {
            defaults.object(forKey: Key.includeCalendar) == nil ? true : defaults.bool(forKey: Key.includeCalendar)
        }

        static func excludedFolders() -> [String] {
            (defaults.string(forKey: Key.excludedFolders) ?? "")
                .split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        }

        private static func configKey() -> String {
            Key.all.map { "\(defaults.object(forKey: $0) ?? "")" }.joined(separator: "|")
                + "|\(CalendarService.excludedCalendarIds().sorted())"
        }

        private static func knownHostsText() -> String {
            (try? String(contentsOf: knownHostsURL, encoding: .utf8)) ?? ""
        }

        private static func readTargets() -> Set<String> {
            Set(defaults.stringArray(forKey: Key.pushedTargets) ?? [])
        }

        private func storeTargets(_ targets: Set<String>) {
            Self.defaults.set(targets.sorted(), forKey: Key.pushedTargets)
            pushedTargets = targets.sorted()
        }

        // MARK: Validation (forwarders; pure logic lives in RemoteReplicaSupport)

        nonisolated static func isValidHost(_ host: String) -> Bool {
            RemoteReplicaSupport.isValidHost(host)
        }

        nonisolated static func isValidUser(_ user: String) -> Bool {
            RemoteReplicaSupport.isValidUser(user)
        }

        nonisolated static func isUsableRsync(_ path: String) -> Bool {
            RemoteReplicaSupport.isUsableRsync(path)
        }

        /// What stops a push to this container, in plain words; nil when it can run.
        private static func blocker(user: String, host: String) -> String? {
            if host.isEmpty {
                return "no container host is set"
            }
            if !isValidHost(host) {
                return "\(host) is not a Tailscale address"
            }
            if !isValidUser(user) {
                return "the ssh user name is not valid"
            }
            if !isUsableRsync(rsyncPath) {
                return "the rsync path is not an executable"
            }
            if !Support.knownHosts(knownHostsText(), contains: host) {
                return "the host key for \(host) has not been trusted"
            }
            if !FileManager.default.fileExists(atPath: keyURL.path) {
                return "this Mac's key does not exist yet"
            }
            return nil
        }

        // MARK: Vault binding

        private static func vaultMismatch(_ root: URL) -> Bool {
            guard let bound = defaults.string(forKey: Key.boundVault), !bound.isEmpty else { return false }
            return bound != Support.canonical(root)
        }

        /// Called when sharing is enabled. Moving to a different vault than the
        /// one last shared drops the old vault's excluded folders: they must be
        /// chosen again for the new vault.
        private func bindVault() {
            guard let root = indexService?.vaultRootURL else { return }
            let canonical = Support.canonical(root)
            if let bound = Self.defaults.string(forKey: Key.boundVault), !bound.isEmpty, bound != canonical {
                Self.defaults.set("", forKey: Key.excludedFolders)
            }
            Self.defaults.set(canonical, forKey: Key.boundVault)
            pausedMessage = nil
        }

        // MARK: Lifecycle

        func start(indexService: VaultIndexService) {
            self.indexService = indexService
            guard !started else { return }
            started = true
            lastEnabled = Self.isEnabled
            lastConfig = Self.configKey()
            lastHost = Self.host
            storeTargets(Self.readTargets())
            wipePending = !pushedTargets.isEmpty && !Self.isEnabled

            triggers.append(Task { [weak self] in
                for await _ in NotificationCenter.default
                    .notifications(named: VaultIndexService.didSettleNotification) {
                    self?.schedule(after: Self.debounceSettle)
                }
            })
            triggers.append(Task { [weak self] in
                for await _ in NotificationCenter.default.notifications(named: .EKEventStoreChanged) {
                    if Self.includeCalendar {
                        self?.schedule(after: Self.debounceCalendar)
                    }
                }
            })
            triggers.append(Task { [weak self] in
                for await _ in NotificationCenter.default.notifications(named: UserDefaults.didChangeNotification) {
                    self?.defaultsChanged()
                }
            })
            triggers.append(Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(Self.timerInterval))
                    self?.timerTick()
                }
            })

            // Sweep leftovers (off the main actor) and make the key BEFORE the
            // first job, so a sweep can never delete a running export's temp tree.
            Task { [weak self] in
                guard let self else { return }
                let stagings = [Self.stagingURL, Self.disabledStagingURL]
                await Task.detached(priority: .utility) {
                    for staging in stagings {
                        ReplicaExporter.sweepStale(staging: staging)
                    }
                }.value
                await prepare()
                if Self.isEnabled {
                    if Self.defaults.string(forKey: Key.boundVault)?.isEmpty ?? true {
                        bindVault()
                    }
                    planner.syncRequested = true
                    kick()
                } else if wipePending {
                    planner.wipeRequested = true
                    kick()
                }
            }
        }

        /// Idempotent local setup, also called by Settings so the key shows up
        /// even if the main window never opened. Single-flight: concurrent
        /// callers share one run, so ssh-keygen never runs twice.
        func prepare() async {
            if let running = prepareTask {
                await running.value
                return
            }
            let task = Task { [weak self] in
                guard let self else { return }
                await performPrepare()
            }
            prepareTask = task
            await task.value
            prepareTask = nil
        }

        private func performPrepare() async {
            let base = Self.baseDirectory
            try? FileManager.default.createDirectory(
                at: base, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
            )
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: base.path)
            await ensureKeyPair()
            loadPublicKey()
            if lastPush == nil, let data = try? Data(contentsOf: Self.lastPushURL) {
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                lastPush = try? decoder.decode(LastPush.self, from: data)
            }
            syncTrustFlag()
            await refreshFingerprint()
        }

        private func ensureKeyPair() async {
            let key = Self.keyURL
            guard !FileManager.default.fileExists(atPath: key.path) else {
                try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: key.path)
                return
            }
            let result = await Support.runProcess(
                "/usr/bin/ssh-keygen",
                ["-q", "-t", "ed25519", "-N", "", "-C", "notetaker-remote", "-f", "id_ed25519"],
                directory: Self.baseDirectory, timeout: 30
            )
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: key.path)
            if result.status != 0 {
                Self.log.error("ssh-keygen failed, exit \(result.status, privacy: .public)")
            }
        }

        private func loadPublicKey() {
            let pub = Self.keyURL.appendingPathExtension("pub")
            publicKey = ((try? String(contentsOf: pub, encoding: .utf8)) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        /// New key pair. Nothing remote changes; the runbook step must be repeated.
        func regenerateKey() async {
            if let running = prepareTask {
                await running.value
            }
            let task = Task { [weak self] in
                guard let self else { return }
                try? FileManager.default.removeItem(at: Self.keyURL)
                try? FileManager.default.removeItem(at: Self.keyURL.appendingPathExtension("pub"))
                publicKey = ""
                await ensureKeyPair()
                loadPublicKey()
            }
            prepareTask = task
            await task.value
            prepareTask = nil
        }

        // MARK: Triggers

        private func defaultsChanged() {
            let enabled = Self.isEnabled
            let host = Self.host
            if host != lastHost {
                lastHost = host
                hostChanged()
            }
            let key = Self.configKey()
            guard key != lastConfig || enabled != lastEnabled else { return }
            lastConfig = key
            if enabled != lastEnabled {
                lastEnabled = enabled
                if enabled {
                    wipePending = false
                    bindVault()
                    planner.enable()
                    kick()
                } else {
                    killSwitch()
                }
            } else if enabled {
                schedule(after: Self.debounceConfig)
            }
        }

        private func timerTick() {
            if Self.isEnabled {
                planner.syncRequested = true
                kick()
            } else if !pushedTargets.isEmpty {
                planner.wipeRequested = true
                kick()
            }
        }

        /// Coalesces triggers into one pending request.
        private func schedule(after delay: TimeInterval) {
            guard Self.isEnabled else { return }
            let first = firstPendingAt ?? Date()
            firstPendingAt = first
            let capped = max(0, min(delay, Self.maxDebounceAge - Date().timeIntervalSince(first)))
            debounce?.cancel()
            debounce = Task { [weak self] in
                try? await Task.sleep(for: .seconds(capped))
                guard !Task.isCancelled, let self else { return }
                firstPendingAt = nil
                planner.syncRequested = true
                kick()
            }
        }

        func pushNow() {
            guard Self.isEnabled else { return }
            planner.notBefore = .distantPast
            planner.syncRequested = true
            kick()
        }

        func retryWipe() {
            guard !Self.isEnabled else { return }
            planner.wipeRequested = true
            kick()
        }

        /// Toggle off: stop everything that would send notes, even a wedged
        /// job, then wipe every container that may hold a copy.
        private func killSwitch() {
            debounce?.cancel()
            firstPendingAt = nil
            generation += 1 // an abandoned loop can no longer change state
            current?.cancel()
            current = nil
            loop?.cancel()
            loop = nil
            busy = false
            planner.killSwitch()
            wipePending = !pushedTargets.isEmpty
            kick()
        }

        // MARK: Serial job loop (one operation at a time)

        private func kick() {
            guard loop == nil else { return }
            let gen = generation
            loop = Task { [weak self] in
                while let self, gen == generation, let op = nextOperation() {
                    busy = true
                    let task = Task { await self.perform(op, generation: gen) }
                    current = task
                    await task.value
                    guard gen == generation else { return } // killed: the new loop owns the state
                    current = nil
                    busy = false
                }
                if let self, gen == generation {
                    loop = nil
                }
            }
        }

        private func nextOperation() -> JobPlanner.Operation? {
            switch planner.next(now: Date(), enabled: Self.isEnabled) {
            case let .run(op):
                return op
            case let .backoff(until):
                // Failed recently: try again once the backoff is over.
                schedule(after: until.timeIntervalSinceNow)
                return nil
            case .idle:
                return nil
            }
        }

        private func perform(_ op: JobPlanner.Operation, generation gen: Int) async {
            switch op {
            case .sync: await runSync(generation: gen)
            case .wipe: await runWipe(generation: gen)
            }
        }

        // MARK: Export + push

        private func runSync(generation gen: Int) async {
            guard Self.isEnabled, let root = indexService?.vaultRootURL else {
                record(failure: "Export skipped: the vault is not available.")
                return
            }
            if Self.defaults.string(forKey: Key.boundVault)?.isEmpty ?? true {
                bindVault()
            }
            if Self.vaultMismatch(root) {
                let message = "Active vault changed - remote sharing paused. Re-enable to share this vault."
                pausedMessage = message
                record(failure: message)
                return
            }
            pausedMessage = nil
            let policy = ExportPolicy(excludedFolders: Self.excludedFolders())
            let exporter = ReplicaExporter(root: root, staging: Self.stagingURL, policy: policy)
            let calendar: Data? = if Self.includeCalendar {
                await Task.detached(priority: .utility) {
                    guard CalendarService.accessState() == .granted else { return nil }
                    return try? SnapshotCodec.encode(CalendarService.snapshot(daysBack: 7, daysAhead: 60))
                }.value
            } else {
                nil
            }
            let started = Date()
            let manifest: ReplicaManifest
            do {
                let result = try await exporter.export(
                    calendarSnapshot: calendar,
                    appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
                )
                manifest = result.manifest
            } catch is CancellationError {
                return
            } catch {
                Self.log.error("export failed: \(Self.describe(error), privacy: .private)")
                guard gen == generation else { return }
                record(failure: "Export failed: \(Self.describe(error))")
                return
            }
            Self.log.notice(
                "exported notes=\(manifest.noteCount, privacy: .public) locked=\(manifest.lockedExcludedCount, privacy: .public) index=\(manifest.indexExcludedCount, privacy: .public) other=\(manifest.otherExcludedCount, privacy: .public) notDownloaded=\(manifest.notDownloadedCount, privacy: .public) calendar=\(manifest.calendarIncluded, privacy: .public) ms=\(Int(Date().timeIntervalSince(started) * 1000), privacy: .public)"
            )
            // Switched off meanwhile (or loop abandoned): never push this image.
            guard Self.isEnabled, gen == generation else { return }
            let user = Self.user
            let host = Self.host
            if let why = Self.blocker(user: user, host: host) {
                record(manifest: manifest, pushed: false, ok: false, message: "Exported; not pushed because \(why).")
                return
            }
            var result = await push(user: user, host: host, staging: "staging")
            guard gen == generation else { return }
            if !result.ok {
                planner.notBefore = Date().addingTimeInterval(Self.failureBackoff)
            } else {
                result.message += await wipeStaleTargets(keeping: Support.target(user: user, host: host), root: root)
            }
            record(manifest: manifest, pushed: true, ok: result.ok, message: result.message)
        }

        /// Sharing is on but the host changed: containers that still hold a
        /// copy get the disabled image (best effort; failures stay listed).
        private func wipeStaleTargets(keeping current: String, root: URL) async -> String {
            let stale = Self.readTargets().subtracting([current])
            guard !stale.isEmpty else { return "" }
            do {
                _ = try ReplicaExporter.writeDisabled(staging: Self.disabledStagingURL, vaultRoot: root)
            } catch {
                return " Old container(s) \(stale.sorted().joined(separator: ", ")) still hold a copy: could not write the disabled image."
            }
            let report = await wipe(targets: stale, staging: "staging-disabled")
            return " " + report.summary(prefix: "Old container wipe")
        }

        private func runWipe(generation gen: Int) async {
            guard !Self.isEnabled else { return }
            guard let root = indexService?.vaultRootURL else {
                wipeFailed("the vault location is not available", attempted: false)
                return
            }
            let manifest: ReplicaManifest
            do {
                manifest = try ReplicaExporter.writeDisabled(staging: Self.stagingURL, vaultRoot: root)
            } catch {
                // Never leave a full local image behind, and never push one.
                try? FileManager.default.removeItem(at: Self.stagingURL)
                wipeFailed("could not write the disabled image: \(Self.describe(error))", attempted: false)
                return
            }
            let targets = Self.readTargets()
            guard !targets.isEmpty else {
                wipePending = false
                record(
                    manifest: manifest, pushed: false, ok: true,
                    message: "Remote access off. The local copy was replaced by the disabled image; nothing had been pushed to a container.",
                    disabled: true
                )
                return
            }
            let report = await wipe(targets: targets, staging: "staging")
            guard gen == generation else { return }
            wipePending = !Self.readTargets().isEmpty
            if report.failed.isEmpty {
                let time = Date().formatted(date: .omitted, time: .standard)
                record(
                    manifest: manifest, pushed: true, ok: true,
                    message: "Remote access off; replica wiped at \(time) on \(report.wiped.joined(separator: ", ")).",
                    disabled: true
                )
            } else {
                Self.log.error("wipe did not reach \(report.failed.count, privacy: .public) container(s)")
                record(
                    manifest: manifest, pushed: !report.wiped.isEmpty || report.attempted, ok: false,
                    message: report.summary(prefix: "Remote access off, but the wipe is not confirmed")
                        + " Run the container kill switch (pct exec <id> -- notetaker-remote kill) or retry.",
                    disabled: true
                )
            }
        }

        private func wipeFailed(_ reason: String, attempted: Bool) {
            wipePending = true
            Self.log.error("wipe did not reach the container")
            let message = "Remote access off, but the wipe did not reach the container (\(reason)). "
                + "Run the container kill switch (pct exec <id> -- notetaker-remote kill) or retry."
            record(manifest: nil, pushed: attempted, ok: false, message: message, disabled: true)
        }

        struct WipeReport {
            var wiped: [String] = []
            var failed: [(target: String, reason: String)] = []
            var attempted = false

            func summary(prefix: String) -> String {
                var parts = [prefix + "."]
                if !wiped.isEmpty {
                    parts.append("Wiped: \(wiped.joined(separator: ", ")).")
                }
                if !failed.isEmpty {
                    parts
                        .append("NOT confirmed: " + failed.map { "\($0.target) (\($0.reason))" }
                            .joined(separator: "; ") + ".")
                }
                return parts.joined(separator: " ")
            }
        }

        /// Pushes the image in `staging` (a disabled image) to every target.
        /// A target leaves the pushed set only after its push succeeded.
        private func wipe(targets: Set<String>, staging: String) async -> WipeReport {
            var report = WipeReport()
            for target in targets.sorted() {
                guard let (user, host) = Support.split(target: target) else {
                    report.failed.append((target, "unreadable target"))
                    continue
                }
                if let why = Self.blocker(user: user, host: host) {
                    report.failed.append((target, why))
                    continue
                }
                report.attempted = true
                let result = await push(user: user, host: host, staging: staging)
                if result.ok {
                    storeTargets(Self.readTargets().subtracting([target]))
                    report.wiped.append(target)
                } else {
                    report.failed.append((target, result.message))
                }
            }
            return report
        }

        // MARK: Push (two rsync passes; manifest last)

        private func push(user: String, host: String, staging: String) async -> (ok: Bool, message: String) {
            // Conservative: even an interrupted push may have left files.
            storeTargets(Self.readTargets().union([Support.target(user: user, host: host)]))
            let commands = Support.pushCommands(user: user, host: host, rsync: Self.rsyncPath, staging: staging)
            for (index, command) in commands.enumerated() {
                let result = await Support.runProcess(
                    command.executable, command.arguments,
                    directory: Self.baseDirectory, timeout: Self.processTimeout
                )
                Self.log.notice(
                    "push pass \(index + 1, privacy: .public) exit=\(result.status, privacy: .public) timedOut=\(result.timedOut, privacy: .public)"
                )
                if Task.isCancelled {
                    return (false, "Cancelled.")
                }
                if result.timedOut || result.status != 0 {
                    let why = result.timedOut ? "timed out after \(Int(Self.processTimeout)) s" : "rsync exit \(result.status)"
                    let tail = Support.tail(result.stderr.isEmpty ? result.stdout : result.stderr)
                    return (false, "Push failed (pass \(index + 1) of 2, \(why))" + (tail.isEmpty ? "." : ": \(tail)"))
                }
            }
            return (true, "Pushed at \(Date().formatted(date: .omitted, time: .standard)).")
        }

        // MARK: Host key (trust on first use, shown to the user)

        func fetchHostKey() async {
            pendingHostLine = nil
            pendingHost = nil
            hostFingerprint = nil
            let host = Self.host
            guard Self.isValidHost(host) else {
                hostKeyMessage = "Set a Tailscale address first."
                return
            }
            hostKeyMessage = "Fetching host key..."
            let result = await Support.runProcess(
                "/usr/bin/ssh-keyscan", ["-t", "ed25519", "-T", "5", host],
                directory: Self.baseDirectory, timeout: 15
            )
            guard host == Self.host else { return } // the field changed while we waited
            guard let line = Support.parseKeyscan(result.stdout, host: host) else {
                let detail = Support.tail(result.stderr)
                hostKeyMessage = "Could not fetch an ed25519 host key" + (detail.isEmpty ? "." : ": \(detail)")
                return
            }
            guard let fingerprint = await fingerprint(ofLine: line), host == Self.host else {
                if host == Self.host {
                    hostKeyMessage = "Could not compute the host key fingerprint."
                }
                return
            }
            pendingHostLine = line
            pendingHost = host
            hostFingerprint = fingerprint
            hostKeyMessage = "Compare this with the container's key, then trust it."
        }

        private func fingerprint(ofLine line: String) async -> String? {
            let temp = Self.baseDirectory.appendingPathComponent("hostkey-\(UUID().uuidString).tmp")
            defer { try? FileManager.default.removeItem(at: temp) }
            guard (try? (line + "\n").write(to: temp, atomically: true, encoding: .utf8)) != nil else { return nil }
            let result = await Support.runProcess(
                "/usr/bin/ssh-keygen", ["-lf", temp.lastPathComponent], directory: Self.baseDirectory, timeout: 15
            )
            guard result.status == 0, let fp = result.stdout.split(separator: " ").dropFirst().first else { return nil }
            return String(fp)
        }

        func trustHost() {
            let host = Self.host
            guard let line = pendingHostLine, pendingHost == host, Self.isValidHost(host) else { return }
            let url = Self.knownHostsURL
            do {
                try Data(Support.knownHosts(Self.knownHostsText(), setting: line, for: host).utf8)
                    .write(to: url, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            } catch {
                hostKeyMessage = "Could not store the host key."
                return
            }
            pendingHostLine = nil
            pendingHost = nil
            syncTrustFlag()
            hostKeyMessage = "Host key trusted."
            if Self.isEnabled {
                pushNow()
            }
        }

        /// The host field changed: forget pending trust, and keep known_hosts
        /// lines only for hosts that may still hold a copy (they must stay
        /// reachable so the kill switch can wipe them).
        private func hostChanged() {
            pendingHostLine = nil
            pendingHost = nil
            hostFingerprint = nil
            hostKeyMessage = nil
            let holding = Set(Self.readTargets().compactMap { Support.split(target: $0)?.host })
            try? Data(Support.knownHosts(Self.knownHostsText(), keeping: holding).utf8)
                .write(to: Self.knownHostsURL, options: .atomic)
            syncTrustFlag()
            Task { await refreshFingerprint() }
        }

        /// `remoteHostKeyTrusted` mirrors "known_hosts has a line for the current host".
        private func syncTrustFlag() {
            let trusted = Support.knownHosts(Self.knownHostsText(), contains: Self.host)
            if Self.defaults.bool(forKey: Key.hostKeyTrusted) != trusted {
                Self.defaults.set(trusted, forKey: Key.hostKeyTrusted)
            }
        }

        private func refreshFingerprint() async {
            let host = Self.host
            guard let line = Self.knownHostsText().split(whereSeparator: \.isNewline)
                .first(where: { $0.split(separator: " ").first?.lowercased() == host }) else { return }
            let fp = await fingerprint(ofLine: String(line))
            if host == Self.host {
                hostFingerprint = fp
            }
        }

        // MARK: Verify

        func verifyExport() async {
            verifyMessage = "Verifying..."
            let policy = ExportPolicy(excludedFolders: Self.excludedFolders())
            let staging = Self.stagingURL
            let outcome = await Task.detached(priority: .utility) {
                try? ReplicaExporter.verify(staging: staging, policy: policy)
            }.value
            guard let outcome else {
                verifyMessage = "Nothing to verify yet (no export has run)."
                return
            }
            if outcome.violations.isEmpty {
                verifyMessage = "0 violations in \(outcome.fileCount) files."
            } else {
                let list = outcome.violations.prefix(10).map { "\($0.path) (\($0.reason))" }.joined(separator: ", ")
                verifyMessage = "\(outcome.violations.count) violations in \(outcome.fileCount) files: \(list)"
            }
        }

        // MARK: Status

        private func record(failure message: String) {
            let previous = lastPush
            write(LastPush(
                at: Date(), ok: false, pushed: false, disabled: false, bytesSent: nil,
                notes: previous?.notes ?? 0, lockedExcluded: previous?.lockedExcluded ?? 0,
                indexExcluded: previous?.indexExcluded ?? 0, otherExcluded: previous?.otherExcluded ?? 0,
                notDownloaded: previous?.notDownloaded ?? 0, calendarIncluded: previous?.calendarIncluded ?? false,
                exportedAt: previous?.exportedAt, message: message
            ))
        }

        private func record(
            manifest: ReplicaManifest?, pushed: Bool, ok: Bool, message: String, disabled: Bool = false
        ) {
            let previous = lastPush
            write(LastPush(
                at: Date(), ok: ok, pushed: pushed, disabled: disabled, bytesSent: nil,
                notes: manifest?.noteCount ?? previous?.notes ?? 0,
                lockedExcluded: manifest?.lockedExcludedCount ?? previous?.lockedExcluded ?? 0,
                indexExcluded: manifest?.indexExcludedCount ?? previous?.indexExcluded ?? 0,
                otherExcluded: manifest?.otherExcludedCount ?? previous?.otherExcluded ?? 0,
                notDownloaded: manifest?.notDownloadedCount ?? previous?.notDownloaded ?? 0,
                calendarIncluded: manifest?.calendarIncluded ?? previous?.calendarIncluded ?? false,
                exportedAt: manifest?.generatedAt ?? previous?.exportedAt, message: message
            ))
        }

        private func write(_ status: LastPush) {
            lastPush = status
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
            if let data = try? encoder.encode(status) {
                try? data.write(to: Self.lastPushURL, options: .atomic)
            }
        }

        nonisolated static func describe(_ error: Error) -> String {
            switch error {
            case let ReplicaExporter.ExporterError.selfCheckFailed(path, reason):
                "self-check failed (\(reason)) at \(path)"
            case let ReplicaExporter.ExporterError.stagingUnavailable(why): "staging unavailable: \(why)"
            case let ReplicaExporter.ExporterError.calendarRejected(why): "calendar rejected: \(why)"
            default: error.localizedDescription
            }
        }
    }
#endif
