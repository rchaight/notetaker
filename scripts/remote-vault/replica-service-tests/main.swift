import Darwin
import Foundation

var failures = 0
func check(_ ok: Bool, _ name: String) {
    if !ok {
        failures += 1
    }
    print((ok ? "ok   " : "FAIL ") + name)
}

typealias S = RemoteReplicaSupport
let fm = FileManager.default

// MARK: validators

let hostCases: [(String, Bool)] = [
    ("100.64.0.1", true), ("100.127.255.254", true), ("100.128.0.1", false), ("100.63.255.255", false),
    ("192.168.5.50", false), ("127.0.0.1", false), ("fd7a:115c:a1e0::1", true), ("fd7a:115c:a1e1::1", false),
    ("fe80::1", false), ("[::1]", false), ("::1", false), ("box.tailnet-1.ts.net", true), ("BOX.TS.NET", true),
    ("box.ts.net.", false), ("ts.net", false), (".ts.net", false), ("-oProxyCommand=x", false),
    ("-oProxyCommand=x.ts.net", false), ("a b.ts.net", false), ("evil.com", false), ("", false),
    ("bóx.ts.net", false), ("box\u{202E}.ts.net", false), ("a..ts.net", false), ("-a.ts.net", false),
]
for (host, expected) in hostCases {
    check(
        S.isValidHost(host) == expected,
        "host \(host.debugDescription) -> \(expected)"
    )
}

for (user, expected) in [
    ("replica", true),
    ("-oFoo", false),
    ("a b", false),
    ("_x", true),
    ("", false),
    ("r@h", false),
    ("é", false),
] {
    check(S.isValidUser(user) == expected, "user \(user.debugDescription) -> \(expected)")
}

// MARK: parseKeyscan

let blob = "AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl"
check(
    S
        .parseKeyscan("# 1.2.3.4:22 SSH-2.0\n1.2.3.4 ssh-ed25519 \(blob)\n", host: "h.ts.net") ==
        "h.ts.net ssh-ed25519 \(blob)",
    "keyscan parses"
)
check(S.parseKeyscan("1.2.3.4 ssh-rsa \(blob)\n", host: "h") == nil, "keyscan rejects rsa")
check(S.parseKeyscan("1.2.3.4 ssh-ed25519 \(blob);rm\n", host: "h") == nil, "keyscan rejects bad base64")
check(S.parseKeyscan("", host: "h") == nil, "keyscan empty")
check(S.parseKeyscan("1.2.3.4 ssh-ed25519\n", host: "h") == nil, "keyscan short line")

// MARK: known_hosts + targets

var kh = S.knownHosts("", setting: "a.ts.net ssh-ed25519 AAA", for: "a.ts.net")
kh = S.knownHosts(kh, setting: "b.ts.net ssh-ed25519 BBB", for: "b.ts.net")
kh = S.knownHosts(kh, setting: "a.ts.net ssh-ed25519 CCC", for: "A.ts.net")
check(kh == "b.ts.net ssh-ed25519 BBB\na.ts.net ssh-ed25519 CCC\n", "known_hosts replaces same host")
check(S.knownHosts(kh, keeping: ["b.ts.net"]) == "b.ts.net ssh-ed25519 BBB\n", "known_hosts keeping")
check(S.knownHosts(kh, keeping: []) == "", "known_hosts keeping none")
check(S.knownHosts(kh, contains: "b.ts.net") && !S.knownHosts(kh, contains: "c.ts.net"), "known_hosts contains")
check(S.split(target: "replica@100.64.0.1")?.host == "100.64.0.1", "split target")

// MARK: planner

var planner = JobPlanner()
planner.syncRequested = true
check(planner.next(now: Date(), enabled: true) == .run(.sync), "planner runs sync")
check(planner.next(now: Date(), enabled: true) == .idle, "planner idle after")
planner.syncRequested = true
planner.notBefore = Date().addingTimeInterval(60)
if case .backoff = planner.next(now: Date(), enabled: true) {
    check(true, "planner backs off")
} else {
    check(
        false,
        "planner backs off"
    )
}

