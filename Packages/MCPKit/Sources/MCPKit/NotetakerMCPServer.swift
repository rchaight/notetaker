import Foundation
import MCP

/// The MCP surface: seven read-only tools over the Notetaker vault.
/// Descriptions are written for the model that will read them — what the
/// tool is for and when to reach for it, not just what it returns.
public enum NotetakerMCPServer {
    public static let serverName = "notetaker"

    static let fallbackVersion = "0.1.0"

    /// Marketing version of the enclosing app. A bare tool has no Info.plist
    /// of its own — `Bundle.main` synthesises a useless "1.0" — so read the
    /// app's plist by walking up from `Contents/MacOS/notetaker-mcp`.
    public static var version: String {
        let container = Bundle.main.bundleURL // .../Notetaker.app/Contents/MacOS
            .deletingLastPathComponent() // .../Notetaker.app/Contents
            .deletingLastPathComponent() // .../Notetaker.app
        guard container.pathExtension == "app",
              let info = NSDictionary(
                  contentsOf: container.appendingPathComponent("Contents/Info.plist")
              ),
              let marketing = info["CFBundleShortVersionString"] as? String
        else { return fallbackVersion }
        return marketing
    }

    public static let instructions = """
    Notetaker is the user's personal markdown vault: notes, inline todos, \
    meetings and projects, all plain .md files in iCloud Drive.

    Start with vault_overview to learn the vault's shape and read its \
    CLAUDE.md instructions. Then narrow with search (best for "what do I \
    know about X"), list_folder (browsing a known area), and read_note \
    (the full text of one note). Use tasks for anything about todos, \
    deadlines, or what someone owes whom.

    calendar_agenda shows the user's day or week when they have enabled \
    calendar sharing; it is a snapshot, so check `stale`.

    This server is read-only: it never edits the vault.
    """

