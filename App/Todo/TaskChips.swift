import IndexKit
import SwiftUI

/// ONE chip vocabulary for every to-do surface (List/Board/Agenda/Matrix):
/// Todoist-style priority colors and per-label color chips. Label colors
/// are deterministic from a fixed palette, overridable per label (stored
/// in AppStorage as JSON {label: paletteIndex}).
enum TaskChipStyle {
    static let palette: [Color] = [.blue, .green, .orange, .purple, .pink, .teal, .indigo, .brown]

    /// Todoist convention: P1 red, P2 orange, P3 blue, P4/none muted.
    static func priorityColor(_ priority: Int?) -> Color {
        switch priority {
        case 1: .red
        case 2: .orange
        case 3: .blue
        default: .secondary
        }
    }

    static func labelColor(_ label: String) -> Color {
        if let index = overrides()[label], palette.indices.contains(index) {
            return palette[index]
        }
        // Deterministic hash → palette (stable across launches; hashValue
        // is seeded per-process, so fold unicode scalars instead).
        let folded = label.unicodeScalars.reduce(5381) { ($0 << 5) &+ $0 &+ Int($1.value) }
        return palette[abs(folded) % palette.count]
    }

    static func setLabelColor(_ label: String, paletteIndex: Int?) {
        var current = overrides()
        current[label] = paletteIndex
        if let data = try? JSONEncoder().encode(current) {
            UserDefaults.standard.set(String(data: data, encoding: .utf8), forKey: "labelColors")
        }
    }

    private static func overrides() -> [String: Int] {
        guard let raw = UserDefaults.standard.string(forKey: "labelColors"),
              let decoded = try? JSONDecoder().decode([String: Int].self, from: Data(raw.utf8))
        else { return [:] }
        return decoded
    }
}

struct PriorityChip: View {
    let priority: Int?

    var body: some View {
        if let priority {
            Text("P\(priority)")
                .font(.caption2.weight(.bold))
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(TaskChipStyle.priorityColor(priority).opacity(0.16), in: Capsule())
                .foregroundStyle(TaskChipStyle.priorityColor(priority))
        }
    }
}

struct LabelChips: View {
    let labels: [String]

    var body: some View {
        ForEach(labels, id: \.self) { label in
            Text("#" + label)
                .font(.caption2.weight(.medium))
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(TaskChipStyle.labelColor(label).opacity(0.16), in: Capsule())
                .foregroundStyle(TaskChipStyle.labelColor(label))
                .contextMenu {
                    Picker("Color", selection: Binding(
                        get: { -1 },
                        set: { TaskChipStyle.setLabelColor(label, paletteIndex: $0 >= 0 ? $0 : nil) }
                    )) {
                        Text("Auto").tag(-1)
                        ForEach(0 ..< TaskChipStyle.palette.count, id: \.self) { index in
                            Label("Color \(index + 1)", systemImage: "circle.fill").tag(index)
                        }
                    }
                }
        }
    }
}
