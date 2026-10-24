import SwiftUI

enum Pane: String, CaseIterable, Identifiable, Hashable {
    case workItem, create, iterations, sprintReport, pickIteration, exports, activity

    var id: Self { self }

    var title: String {
        switch self {
        case .workItem: return "Work Item"
        case .create: return "Create"
        case .iterations: return "Iterations"
        case .sprintReport: return "Sprint Report"
        case .pickIteration: return "Pick Iteration"
        case .exports: return "Exports"
        case .activity: return "Activity"
        }
    }

    var symbol: String {
        switch self {
        case .workItem: return "doc.text.magnifyingglass"
        case .create: return "plus.square"
        case .iterations: return "calendar"
        case .sprintReport: return "chart.bar.doc.horizontal"
        case .pickIteration: return "scope"
        case .exports: return "square.and.arrow.up"
        case .activity: return "terminal"
        }
    }
}

struct ContentView: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var cli: CLIRunner
    @State private var selection: Pane? = .workItem

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section("Work Items") {
                    row(.workItem)
                    row(.create)
                }
                Section("Sprints") {
                    row(.iterations)
                    row(.sprintReport)
                    row(.pickIteration)
                }
                Section("Reports") {
                    row(.exports)
                }
                Section("Engine") {
                    row(.activity)
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 210)
        } detail: {
            VStack(spacing: 0) {
                if settings.looksUnconfigured {
                    setupBanner
                }
                detail(for: selection ?? .workItem)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .toolbar {
            ToolbarItemGroup {
                if cli.runningCount > 0 {
                    ProgressView().controlSize(.small)
                }
                SettingsButton()
            }
        }
    }

    private func row(_ pane: Pane) -> some View {
        Label(pane.title, systemImage: pane.symbol).tag(pane)
    }

    @ViewBuilder
    private func detail(for pane: Pane) -> some View {
        switch pane {
        case .workItem: WorkItemView()
        case .create: CreateView()
        case .iterations: IterationsView()
        case .sprintReport: SprintReportView()
        case .pickIteration: PickIterationView()
        case .exports: ExportsView()
        case .activity: ActivityView()
        }
    }

    private var setupBanner: some View {
        HStack {
            Image(systemName: "info.circle.fill").foregroundStyle(Color.accentColor)
            Text("Add your organization, project and personal access token in Settings, or point the engine at an existing .env file.")
                .font(.callout)
            Spacer()
            SettingsButton()
        }
        .padding(10)
        .background(Color.accentColor.opacity(0.1))
    }
}