    public static func tools() -> [Tool] {
        let readOnly = Tool.Annotations(readOnlyHint: true, destructiveHint: false, openWorldHint: false)
        return [
            Tool(
                name: "vault_overview",
                description: """
                Start here. Returns the vault's own CLAUDE.md instructions (if the user wrote \
                any), its root table of contents, the folder tree with note counts, and the \
                most recently edited notes. Call this first in a session before guessing at \
                paths or folder names.
                """,
                inputSchema: .object(["type": .string("object"), "properties": .object([:])]),
                annotations: readOnly
            ),
            Tool(
                name: "list_folder",
                description: """
                List one folder of the vault: its subfolders and its notes, plus the folder's \
                _index.md table of contents when the app has written one. Use it to browse a \
                known area (e.g. "Meetings", "Work Notes/Curriculum") when search is too blunt. \
                Locked notes appear by title only.
                """,
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "path": .object([
                            "type": .string("string"),
                            "description": .string(
                                "Vault-relative folder path, e.g. \"Meetings\". Empty string or \"/\" for the vault root."
                            ),
                        ]),
                    ]),
                    "required": .array([.string("path")]),
                ]),
                annotations: readOnly
            ),
            Tool(
                name: "read_note",
                description: """
                Read the full markdown of one note, including its YAML frontmatter. Paths come \
                from search, list_folder, or vault_overview — the .md extension is optional. \
                Notes the user has locked return their title and nothing else; their contents \
                are encrypted and are never served.
                """,
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "path": .object([
                            "type": .string("string"),
                            "description": .string("Vault-relative note path, e.g. \"Daily/2026-08-20.md\"."),
                        ]),
                    ]),
                    "required": .array([.string("path")]),
                ]),
                annotations: readOnly
            ),
            Tool(
                name: "search",
                description: """
                Find notes by meaning and by keyword. The default hybrid mode fuses full-text \
                BM25 ranking with semantic similarity over the app's on-device embeddings, so \
                it finds notes that discuss a topic without using your exact words. Returns \
                ranked paths with a matching snippet; follow up with read_note for the full \
                text. This is the right first move for any "what do I know / what did I say \
                about X" question.
                """,
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "query": .object([
                            "type": .string("string"),
                            "description": .string("What to look for — words or a short phrase."),
                        ]),
                        "mode": .object([
                            "type": .string("string"),
                            "enum": .array([.string("keyword"), .string("semantic"), .string("hybrid")]),
                            "description": .string(
                                "hybrid (default) fuses both; keyword for exact terms; semantic for concepts."
                            ),
                        ]),
                        "limit": .object([
                            "type": .string("integer"),
                            "description": .string("Maximum results, default 10."),
                        ]),
                    ]),
                    "required": .array([.string("query")]),
                ]),
                annotations: readOnly
            ),
            Tool(
                name: "tasks",
                description: """
                The user's inline todos across the whole vault, with their due dates, \
                priorities, tags, assignees and source note + line. Filter it to answer \
                questions like "what's due this week", "what am I waiting on from Dana", or \
                "what's tagged #curriculum". Open tasks only unless include_completed is set.
                """,
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "due_within_days": .object([
                            "type": .string("integer"),
                            "description": .string(
                                "Only tasks due within this many days; overdue tasks always count as due."
                            ),
                        ]),
                        "assignee": .object([
                            "type": .string("string"),
                            "description": .string("@person the task is assigned to or about."),
                        ]),
                        "kind": .object([
                            "type": .string("string"),
                            "enum": .array([
                                .string("discuss"), .string("waiting"), .string("next"),
                                .string("someday"), .string("followup"),
                            ]),
                            "description": .string("The ?kind token: discuss, waiting, next, someday, followup."),
                        ]),
                        "label": .object([
                            "type": .string("string"),
                            "description": .string("A #tag on the task, without the #."),
                        ]),
                        "include_completed": .object([
                            "type": .string("boolean"),
                            "description": .string("Include finished tasks. Default false."),
                        ]),
                        "limit": .object([
                            "type": .string("integer"),
                            "description": .string("Maximum tasks, default 100."),
                        ]),
                    ]),
                ]),
                annotations: readOnly
            ),
            Tool(
                name: "calendar_agenda",
                description: """
                The user's upcoming calendar events from the calendars they chose to share \
                with you, grouped by day. Use it for "what's on today / this week / on \
                Friday", meeting prep, and finding free time. Default range is today; "week" \
                is today plus the next six days; "custom" takes from/to dates. Events come \
                from a snapshot Notetaker refreshes while it runs — check `stale` and \
                `generated_at`. Returns `available: false` with instructions when the user \
                has not turned sharing on.
                """,
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "range": .object([
                            "type": .string("string"),
                            "enum": .array([
                                .string("today"), .string("tomorrow"), .string("week"), .string("custom"),
                            ]),
                            "description": .string("Default today. custom requires from and to."),
                        ]),
                        "from": .object([
                            "type": .string("string"),
                            "description": .string("yyyy-mm-dd, first day (range custom only)."),
                        ]),
                        "to": .object([
                            "type": .string("string"),
                            "description": .string("yyyy-mm-dd, last day inclusive (range custom only)."),
                        ]),
                        "calendar": .object([
                            "type": .string("string"),
                            "description": .string(
                                "Only events from the calendar with this title (case-insensitive); see calendar_list."
                            ),
                        ]),
                    ]),
                ]),
                annotations: readOnly
            ),
            Tool(
                name: "calendar_list",
                description: """
                The calendars included in the shared snapshot, with account and colour. Use \
                the titles as the `calendar` filter for calendar_agenda.
                """,
                inputSchema: .object(["type": .string("object"), "properties": .object([:])]),
                annotations: readOnly
            ),
        ]
    }

    /// Builds a server with the tool handlers wired to `service`. Callers
    /// supply the transport, so tests can drive it in-process.
    public static func make(service: VaultService) async -> Server {
        let server = Server(
            name: serverName,
            version: version,
            instructions: instructions,
            capabilities: .init(tools: .init(listChanged: false))
        )
        await server.withMethodHandler(ListTools.self) { _ in .init(tools: tools()) }
        await server.withMethodHandler(CallTool.self) { parameters in
            await call(name: parameters.name, arguments: parameters.arguments ?? [:], service: service)
        }
        return server
    }

    /// Tool dispatch, split out so tests can exercise it without a transport.
    public static func call(
        name: String, arguments: [String: Value], service: VaultService
    ) async -> CallTool.Result {
        do {
            let payload: Value = switch name {
            case "vault_overview":
                service.vaultOverview()
            case "list_folder":
                try service.listFolder(path: arguments["path"]?.stringValue ?? "")
            case "read_note":
                try await service.readNote(path: required("path", in: arguments))
            case "search":
                try await service.search(
                    query: required("query", in: arguments),
                    mode: arguments["mode"]?.stringValue
                        .flatMap(VaultService.SearchMode.init(rawValue:)) ?? .hybrid,
                    limit: arguments["limit"]?.intValue ?? 10
                )
            case "tasks":
                service.tasks(VaultService.TaskQuery(
                    dueWithinDays: arguments["due_within_days"]?.intValue,
                    assignee: arguments["assignee"]?.stringValue,
                    kind: arguments["kind"]?.stringValue,
                    label: arguments["label"]?.stringValue,
                    includeCompleted: arguments["include_completed"]?.boolValue ?? false,
                    limit: arguments["limit"]?.intValue ?? 100
                ))
            case "calendar_agenda":
                try service.calendarAgenda(VaultService.CalendarAgendaQuery(
                    range: arguments["range"]?.stringValue,
                    from: arguments["from"]?.stringValue,
                    to: arguments["to"]?.stringValue,
                    calendar: arguments["calendar"]?.stringValue
                ))
            case "calendar_list":
                service.calendarList()
            default:
                throw MCPError.methodNotFound("unknown tool \(name)")
            }
            // Optional-typed so the non-throwing `Value?` overload is chosen
            // over the generic Codable one.
            let structured: Value? = payload
            return .init(
                content: [.text(text: json(payload), annotations: nil, _meta: nil)],
                structuredContent: structured,
                isError: false
            )
        } catch {
            return .init(
                content: [.text(text: "\(error)", annotations: nil, _meta: nil)],
                isError: true
            )
        }
    }

    private static func required(_ key: String, in arguments: [String: Value]) throws -> String {
        guard let value = arguments[key]?.stringValue, !value.isEmpty else {
            throw MCPError.invalidParams("\(key) is required")
        }
        return value
    }

    static func json(_ value: Value) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value), let text = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return text
    }
}
