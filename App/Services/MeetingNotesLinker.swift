#if os(macOS)
    import Foundation
    import MarkdownKit
    import VaultKit

    /// Links Audio Transcribe's `type: meeting-notes` files into their day's daily note: a
    /// `[[link]]`, the notes' `## Summary` and an open-action-item count go under the meeting's
    /// `# <time> — <title>` heading (`MeetingNotesInsertion` plans it). The link in the daily
    /// note is the ONLY record that this happened — no flags, nothing outside the files.
    ///
    /// Mac only: one device inserts, the edit syncs (two devices inserting at once would
    /// duplicate the block). Writes go through the editor's model when the daily note is on
    /// screen (`NotesModel.applyAutomaticEdit`), else through `VaultIndexService`'s
    /// coordinated write path — and only while the editor holds nothing for that note. Busy
    /// means skip and retry; it never means write anyway.
    @MainActor
    final class MeetingNotesLinker {
        /// UserDefaults key for Settings › Calendar › "Link meeting notes into the daily note".
        nonisolated static let enabledKey = "linkMeetingNotes"
        /// Meeting notes dated within this many days back from today are linked.
        nonisolated static let lookbackDays = 7
        /// Typing must have paused this long before the on-screen daily note is edited.
        static let editorIdle: TimeInterval = 5
        private static let settleDebounce: Duration = .seconds(3)
        private static let retryDelay: Duration = .seconds(30)

        /// Default on: a raw read sees `false` for an absent key, so absent counts as true.
        nonisolated static func isEnabled() -> Bool {
            (UserDefaults.standard.object(forKey: enabledKey) as? Bool) ?? true
        }

        private weak var indexService: VaultIndexService?
        private weak var notesModel: NotesModel?
        private let store = VaultFileStore()
        private var started = false
        private var triggers: [Task<Void, Never>] = []
        private var scheduled: Task<Void, Never>?
        private var running = false
        private var rerun = false
        private var wasEnabled = MeetingNotesLinker.isEnabled()

        func start(indexService: VaultIndexService, notesModel: NotesModel) {
            self.indexService = indexService
            self.notesModel = notesModel
            guard !started else { return }
            started = true
            // Every index pass (vault changes, our own writes, the first scan at launch) is a
            // trigger; a pass that finds everything linked writes nothing, so it settles.
            triggers.append(Task { [weak self] in
                for await _ in NotificationCenter.default
                    .notifications(named: VaultIndexService.didSettleNotification) {
                    guard let self else { return }
                    schedule(after: Self.settleDebounce)
                }
            })
            triggers.append(Task { [weak self] in
                for await _ in NotificationCenter.default.notifications(named: UserDefaults.didChangeNotification) {
                    guard let self else { return }
                    let enabled = Self.isEnabled()
                    if enabled, !wasEnabled {
                        schedule(after: .seconds(1))
                    }
                    wasEnabled = enabled
                }
            })
            schedule(after: Self.settleDebounce) // once at launch
        }

        func stop() {
            for task in triggers {
                task.cancel()
            }
            scheduled?.cancel()
        }

        private func schedule(after delay: Duration) {
            scheduled?.cancel()
            scheduled = Task { [weak self] in
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled else { return }
                await self?.run()
            }
        }

        private func run() async {
            guard !running else {
                rerun = true
                return
            }
            running = true
            var retry = await pass()
            while rerun {
                rerun = false
                retry = await pass()
            }
            running = false
            if retry {
                schedule(after: Self.retryDelay)
            }
        }

        /// One pass over the recent meeting notes. Returns true when something was skipped
        /// for now (editor busy, conflict, failed write) and a later pass should retry.
        private func pass() async -> Bool {
            guard Self.isEnabled(), let indexService, let notesModel, indexService.state == .ready,
                  let root = indexService.vaultRootURL else { return false }
            let policy = ExportPolicy(excludedFolders: RemoteReplicaService.excludedFolders())
            var retry = false
            for (noteId, day) in indexService.meetingNoteDays.sorted(by: { $0.key < $1.key })
                where Self.isRecent(day) {
                let dailyId = "Daily/\(day).md"
                // Only ever a daily note: never the notes file itself, `_index.md` or `.trash/`.
                guard MeetingNote.isDay(day), dailyId != noteId, !VaultPath.isInsideHiddenFolder(noteId),
                      !VaultFileStore.isIndexFile(noteId) else { continue }
                let noteURL = root.appendingPathComponent(noteId)
                let dailyURL = root.appendingPathComponent(dailyId)
                // Never creates the daily note, and never waits on an iCloud download: a missing
                // or not-yet-downloaded file is picked up by a later pass.
                guard FileManager.default.fileExists(atPath: dailyURL.path),
                      FileManager.default.fileExists(atPath: noteURL.path),
                      let source = try? await store.readString(at: noteURL),
                      let note = MeetingNote.parse(noteId: noteId, source: source, policy: policy)
                else { continue }

                let transform: (String) -> String? = { text in
                    if case let .insert(updated) = MeetingNotesInsertion.plan(dailyNote: text, note: note) {
                        return updated
                    }
                    return nil // .alreadyLinked: never write
                }
                switch await notesModel.applyAutomaticEdit(to: dailyId, idle: Self.editorIdle, transform: transform) {
                case .applied, .unchanged:
                    continue
                case .deferred:
                    retry = true
                    continue
                case .notOpen:
                    break
                }
                let clearance = notesModel.editorClearance(for: dailyId)
                let outcome = await indexService.applyAutomaticEdit(
                    to: dailyId,
                    editorIsClear: { [weak notesModel] in
                        clearance != nil && notesModel?.editorClearance(for: dailyId) == clearance
                    },
                    transform: transform
                )
                if outcome == .deferred {
                    retry = true
                }
            }
            return retry
        }

        /// `yyyy-MM-dd` from today back `lookbackDays` days, inclusive.
        nonisolated static func isRecent(_ day: String, now: Date = Date(), calendar: Calendar = .current) -> Bool {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.calendar = calendar
            formatter.timeZone = calendar.timeZone
            formatter.dateFormat = "yyyy-MM-dd"
            guard let date = formatter.date(from: day) else { return false }
            let today = calendar.startOfDay(for: now)
            guard let earliest = calendar.date(byAdding: .day, value: -lookbackDays, to: today) else { return false }
            return date >= earliest && date <= today
        }
    }
#endif
