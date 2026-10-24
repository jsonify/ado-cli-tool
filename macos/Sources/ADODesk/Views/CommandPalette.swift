import SwiftUI

/// ⌘K: type to jump anywhere. Return runs the first match.
struct CommandPalette: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private struct Action: Identifiable {
        let id: String
        let title: String
        let detail: String?
        let symbol: String
        let perform: @MainActor (AppModel) -> Void
    }

    private var actions: [Action] {
        let text = query.trimmed
        var results: [Action] = []
        if let id = Int(text.trimmingCharacters(in: CharacterSet(charactersIn: "#"))) {
            results.append(Action(id: "open-\(id)", title: "Open work item #\(id)", detail: nil, symbol: "arrow.right.circle") {
                $0.openWorkItem(id)
            })
        }

        var commands = [
            Action(id: "new", title: "New work item", detail: "⌘N", symbol: "plus.square") { $0.showNewItem = true },
        ]
        for (index, pane) in Pane.allCases.enumerated() {
            commands.append(Action(id: "pane-\(pane.rawValue)", title: "Go to \(pane.title)", detail: "⌘\(index + 1)", symbol: pane.symbol) {
                $0.pane = pane
            })
        }
        commands.append(Action(id: "export", title: "Export closed stories or modifications", detail: nil, symbol: "square.and.arrow.up") {
            $0.pane = .reports
        })
        commands.append(Action(
            id: "activity",
            title: model.showActivity ? "Hide activity" : "Show activity",
            detail: "⇧⌘Y",
            symbol: "terminal"
        ) {
            $0.showActivity.toggle()
        })
        results += commands.filter { text.isEmpty || $0.title.localizedCaseInsensitiveContains(text) }

        let items = model.recents.filter {
            text.isEmpty || $0.title.localizedCaseInsensitiveContains(text) || String($0.id).hasPrefix(text)
        }
        results += items.prefix(8).map { item in
            Action(id: "recent-\(item.id)", title: item.title.isEmpty ? "Untitled" : item.title, detail: "#\(item.id)", symbol: "clock") {
                $0.openWorkItem(item.id)
            }
        }
        return results
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Type a command, a work item ID, or a title", text: $query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .onSubmit {
                        if let first = actions.first { run(first) }
                    }
            }
            .padding(14)
            Divider()
            List {
                ForEach(Array(actions.enumerated()), id: \.element.id) { index, action in
                    Button {
                        run(action)
                    } label: {
                        HStack {
                            Image(systemName: action.symbol).frame(width: 20).foregroundStyle(.secondary)
                            Text(action.title).lineLimit(1)
                            Spacer()
                            if let detail = action.detail {
                                Text(detail).font(.caption).foregroundStyle(.secondary)
                            }
                            if index == 0 {
                                Image(systemName: "return").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .listStyle(.plain)
        }
        .frame(width: 560, height: 380)
        .background {
            Button("Close") { dismiss() }
                .keyboardShortcut(.cancelAction)
                .hidden()
        }
    }

    private func run(_ action: Action) {
        dismiss()
        // Let this sheet finish closing first: an action may present the New Work Item sheet.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 200_000_000)
            action.perform(model)
        }
    }
}
