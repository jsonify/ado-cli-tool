import SwiftUI

/// Every engine invocation with its raw JSON output, for debugging and copying results.
struct ActivityView: View {
    @EnvironmentObject private var cli: CLIRunner
    @State private var selection: LogEntry.ID?

    private var selectedEntry: LogEntry? {
        cli.log.first { $0.id == selection }
    }

    var body: some View {
        HSplitView {
            List(cli.log, selection: $selection) { entry in
                HStack {
                    Image(systemName: entry.succeeded ? "checkmark.circle.fill" : "xmark.octagon.fill")
                        .foregroundStyle(entry.succeeded ? Color.green : Color.red)
                    VStack(alignment: .leading) {
                        Text(entry.subcommand).font(.body.monospaced())
                        Text(entry.date, style: .time).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .frame(minWidth: 220, idealWidth: 260, maxWidth: 360)

            Group {
                if let entry = selectedEntry {
                    LogDetailView(entry: entry)
                } else {
                    Text(cli.log.isEmpty ? "Engine calls will appear here." : "Select a call to see its output.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle("Activity")
        .toolbar {
            ToolbarItem {
                Button {
                    selection = nil
                    cli.clearLog()
                } label: {
                    Label("Clear", systemImage: "trash")
                }
                .disabled(cli.log.isEmpty)
            }
        }
    }
}

private struct LogDetailView: View {
    let entry: LogEntry

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(entry.exitCode.map { "Exit code \($0)" } ?? "Failed to launch")
                    Text("·")
                    Text(String(format: "%.2fs", entry.duration))
                    Text("·")
                    Text(entry.date, style: .date)
                    Text(entry.date, style: .time)
                    Spacer()
                    Button("Copy Output") { Desktop.copy(entry.stdout) }
                        .disabled(entry.stdout.isEmpty)
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                section("Command", entry.commandLine)
                if !entry.stdout.isEmpty {
                    section("Output", entry.stdout)
                }
                if !entry.stderr.isEmpty {
                    section("Errors", entry.stderr)
                }
            }
            .padding(16)
        }
    }

    private func section(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.headline)
            Text(text)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.08)))
        }
    }
}
