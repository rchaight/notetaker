import IndexKit
import SwiftUI

/// Lightweight link graph: notes on a ring, wikilink edges between them.
/// Linked notes cluster by degree toward the center; tap opens the note.
struct GraphView: View {
    let notes: [(id: String, title: String)]
    let links: [(from: String, toTitle: String)]
    let onOpen: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    private struct Node: Identifiable {
        let id: String
        let title: String
        let position: CGPoint
        let degree: Int
    }

    private func layout(in size: CGSize) -> [Node] {
        let byTitle = Dictionary(uniqueKeysWithValues: notes.map { ($0.title.lowercased(), $0.id) })
        var degree: [String: Int] = [:]
        for link in links {
            degree[link.from, default: 0] += 1
            if let target = byTitle[link.toTitle.lowercased()] {
                degree[target, default: 0] += 1
            }
        }
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let maxRadius = min(size.width, size.height) / 2 - 50
        let count = max(notes.count, 1)
        return notes.enumerated().map { index, note in
            let angle = (Double(index) / Double(count)) * 2 * .pi
            // Higher degree → closer to center (hub-and-spoke reading).
            let connectivity = min(Double(degree[note.id] ?? 0), 6)
            let radius = maxRadius * (1.0 - connectivity * 0.12)
            return Node(
                id: note.id,
                title: note.title,
                position: CGPoint(
                    x: center.x + radius * cos(angle),
                    y: center.y + radius * sin(angle)
                ),
                degree: degree[note.id] ?? 0
            )
        }
    }

    var body: some View {
        GeometryReader { geo in
            let nodes = layout(in: geo.size)
            let byId = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })
            let byTitle = Dictionary(
                uniqueKeysWithValues: nodes.map { ($0.title.lowercased(), $0) }
            )
            ZStack {
                Canvas { context, _ in
                    for link in links {
                        guard let from = byId[link.from],
                              let to = byTitle[link.toTitle.lowercased()],
                              from.id != to.id else { continue }
                        var path = Path()
                        path.move(to: from.position)
                        path.addLine(to: to.position)
                        context.stroke(path, with: .color(.secondary.opacity(0.35)), lineWidth: 1)
                    }
                }
                ForEach(nodes) { node in
                    VStack(spacing: 2) {
                        Circle()
                            .fill(node.degree > 0 ? Color.accentColor : Color.secondary.opacity(0.5))
                            .frame(
                                width: 8 + CGFloat(min(node.degree, 6)) * 2,
                                height: 8 + CGFloat(min(node.degree, 6)) * 2
                            )
                        Text(node.title)
                            .font(.caption2)
                            .lineLimit(1)
                            .frame(maxWidth: 90)
                    }
                    .position(node.position)
                    .onTapGesture {
                        dismiss()
                        onOpen(node.id)
                    }
                }
            }
        }
        .frame(minWidth: 600, minHeight: 460)
        .overlay(alignment: .topTrailing) {
            Button("Done") { dismiss() }
                .padding(10)
        }
    }
}
