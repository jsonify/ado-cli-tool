import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var cli: CLIRunner
    @EnvironmentObject private var model: AppModel

    var body: some View {
        NavigationSplitView {
            List(selection: $model.pane) {
                ForEach(Pane.allCases) { pane in
                    Label(pane.title, systemImage: pane.symbol).tag(pane)
                }
            }
            .safeAreaInset(edge: .bottom) {
                EngineStatusPill()
                    .padding(10)
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 320)
        } detail: {
            VStack(spacing: 0) {
                Group {
                    if model.showSetup {
                        SetupCard()
                    } else {
                        detail(for: model.pane ?? .currentSprint)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

                if model.showActivity {
                    Divider()
                    ActivityDrawer()
                        .frame(height: 280)
                        .transition(.move(edge: .bottom))
                }
            }
            .animation(.easeOut(duration: 0.2), value: model.showActivity)
        }
        .toolbar {
            ToolbarItemGroup {
                if cli.runningCount > 0 {
                    ProgressView().controlSize(.small)
                }
                Button {
                    model.showPalette = true
                } label: {
                    Label("Command Palette", systemImage: "command")
                }
                .help("Command palette (⌘K)")
                Button {
                    model.showNewItem = true
                } label: {
                    Label("New Work Item", systemImage: "plus")
                }
                .help("New work item (⌘N)")
                SettingsButton()
            }
        }
        .sheet(isPresented: $model.showNewItem) {
            NewWorkItemSheet()
                .environmentObject(settings)
                .environmentObject(cli)
                .environmentObject(model)
        }
        .sheet(isPresented: $model.showPalette) {
            CommandPalette()
                .environmentObject(model)
        }
    }

    @ViewBuilder
    private func detail(for pane: Pane) -> some View {
        switch pane {
        case .currentSprint: CurrentSprintView()
        case .workItems: WorkItemsView()
        case .sprints: SprintsView()
        case .reports: ReportsView()
        }
    }
}

/// Ambient engine status at the bottom of the sidebar; click to show the activity drawer.
private struct EngineStatusPill: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var cli: CLIRunner
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Button {
            model.showActivity.toggle()
        } label: {
            HStack(spacing: 6) {
                if cli.runningCount > 0 {
                    ProgressView().controlSize(.mini)
                } else {
                    Circle().fill(status.color).frame(width: 8, height: 8)
                }
                Text(status.text)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                Image(systemName: model.showActivity ? "chevron.down" : "chevron.up")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Capsule().fill(Color.secondary.opacity(0.12)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("Show the engine activity log (⇧⌘Y)")
    }

    private var status: (text: String, color: Color) {
        if cli.runningCount > 0 {
            return ("Running…", .accentColor)
        }
        guard settings.resolvedScriptURL != nil else {
            return ("Engine not found", .red)
        }
        if let last = cli.log.first, !last.succeeded {
            return ("Last command failed", .orange)
        }
        let python = settings.pythonPath.trimmed.isEmpty
            ? "python3"
            : URL(fileURLWithPath: settings.pythonPath.trimmed).lastPathComponent
        return ("Engine ready · \(python)", .green)
    }
}