planner.syncRequested = true
planner.killSwitch()
check(planner.next(now: Date(), enabled: false) == .run(.wipe), "kill switch: wipe first, ignores backoff")
check(planner.next(now: Date(), enabled: false) == .idle, "kill switch: pending sync dropped")
planner.syncRequested = true
check(planner.next(now: Date(), enabled: false) == .idle, "disabled: sync never runs")
// off / on / off
planner = JobPlanner(); planner.enable(); planner.killSwitch(); planner.enable(); planner.killSwitch()
check(
    planner.next(now: Date(), enabled: false) == .run(.wipe) && planner.next(now: Date(), enabled: false) == .idle,
    "off/on/off ends with exactly one wipe"
)

// MARK: process runner

func elapsed(_ body: () async -> ProcessResult) async -> (ProcessResult, TimeInterval) {
    let start = Date()
    let result = await body()
    return (result, Date().timeIntervalSince(start))
}

func running(_ marker: String) -> Bool {
    let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep"); p.arguments = ["-f", marker]
    p.standardOutput = FileHandle.nullDevice
    try? p.run(); p.waitUntilExit(); return p.terminationStatus == 0
}

let tmp = fm.temporaryDirectory.appendingPathComponent("rrs-\(getpid())", isDirectory: true)
try? fm.createDirectory(at: tmp, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: tmp) }

var (r, t) = await elapsed { await S.runProcess(
    "/bin/sh",
    ["-c", "echo hi; echo err >&2; exit 3"],
    directory: tmp,
    timeout: 10
) }
check(r.status == 3 && r.stdout == "hi\n" && r.stderr == "err\n" && !r.timedOut, "runner captures output and status")

// A grandchild keeps the pipes open after the parent exits: must not stall.
(r, t) = await elapsed { await S.runProcess(
    "/bin/sh",
    ["-c", "sleep 3101 & echo started; exit 0"],
    directory: tmp,
    timeout: 10
) }
check(
    t < 3 && r.status == 0 && r.stdout == "started\n",
    "grandchild holding the pipe does not stall (\(String(format: "%.2f", t))s)"
)
try? await Task.sleep(for: .milliseconds(300))
check(!running("sleep 3101"), "grandchild killed after parent exit")

(r, t) = await elapsed { await S.runProcess("/bin/sleep", ["3102"], directory: tmp, timeout: 1) }
check(r.timedOut && t < 5, "watchdog kills a hung child (\(String(format: "%.2f", t))s)")

(r, t) = await elapsed { await S.runProcess("/definitely/not/here", [], directory: tmp, timeout: 5) }
check(r.status == -1, "launch failure reported")

/// Cancel while running: whole group dies, call returns promptly.
let cancelTask = Task { await S.runProcess("/bin/sh", ["-c", "sleep 3103 & sleep 3103"], directory: tmp, timeout: 60) }
try? await Task.sleep(for: .milliseconds(400))
let t0 = Date()
cancelTask.cancel()
let cancelled = await cancelTask.value
check(Date().timeIntervalSince(t0) < 4 && cancelled.status != 0, "cancel during push-like child returns promptly")
try? await Task.sleep(for: .milliseconds(300))
check(!running("sleep 3103"), "cancel kills the whole process group")

/// Cancel before the child can start (lost-cancel window).
let early = Task { () -> ProcessResult in
    while !Task.isCancelled {
        await Task.yield()
    }
    return await S.runProcess("/bin/sleep", ["3104"], directory: tmp, timeout: 60)
}

early.cancel()
await check((early.value).status != 0 && !running("sleep 3104"), "cancelled-before-start child never runs")

// MARK: rsync filters (real /usr/bin/rsync + fake ssh)

