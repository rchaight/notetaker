# 03 — Quick Add preserves every token

## Goal

`QuickAddParser.parse` emits a line that carries everything the user typed (`@person ?kind ~start ^id blockedby:/depends: &rec`), in one deterministic order, idempotently, using `TaskTokenParser` as the only parser. The app's AI-assisted Quick Add can no longer drop tokens either.

## Verified findings

- `Packages/TaskEngine/Sources/TaskEngine/QuickAdd.swift:28-56`: after `TaskTokenParser.parse`, the line is rebuilt from `cleanText` + `>due` + `!pN` + `&rec` only, and the returned metadata is re-initialised with just five fields (`:52-55`). `TaskTokenParser.parse` (`TaskTokenParser.swift:64-88`) strips `~start ^id blockedby: ✅ @ ?` from `cleanText`, so they are lost. Plan claim correct. `#tag` survives because labels stay in `cleanText`.
- `TaskLineRewriter.replacingText` (`TaskLineRewriter.swift:53-96`) already serialises a full `ParsedTaskMetadata` in a fixed order: `>due ~start !pN &rec ^id blockedby:^x… @person ?kind ✅day`. That is the canonical order to reuse.
- Entry points: `HeadlessVaultWriter.addTask` (`App/Services/HeadlessVaultWriter.swift:19-27`; menu bar `MenuBarQuickAdd.swift:44`, App Intents `NotetakerIntents.swift:21`) calls `QuickAddParser.parse` directly. The in-app path `VaultIndexService.quickAdd` (`:512`) and the project quick add (`:780`) call `quickAddLine(for:)` (`:534-551`), which routes to `AIRouter.parseTask` unless the input contains `>`, `!p`, `&every` or `&after` (`:535-536`); `@ ? ~ ^ blockedby:` do not count as explicit, and AIKit's `ParsedTask.markdownLine` (`AIKit/AIProvider.swift:18-28`) emits only text/due/priority/labels — a second token-dropping path.
- Existing tests: `QuickAddTests` (6 cases) pin the current output format `- [ ] text #tag >due !pN`, i.e. tags inside the text, then tokens.

## Design

**TaskEngine**

1. New `public extension ParsedTaskMetadata { var tokenSuffix: [String] }` (or `enum TaskLineSerializer { static func tokens(for:) }`) extracted from `replacingText`; `replacingText` calls it. Order unchanged: due, start, priority, recurrence (`rawToken`), blockId, dependsOn (`blockedby:^id` each, in parsed order), assignee, kind, completedDay.
2. `QuickAddParser.parse`:
   - parse with `TaskTokenParser`;
   - natural-language fallbacks only fill `dueDate`/`priority` when the token form is absent (unchanged);
   - `metadata = ParsedTaskMetadata(cleanText: text, dueDate:, startDate: parsed.startDate, priority:, labels: parsed.labels, recurrence:, blockId:, dependsOn:, completedDay:, assignee:, kind:)` — all fields carried;
   - `markdownLine = "- [ ] " + text + (tokens.isEmpty ? "" : " " + tokens.joined(" "))`.
   - `depends:^x` is normalised to `blockedby:^x` (parser treats them as synonyms; the rewriter already writes `blockedby:`). Document it.
3. New `public static func hasExplicitTokens(_ input: String) -> Bool` on `QuickAddParser`: true when the parse yields any of due/start/priority/recurrence/blockId/dependsOn/assignee/kind/completedDay. No local regexes.

**App (low-risk consistency)**

- `VaultIndexService.quickAddLine`: replace the hand-rolled `hasExplicitTokens` string checks with `QuickAddParser.hasExplicitTokens(input)`. Any grammar token now bypasses the model, so the AI path only ever sees token-free text and cannot drop anything.
- `HeadlessVaultWriter.addTask`: unchanged (already the deterministic path).

**Follow-ups, not Phase 1:** (a) AI path merging its result through `tokenSuffix` so a model could add `@person`; (b) giving the headless path the AI parse (would make Siri/menu-bar results device-dependent); (c) Quick Add placing tokens before `#tags` (cosmetic; changes existing test strings).

## Acceptance criteria

