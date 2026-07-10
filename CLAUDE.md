# Notetaker — agent guide

Native macOS 26+/iOS 26+ universal SwiftUI app: markdown notes + inline todos + project management, everything stored in iCloud. Read FEATURES.md (design decisions) and PLAN.md (milestones) before nontrivial work; log build-loop passes in PROGRESS.md.

## The one invariant

**Plain `.md` files in the iCloud Drive vault are the single source of truth. The GRDB index (IndexKit) is derived and must always be rebuildable from the files.** Never write app state that cannot be reconstructed by re-scanning the vault. UI task mutations (check-off, reschedule) edit the source markdown line via coordinated file writes — never only the index.

## Architecture / module boundaries

- `App/` — app target: shell (adaptive TabView + NavigationSplitView), scenes, composition root. No business logic.
- `Packages/VaultKit` — iCloud Drive file layer: NSFileCoordinator/NSFilePresenter, NSMetadataQuery observation, conflict detection. Owns ALL file I/O.
- `Packages/MarkdownKit` — swift-markdown parsing/AST, frontmatter, todo/tag/wikilink extraction. Pure; no I/O.
- `Packages/EditorKit` — TextKit 2 live-preview editor (NS/UIViewRepresentable), Liquid Glass chrome.
- `Packages/IndexKit` — GRDB derived index + FTS5. Rebuildable; schema-version guard drops + rescans.
- `Packages/TaskEngine` — dates, priorities, recurrence (ONE engine for every surface), filters. Pure; no I/O.
- `Packages/ProjectKit` — projects/Gantt/dependencies as views over TaskEngine + IndexKit data.
- `Packages/ConversionKit` — import pipeline (Vision/Speech native paths; Docling via File-Parser on macOS).
- `Packages/AIKit` — `AIProvider` protocol: FoundationModels | Ollama | None. Private/on-device by default.
- `Packages/SecurityKit` — app lock (LocalAuthentication), per-note locking, Keychain.
- `Packages/AppIntentsKit` — App Intents (Add Task / Create Note) feeding Siri/Shortcuts/widgets.

Dependencies point downward only (App → packages; packages never import App). Pure packages (MarkdownKit, TaskEngine) must stay I/O-free.

## Build & verify

- `Notetaker.xcodeproj` is GENERATED — edit `project.yml`, then `xcodegen generate`. Never hand-edit the pbxproj.
- Build: `xcodebuild -project Notetaker.xcodeproj -scheme Notetaker -destination 'platform=macOS' build`
- iOS: same with `-destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO`
- Package tests: `cd Packages/<Kit> && swift test`
- Formatting: `swiftformat --lint .`

## Current signing state

Ad-hoc (`CODE_SIGN_IDENTITY: "-"`, team 6A2NHN89Q8). No Apple Development cert on this machine yet — the user must sign into Xcode before the iCloud container entitlement (M1) can be enabled. Developer ID cert exists for eventual .dmg distribution (M10).

## Build-loop conventions

One PLAN.md checkbox step per pass: implement → verify (build/test/launch, not just compile) → one commit containing the code AND the checked box AND a PROGRESS.md pass-log row. Break at milestone boundaries for user review. Commit messages start with `M<n>.<step>:`.