let fake = tmp.appendingPathComponent("fakessh")
try! """
#!/bin/sh
while [ $# -gt 0 ]; do case "$1" in -F|-i|-o) shift 2;; -*) shift;; *) shift; break;; esac; done
exec "$@"
""".write(to: fake, atomically: true, encoding: .utf8)
chmod(fake.path, 0o755)
let work = tmp.appendingPathComponent("work with space", isDirectory: true)
let inbox = tmp.appendingPathComponent("inbox", isDirectory: true)
func write(_ path: URL, _ text: String) {
    try? fm.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
    try! text.write(to: path, atomically: true, encoding: .utf8)
}

func listing(_ root: URL) -> [String] {
    let e = fm.enumerator(atPath: root.path)?.allObjects as? [String] ?? []
    return e.sorted()
}

func push(staging: String) async -> Bool {
    let cmds = S.pushCommands(user: "replica", host: "100.64.0.1", rsync: "/usr/bin/rsync", staging: staging,
                              ssh: fake.path, destination: inbox.path)
    for c in cmds {
        let res = await S.runProcess(c.executable, c.arguments, directory: work, timeout: 60)
        if res.status != 0 {
            print("   rsync failed:", res.status, res.stderr); return false
        }
    }
    return true
}

write(work.appendingPathComponent("staging/vault/a.md"), "a")
write(work.appendingPathComponent("staging/vault/sub/b.md"), "b")
write(work.appendingPathComponent("staging/calendar-remote.json"), "{}")
write(work.appendingPathComponent("staging/manifest.json"), "{\"v\":2}")
// Remote state: stale replica content AND unrelated files a mis-restricted account could reach.
write(inbox.appendingPathComponent("vault/gone.md"), "x")
write(inbox.appendingPathComponent("manifest.json"), "old")
write(inbox.appendingPathComponent("unrelated.txt"), "keep")
write(inbox.appendingPathComponent("unrelated-dir/inner.txt"), "keep")
write(inbox.appendingPathComponent("vaultx/keep.md"), "keep")
await check(push(staging: "staging"), "full push succeeds (path with space, relative -e paths)")
var l = listing(inbox)
check(
    l.contains("vault/a.md") && l.contains("vault/sub/b.md") && l.contains("calendar-remote.json"),
    "pushed files arrived"
)
check(!l.contains("vault/gone.md"), "--delete removed stale vault content")
check(
    l.contains("unrelated.txt") && l.contains("unrelated-dir/inner.txt") && l.contains("vaultx/keep.md"),
    "unrelated file/dir survive full push"
)
check((try? String(contentsOf: inbox.appendingPathComponent("manifest.json"))) == "{\"v\":2}", "manifest delivered")
let mtimes = l.filter { !$0.hasPrefix("unrelated") && !$0.hasPrefix("vaultx") }.compactMap { name -> (String, Date)? in
    guard let d = (try? fm
        .attributesOfItem(atPath: inbox.appendingPathComponent(name).path))?[.modificationDate] as? Date
    else { return nil }
    return (name, d)
}

check(
    mtimes.first { $0.0 == "manifest.json" }
        .map { m in mtimes.filter { !$0.0.hasSuffix("/") }.allSatisfy { m.1 >= $0.1 } } ?? false,
    "manifest mtime is the newest"
)

// Kill-switch image: DISABLED + manifest only.
try? fm.removeItem(at: work.appendingPathComponent("staging"))
write(work.appendingPathComponent("staging/DISABLED"), "")
write(work.appendingPathComponent("staging/manifest.json"), "{\"disabled\":true}")
await check(push(staging: "staging"), "disabled-image push succeeds")
l = listing(inbox)
check(
    !l.contains { $0.hasPrefix("vault/") } && !l.contains("calendar-remote.json"),
    "disabled push removes old vault/ and calendar"
)
check(
    l
        .contains("DISABLED") && (try? String(contentsOf: inbox.appendingPathComponent("manifest.json"))) ==
        "{\"disabled\":true}",
    "DISABLED + new manifest present"
)
check(
    l.contains("unrelated.txt") && l.contains("unrelated-dir/inner.txt") && l.contains("vaultx/keep.md"),
    "unrelated file/dir survive disabled push"
)

print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