1. For every token in the table below, `parse(input).markdownLine` contains it and `metadata` reports it.
2. Idempotent: `parse(stripPrefix(parse(x).markdownLine)).markdownLine == parse(x).markdownLine` for every table row.
3. Deterministic: the same tokens typed in any order produce the same line.
4. `TaskTokenParser.parse` of the produced line (minus `- [ ] `) round-trips every field (IndexKit's existing `quickAddOutputRoundTripsThroughIndex` extended).
5. Existing six `QuickAddTests` still pass unchanged (format for due/priority/tags is preserved).
6. In the app, "call Amber @Amber ?waiting" via Quick Add (⇧⌘N), the menu bar, and the Add Task intent all append the identical line to `Inbox.md`.

## Files expected to change

`Packages/TaskEngine/Sources/TaskEngine/{QuickAdd.swift, TaskLineRewriter.swift (extract only), TaskTokenParser.swift (the extension, if placed there)}`, `Packages/TaskEngine/Tests/TaskEngineTests/QuickAddTests.swift`, `Packages/IndexKit/Tests/IndexKitTests/PipelineIntegrationTests.swift` (one case), `App/Services/VaultIndexService.swift` (only `quickAddLine`).
Must NOT touch: `AIKit`, `HeadlessVaultWriter.swift`, `MenuBarQuickAdd.swift`, `NotetakerIntents.swift`, `Recurrence.swift` (spec 02), `settingPriority` (spec 06).

## Test plan (`QuickAddTests`, per-token table; today fixture fixed)

| case | input | expected `markdownLine` |
|---|---|---|
| `assigneeKept` | `call Amber @Amber` | `- [ ] call Amber @Amber` |
| `kindKept` | `budget ?discuss @Amber` | `- [ ] budget @Amber ?discuss` |
| `everyKindInVocabulary` | one input per `discuss waiting next someday followup` | each preserved; `?bogus` stays in text |
| `startDateKept` | `draft ~2026-07-01 >2026-07-10` | `- [ ] draft >2026-07-10 ~2026-07-01` |
| `blockIdKept` | `ship ^ship-v1` | `- [ ] ship ^ship-v1` |
| `dependencyKeptAndNormalised` | `test depends:^ship-v1` | `- [ ] test blockedby:^ship-v1` |
| `multipleDependencies` | `x blockedby:^a,^b` | `- [ ] x blockedby:^a blockedby:^b` |
| `completedDayKept` | `done ✅2026-07-01` | `- [ ] done ✅2026-07-01` |
| `allTokensCanonicalOrder` | tokens in scrambled order | `- [ ] t #tag >D ~S !p2 &every 2 weeks ^id blockedby:^o @p ?waiting` |
| `orderIndependent` | two permutations | equal lines |
| `idempotent` | every row above re-parsed | unchanged |
| `naturalDateDoesNotOverrideToken` | `pay rent tomorrow >2026-07-20` | `>2026-07-20`, "tomorrow" stays in text |
| `barePriorityDoesNotOverrideToken` | `x p1 !p3` | `!p3` |
| `hasExplicitTokensTable` | one input per token + plain text | true…, false |
| `metadataCarriesAllFields` | the all-tokens row | every `ParsedTaskMetadata` field populated |

`TaskLineRewriterTests` (exists? if not, add in `AuditHardeningTests`): `replacingTextOrderUnchangedAfterExtraction` — pin the previous output of `replacingText` on an all-tokens line.
Run: `cd Packages/TaskEngine && DEVELOPER_DIR=/Applications/Xcode.app swift test --scratch-path ~/.cache/notetaker-build/TaskEngine`; Linux is covered by CI.

## Non-goals

Changing the token order of `replacingText`, teaching the AI path new tokens, Quick Add UI, autocomplete, `#tag` placement.

## Risks / invariants

- **ONE parser:** no new regex; `hasExplicitTokens` derives from the parse. Vocabulary (`?kind`) stays untouched.
- **Idempotency** matters because `replacingText` and Quick Add now share the serialiser; a drift there would rewrite lines on every edit in Task Detail.
- Linux CI builds TaskEngine; keep `NSDataDetector` behind the existing `#if os(Linux)` split.

## Builder model

sonnet.
