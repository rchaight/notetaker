#if os(macOS)
    import Darwin
    import Foundation

    // Pure helpers for RemoteReplicaService: validators, argument builders,
    // host bookkeeping, the job planner and a process runner that cannot be
    // wedged by a grandchild holding a pipe. No app types are referenced, so
    // scripts/remote-vault/replica-service-tests.sh compiles this file alone.

    struct ProcessResult: Sendable {
        var status: Int32
        var stdout: String
        var stderr: String
        var timedOut: Bool
    }

    enum RemoteReplicaSupport {
        static let sshPath = "/usr/bin/ssh"

        // MARK: Validation

        /// Tailscale IPv4 (100.64.0.0/10), IPv6 (fd7a:115c:a1e0::/48) or `*.ts.net`
        /// (case-insensitive, no trailing dot). Callers should lowercase first.
        static func isValidHost(_ host: String) -> Bool {
            guard !host.isEmpty, host.count <= 253,
                  host.unicodeScalars.allSatisfy({ $0.isASCII && !$0.properties.isWhitespace }) else { return false }
            var v4 = in_addr()
            if inet_pton(AF_INET, host, &v4) == 1 {
                let value = UInt32(bigEndian: v4.s_addr)
                return value & 0xFFC0_0000 == 0x6440_0000
            }
            var v6 = in6_addr()
            if inet_pton(AF_INET6, host, &v6) == 1 {
                let bytes = withUnsafeBytes(of: v6) { Array($0) }
                return Array(bytes.prefix(6)) == [0xFD, 0x7A, 0x11, 0x5C, 0xA1, 0xE0]
            }
            let lower = host.lowercased()
            guard lower.hasSuffix(".ts.net"), lower.count > ".ts.net".count else { return false }
            let labels = lower.split(separator: ".", omittingEmptySubsequences: false)
            return labels.allSatisfy { label in
                !label.isEmpty && label.count <= 63 && !label.hasPrefix("-") && !label.hasSuffix("-")
                    && label.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
            }
        }

        static func isValidUser(_ user: String) -> Bool {
            guard let first = user.unicodeScalars.first, user.count <= 32 else { return false }
            let lead = first == "_" || (first.isASCII && first.properties.isAlphabetic)
            return lead && user.unicodeScalars.allSatisfy {
                $0.isASCII && ($0.properties.isAlphabetic || ("0" ... "9").contains($0) || $0 == "_" || $0 == "-")
            }
        }

        static func isUsableRsync(_ path: String) -> Bool {
            path.hasPrefix("/") && !path.contains("\n") && FileManager.default.isExecutableFile(atPath: path)
        }

        // MARK: Push arguments

        static func sshCommand() -> String {
            [
                sshPath, "-F", "/dev/null", "-i", "id_ed25519",
                "-o", "IdentitiesOnly=yes", "-o", "IdentityAgent=none",
                "-o", "StrictHostKeyChecking=yes", "-o", "UserKnownHostsFile=known_hosts",
                "-o", "GlobalKnownHostsFile=/dev/null", "-o", "UpdateHostKeys=no",
                "-o", "BatchMode=yes", "-o", "PasswordAuthentication=no",
                "-o", "ConnectTimeout=20", "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=2",
                "-o", "ForwardAgent=no", "-o", "ClearAllForwardings=yes",
            ].joined(separator: " ")
        }

        /// Filter rules (spec 04 review): even if the remote lacked its rrsync
        /// forced command, only these four top-level names can be sent or
        /// deleted. Files excluded on the receiver are not deleted (no
        /// --delete-excluded). manifest.json is excluded from pass 1.
        static let pass1Filters = [
            "--exclude=/manifest.json",
            "--include=/vault/***",
            "--include=/calendar-remote.json",
            "--include=/DISABLED",
            "--exclude=*",
        ]

        /// `staging` is a directory name relative to the child's working directory.
        static func pushCommands(
            user: String, host: String, rsync: String, staging: String = "staging", ssh: String = sshCommand(),
            destination: String = "/"
        ) -> [(executable: String, arguments: [String])] {
            let target = host.contains(":") ? "[\(host)]" : host
            let remote = "\(user)@\(target)"
            let base = destination.hasSuffix("/") ? destination : destination + "/"
            return [
                (
                    rsync,
                    ["-rlt", "--delete", "--timeout=60"] + pass1Filters + [
                        "-e",
                        ssh,
                        "\(staging)/",
                        "\(remote):\(base)",
                    ]
                ),
                (
                    rsync,
                    ["-lt", "--timeout=60", "-e", ssh, "\(staging)/manifest.json", "\(remote):\(base)manifest.json"]
                ),
            ]
        }

        // MARK: Host key lines

        /// `host ssh-ed25519 <base64>`, rebuilt from validated fields only.
        static func parseKeyscan(_ output: String, host: String) -> String? {
            for raw in output.split(whereSeparator: \.isNewline) where !raw.hasPrefix("#") {
                let fields = raw.split(separator: " ")
                guard fields.count >= 3, fields[1] == "ssh-ed25519" else { continue }
                let blob = String(fields[2])
                guard !blob.isEmpty,
                      blob
                      .allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "+" || $0 == "/" || $0 == "=") })
                else { continue }
                return "\(host) ssh-ed25519 \(blob)"
            }
            return nil
        }

        /// known_hosts text with `line` replacing any existing line for `host`.
        static func knownHosts(_ existing: String, setting line: String, for host: String) -> String {
            var lines = existing.split(whereSeparator: \.isNewline).map(String.init).filter { !lineIsHost($0, host) }
            lines.append(line)
            return lines.joined(separator: "\n") + "\n"
        }

        /// known_hosts text keeping only lines whose host is in `hosts`.
        static func knownHosts(_ existing: String, keeping hosts: Set<String>) -> String {
            let kept = existing.split(whereSeparator: \.isNewline).map(String.init).filter { line in
                hosts.contains { lineIsHost(line, $0) }
            }
            return kept.isEmpty ? "" : kept.joined(separator: "\n") + "\n"
        }

        static func knownHosts(_ text: String, contains host: String) -> Bool {
            text.split(whereSeparator: \.isNewline).contains { lineIsHost(String($0), host) }
        }

        private static func lineIsHost(_ line: String, _ host: String) -> Bool {
            line.split(separator: " ").first.map { $0.lowercased() == host.lowercased() } ?? false
        }

        /// "user@host" entries of the pushed-targets set.
        static func target(user: String, host: String) -> String {
            "\(user)@\(host)"
        }

        static func split(target: String) -> (user: String, host: String)? {
            guard let at = target.firstIndex(of: "@") else { return nil }
            return (String(target[..<at]), String(target[target.index(after: at)...]))
        }

        /// Case-insensitive canonical comparison of two vault roots.
        static func canonical(_ url: URL) -> String {
            url.resolvingSymlinksInPath().standardizedFileURL.path.lowercased()
        }

        static func tail(_ text: String, limit: Int = 2048) -> String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.count <= limit ? trimmed : String(trimmed.suffix(limit))
        }

        // MARK: Processes

        /// Runs a child in its own process group with a clean environment.
        /// Never blocks on a pipe a grandchild may hold: output is read with
        /// dispatch sources, the group is killed when the child exits, and the
        /// result is delivered at most `grace` seconds after the exit.
        static func runProcess(
            _ executable: String, _ arguments: [String], directory: URL, timeout: TimeInterval,
            grace: TimeInterval = 0.5
        ) async -> ProcessResult {
            if Task.isCancelled {
                return ProcessResult(status: -1, stdout: "", stderr: "cancelled", timedOut: false)
            }
            let child = ChildProcess()
            return await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    child.start(
                        executable: executable, arguments: arguments, directory: directory,
                        timeout: timeout, grace: grace, continuation: continuation
                    )
                }
            } onCancel: {
                child.cancel()
            }
        }
    }

    /// Which operation runs next. Pure so its ordering can be tested.
    struct JobPlanner {
        enum Operation: Equatable { case sync, wipe }
        enum Decision: Equatable {
            case run(Operation)
            case backoff(until: Date)
            case idle
        }

        var syncRequested = false
        var wipeRequested = false
        var notBefore = Date.distantPast

        /// A wipe always wins and is never delayed by the failure backoff.
        mutating func next(now: Date, enabled: Bool) -> Decision {
            if wipeRequested {
                wipeRequested = false
                return .run(.wipe)
            }
            guard syncRequested, enabled else { return .idle }
            syncRequested = false
            if now < notBefore {
                return .backoff(until: notBefore)
            }
            return .run(.sync)
        }

        /// Toggle off: nothing may export or push again until re-enabled.
        mutating func killSwitch() {
            syncRequested = false
            wipeRequested = true
        }

        mutating func enable() {
            wipeRequested = false
            syncRequested = true
            notBefore = .distantPast
        }
    }

    private final class ChildProcess: @unchecked Sendable {
        private let lock = NSLock()
        private let queue = DispatchQueue(label: "com.rchaight.notetaker.remote-child")
        private var pid: pid_t = 0
        private var cancelled = false
        private var timedOut = false
        private var exited = false
        private var finished = false
        private var status: Int32 = 0
        private var eof = 0
        private var out = Data()
        private var err = Data()
        private var sources: [DispatchSourceRead] = []
        private var continuation: CheckedContinuation<ProcessResult, Never>?
        private static let cap = 16 * 1024

        func start(
            executable: String, arguments: [String], directory: URL, timeout: TimeInterval,
            grace: TimeInterval, continuation: CheckedContinuation<ProcessResult, Never>
        ) {
            lock.lock()
            self.continuation = continuation
            lock.unlock()

            var outFds: [Int32] = [0, 0]
            var errFds: [Int32] = [0, 0]
            guard pipe(&outFds) == 0 else { return fail("could not create pipe") }
            guard pipe(&errFds) == 0 else {
                close(outFds[0]); close(outFds[1])
                return fail("could not create pipe")
            }

            var actions: posix_spawn_file_actions_t?
            posix_spawn_file_actions_init(&actions)
            posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
            posix_spawn_file_actions_adddup2(&actions, outFds[1], 1)
            posix_spawn_file_actions_adddup2(&actions, errFds[1], 2)
            posix_spawn_file_actions_addchdir_np(&actions, directory.path)
            var attributes: posix_spawnattr_t?
            posix_spawnattr_init(&attributes)
            posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT))
            posix_spawnattr_setpgroup(&attributes, 0)

            let argv: [UnsafeMutablePointer<CChar>?] = ([executable] + arguments).map { strdup($0) } + [nil]
            let envp: [UnsafeMutablePointer<CChar>?] = [strdup("PATH=/usr/bin:/bin"), nil]
            var childPid: pid_t = 0
            let rc = posix_spawn(&childPid, executable, &actions, &attributes, argv, envp)
            argv.forEach { free($0) }
            envp.forEach { free($0) }
            posix_spawn_file_actions_destroy(&actions)
            posix_spawnattr_destroy(&attributes)
            close(outFds[1])
            close(errFds[1])
            guard rc == 0 else {
                close(outFds[0]); close(errFds[0])
                return fail("could not launch \(executable)")
            }

            lock.lock()
            pid = childPid
            let alreadyCancelled = cancelled
            lock.unlock()

            attach(fd: outFds[0], isOut: true)
            attach(fd: errFds[0], isOut: false)
            // Reap on a background thread; the group kill then also ends any
            // grandchild (ssh) still holding the pipes.
            DispatchQueue.global().async { [self] in
                var raw: Int32 = 0
                while waitpid(childPid, &raw, 0) == -1, errno == EINTR {}
                let code: Int32 = raw & 0x7F == 0 ? (raw >> 8) & 0xFF : 128 + (raw & 0x7F)
                lock.lock()
                exited = true
                status = code
                lock.unlock()
                killpg(childPid, SIGKILL)
                queue.async { self.finishIfDrained() }
                queue.asyncAfter(deadline: .now() + grace) { self.finish() }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [self] in
                lock.lock()
                let skip = exited || finished
                if !skip {
                    timedOut = true
                }
                lock.unlock()
                if !skip {
                    terminateGroup()
                }
            }
            if alreadyCancelled {
                terminateGroup()
            } // cancel arrived before the pid existed
        }

        func cancel() {
            lock.lock()
            cancelled = true
            let running = pid > 0 && !exited
            lock.unlock()
            if running {
                terminateGroup()
            }
        }

        private func terminateGroup() {
            lock.lock()
            let target = pid
            lock.unlock()
            guard target > 0 else { return }
            killpg(target, SIGTERM)
            queue.asyncAfter(deadline: .now() + 2) { [self] in
                lock.lock()
                let done = exited
                lock.unlock()
                if !done {
                    killpg(target, SIGKILL)
                }
            }
        }

        private func attach(fd: Int32, isOut: Bool) {
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            source.setEventHandler { [self] in
                var buffer = [UInt8](repeating: 0, count: 64 * 1024)
                let count = read(fd, &buffer, buffer.count)
                if count > 0 {
                    append(Data(buffer[0 ..< count]), isOut: isOut)
                } else if count == 0 || errno != EAGAIN {
                    source.cancel()
                    lock.lock()
                    eof += 1
                    lock.unlock()
                    finishIfDrained()
                }
            }
            source.setCancelHandler { close(fd) }
            lock.lock()
            sources.append(source)
            lock.unlock()
            source.resume()
        }

        private func append(_ data: Data, isOut: Bool) {
            lock.lock()
            defer { lock.unlock() }
            if isOut {
                out.append(data)
                if out.count > Self.cap {
                    out = out.suffix(Self.cap)
                }
            } else {
                err.append(data)
                if err.count > Self.cap {
                    err = err.suffix(Self.cap)
                }
            }
        }

        private func finishIfDrained() {
            lock.lock()
            let done = exited && eof >= 2
            lock.unlock()
            if done {
                finish()
            }
        }

        private func fail(_ message: String) {
            lock.lock()
            let continuation = continuation
            self.continuation = nil
            finished = true
            lock.unlock()
            continuation?.resume(returning: ProcessResult(status: -1, stdout: "", stderr: message, timedOut: false))
        }

        private func finish() {
            lock.lock()
            guard !finished else { lock.unlock(); return }
            finished = true
            let continuation = continuation
            self.continuation = nil
            let pending = sources
            sources = []
            let result = ProcessResult(
                status: status, stdout: String(decoding: out, as: UTF8.self),
                stderr: String(decoding: err, as: UTF8.self), timedOut: timedOut
            )
            lock.unlock()
            pending.forEach { $0.cancel() } // closes the read ends
            continuation?.resume(returning: result)
        }
    }
#endif
