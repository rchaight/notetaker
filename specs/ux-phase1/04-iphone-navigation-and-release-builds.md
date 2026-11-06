# 04 — iPhone navigation (To-Do, Tags), no Vault tab on iOS, Release installs

## Goal

On an iPhone, the To-Do and Tags tabs reach their detail column; the Debug-only Vault tab never ships to the phone; `scripts/install-ios.sh` installs a Release build by default. macOS behaviour is unchanged.

## Verified findings

- **To-Do sidebar** (`App/Todo/TodoView.swift:274-300`): `List { … }` with no `selection:`; rows use `.onTapGesture` to set `viewModeRaw` / `filterText`. PROGRESS row 228 established that a compact `NavigationSplitView` pushes the detail only when the List's **own** selection becomes non-nil. Nothing here sets one, so on compact width the user stays on the sidebar. Could not run the phone; the mechanism is the same one row 228 fixed, so the claim is treated as correct and the builder confirms it on the device before and after.
- **Tags sidebar** (`App/Notes/TagsView.swift:159`): `List(selection: $selectedTags)` bound to `Set<String>`. On iOS a Set-bound List selects only in edit mode, and a Set selection never drives the compact push. Claim correct. `selectedTags` is used in 15 places (rename, merge, bulk bar, `selectedTag` computed at `:25-27`).
- **Vault tab**: iOS `TabView` at `AppShell.swift:181-185` wraps `Tab("Vault")` in `#if DEBUG`; the phone currently runs Debug (`install-ios.sh:16,76,80`: `-configuration Debug`, `Debug-iphoneos`), so it shows 7 tabs. The macOS tab list (`:33-49`) and `mountedViews` (`:203-205`) are macOS-only paths. iOS Settings already has a Vault pane (`SettingsView.swift:498-504`, read-only text).
- **Signing**: `project.yml` sets `CODE_SIGN_STYLE: Automatic`, `DEVELOPMENT_TEAM`, no per-configuration identity override, and the script passes `-allowProvisioningUpdates`. With automatic signing, a Release build for `generic/platform=iOS` signs with the same Apple Development identity and development profile as Debug (distribution identities are only chosen when archiving/exporting), so `devicectl install` keeps working. Differences that matter: `#if DEBUG` code is compiled out (Vault tab, Settings › Debug tab), `-O`/whole-module, assertions off, `get-task-allow` false (no debugger attach), `ENABLE_TESTABILITY` off. Release has never been built for iOS in this repo, so a Release-only compile error is possible (e.g. a symbol referenced outside a `#if DEBUG` guard).

## Design

**TodoView (iOS only; macOS untouched)**

```swift
private enum SidebarItem: Hashable { case mode(ViewMode), filter(String) }
#if os(iOS)
@State private var sidebarSelection: SidebarItem?
#endif
```
- In `sidebarLists`, under `#if os(iOS)`: `List(selection: $sidebarSelection)`, rows tagged `.tag(SidebarItem.mode(mode))` / `.tag(.filter(saved))`, no `onTapGesture`, no `listRowBackground` hack; `.onChange(of: sidebarSelection)` applies `viewModeRaw` / `filterText` exactly as the tap handlers do. Popping back to the sidebar clears the selection (compact split-view behaviour), so a second tap works. Keep the `#else` branch byte-identical to today.
- Detail toolbar already exists (`:103-125`); no change.

**TagsView (iOS only)**

- `#if os(iOS) @State private var selectedTagSingle: String?`; the List uses `selection: $selectedTagSingle` on iOS and `$selectedTags` on macOS; `.onChange(of: selectedTagSingle) { selectedTags = $0.map { [$0] } ?? [] }`. Everything downstream keeps reading `selectedTags`/`selectedTag`. Bulk bar (needs >1) never shows on iOS — acceptable; the context-menu actions stay.

**AppShell**

- Delete the `#if DEBUG Tab("Vault")` block from the iOS `TabView` (`:181-185`). macOS keeps its Debug Vault tab. Add a "Rebuild index" button to the iOS Settings › Vault pane **only if** `SettingsView` already has access to `VaultIndexService` (it does not appear to — `grep indexService App/Shell/SettingsView.swift` is empty); otherwise skip and note it in the PROGRESS row. Rescans happen automatically on launch.

**scripts/install-ios.sh**

- `CONFIG=Release` by default; `--debug` flag switches to Debug. `APP="$DERIVED/Build/Products/$CONFIG-iphoneos/Notetaker.app"`; `-configuration "$CONFIG"` in both the plan text and the build. Header comment and `PLAN` output mention the configuration.
- Before the first device run, prove Release compiles without a phone: `DEVELOPER_DIR=/Applications/Xcode.app xcodebuild -project Notetaker.xcodeproj -scheme Notetaker -configuration Release -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO -derivedDataPath ~/.cache/notetaker-build/DerivedData-ios-release build`. Add that command to `scripts/verify.sh` as a third build (decision for Robert; default: yes, it costs one more build).

## Acceptance criteria

1. iPhone To-Do: tapping Today/Overdue/Upcoming/Inbox/a saved filter pushes the task list; back returns to the sidebar; tapping again works. Mac: rows highlight and switch exactly as before (no selection highlight change, `listRowBackground` kept).
2. iPhone Tags: tapping a tag pushes its detail; rename/merge/remove from the context menu still work; Mac multi-select and bulk bar unchanged.
3. The installed phone build shows six tabs (Notes, To-Do, Projects, Meetings, Calendar, Tags) and Settings has no Debug tab.
4. `scripts/install-ios.sh` prints `-configuration Release` in its plan; `--yes` installs, launches, and the build-number check passes; `--debug` restores the old behaviour.
5. `scripts/verify.sh 3 --install` passes (with the Release simulator build if added).

## Files expected to change

`App/Todo/TodoView.swift`, `App/Notes/TagsView.swift` (selection only — spec 01's confirmation dialogs touch the same file; build them in the same pass or sequentially), `App/Shell/AppShell.swift`, `App/Shell/SettingsView.swift` (optional), `scripts/install-ios.sh`, `scripts/verify.sh` (optional), `CLAUDE.md` iPhone-install bullet (mention Release/`--debug`).
Must NOT touch: `project.yml` (spec 06 owns it), `NotesView.swift`, `NotesModel.swift`, any package.

## Test plan

No package logic changes. Verification is build + device:
- Both builds via `verify.sh`; the Release iOS simulator build above.
- Device: `scripts/install-ios.sh --yes` with the phone unlocked; walk acceptance 1-3 by hand (the orchestrator lists them in the manual checklist).
- Regression: on the Mac, To-Do sidebar highlight, saved-filter toggle (tap again clears), Tags multi-select + "Merge Into"/"Delete All" bar.

## Non-goals

The four-tab iPhone shell (Phase 3), iPhone headers/accessory bar, Settings redesign, changing macOS selection models, TestFlight/App Store signing.

## Risks / invariants

- **Compact-selection trap (PROGRESS 228):** the fix is "the List's own selection"; do not try to drive navigation through the model.
- **macOS toolbar-bridge trap:** no new `.toolbar`/`.navigationTitle` on detail panes; the iOS-only code must stay under `#if os(iOS)`.
- Release build: a Release-only compile failure blocks the phone install; the simulator Release build catches it on the Mac first.
- Once the phone runs Release, there is no in-app Vault debug view on iOS; the Mac keeps it.

## Builder model

sonnet.
