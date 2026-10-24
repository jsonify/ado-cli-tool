import AppKit
import SwiftUI

/// Every engine invocation with its raw JSON output, shown in a drawer below the main content.
struct ActivityDrawer: View {
    @EnvironmentObject private var cli: CLIRunner
    @EnvironmentObject private var model: AppModel
    @State private var selection: LogEntry.ID?

    private var selectedEntry: LogEntry? {
        cli.log.first { $0.id == selection }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Activity", systemImage: "terminal").font(.headline)
                Text("\(cli.log.count) call(s)").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Clear") {
                    selection = nil
                    cli.clearLog()
                }
                .disabled(cli.log.isEmpty)
                Button {
                    model.showActivity = false
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .help("Hide activity (⇧⌘Y)")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            Divider()

            HSplitView {
                List(cli.log, selection: $selection) { entry in
                    HStack {
                        Image(systemName: entry.succeeded ? "checkmark.circle.fill" : "xmark.octagon.fill")
                            .foregroundStyle(entry.succeeded ? Color.green : Color.red)
                        VStack(alignment: .leading) {
                            Text(entry.subcommand).font(.body.monospaced())
                            HStack(spacing: 4) {
                                Text(entry.date, style: .time)
                                Text("·")
                                Text(String(format: "%.2fs", entry.duration))
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(minWidth: 220, idealWidth: 260, maxWidth: 360)

                Group {
                    if let entry = selectedEntry {
                        LogDetailView(entry: entry)
                    } else {
                        Text(cli.log.isEmpty ? "Engine calls will appear here." : "Select a call to see its command and output.")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            if selection == nil { selection = cli.log.first?.id }
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
