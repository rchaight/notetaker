#if os(macOS)
    import CalendarKit
    import EventKit
    import Foundation
    import os

    /// Keeps the opt-in calendar snapshot (`Index/calendar-snapshot.json`)
    /// fresh for the bundled `notetaker-mcp` server. Derived data: deleted
    /// when sharing is off, rewritten whenever it could be stale. No-ops
    /// unless the user turned sharing on AND calendar access is granted.
    @MainActor
    final class CalendarSnapshotPublisher {
        static let shareKey = "calendarShareWithMCP"
        private static let log = Logger(subsystem: "com.rchaight.notetaker", category: "CalendarSnapshot")
        /// Rewrite an unchanged snapshot once it is this old so the server's
        /// `generated_at`/`stale` keep meaning "the app was running".
        private static let refreshAge: TimeInterval = 10 * 60

        private var tasks: [Task<Void, Never>] = []
        private var pending: Task<Void, Never>?
        private var lastConfig: String?

        /// `<Application Support>/Index/calendar-snapshot.json`, beside index.sqlite.
        static var snapshotURL: URL? {
            try? FileManager.default
                .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                .appendingPathComponent("Index", isDirectory: true)
                .appendingPathComponent("calendar-snapshot.json")
        }

        static var isSharingEnabled: Bool {
            UserDefaults.standard.bool(forKey: shareKey)
        }

        private static func configKey() -> String {
            "\(isSharingEnabled)|\(CalendarService.excludedCalendarIds().sorted())"
        }

        /// Deletes the snapshot. Static so Settings can honor "off" even when
        /// the main window (which owns the publisher instance) is closed.
        static func deleteIfPresent() {
            guard let url = snapshotURL, FileManager.default.fileExists(atPath: url.path) else { return }
            do {
                try FileManager.default.removeItem(at: url)
            } catch {
                log.error("could not delete snapshot: \(error.localizedDescription)")
            }
        }

        func start() {
            guard tasks.isEmpty else { return }
            lastConfig = Self.configKey()
            refresh()

            tasks.append(Task { [weak self] in
                for await _ in NotificationCenter.default.notifications(named: .EKEventStoreChanged) {
                    self?.schedule()
                }
            })
            tasks.append(Task { [weak self] in
                for await _ in NotificationCenter.default.notifications(named: UserDefaults.didChangeNotification) {
                    guard let self else { return }
                    let key = Self.configKey()
                    if key != lastConfig {
                        lastConfig = key
                        schedule()
                    }
                }
            })
            tasks.append(Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(30 * 60))
                    self?.refresh()
                }
            })
        }

        /// Call when the share toggle flips (also covered by the defaults observer).
        func settingsChanged() {
            lastConfig = Self.configKey()
            refresh()
        }

        private func schedule() {
            pending?.cancel()
            pending = Task { [weak self] in
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
                self?.refresh()
            }
        }

        /// Writes, rewrites or deletes the snapshot to match current settings.
        func refresh() {
            guard let url = Self.snapshotURL else { return }
            guard Self.isSharingEnabled else {
                Self.deleteIfPresent()
                return
            }
            guard CalendarService.accessState() == .granted else { return }

            let snapshot = CalendarService.snapshot(daysBack: 1, daysAhead: 28)
            do {
                if let existing = try? SnapshotCodec.decode(Data(contentsOf: url)),
                   existing.sameContent(as: snapshot),
                   snapshot.generatedAt.timeIntervalSince(existing.generatedAt) < Self.refreshAge {
                    return
                }
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(), withIntermediateDirectories: true
                )
                try SnapshotCodec.encode(snapshot).write(to: url, options: .atomic)
            } catch {
                Self.log.error("could not write snapshot: \(error.localizedDescription)")
            }
        }
    }

    private extension CalendarSnapshot {
        /// Everything except `generatedAt`.
        func sameContent(as other: CalendarSnapshot) -> Bool {
            rangeStart == other.rangeStart && rangeEnd == other.rangeEnd && timeZone == other.timeZone
                && calendars == other.calendars && events == other.events
        }
    }
#endif
