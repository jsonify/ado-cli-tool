import SwiftUI

struct SprintReportView: View {
    @EnvironmentObject private var settings: SettingsStore
    @State private var iterationPath = ""
    @State private var state = "Closed"

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Summarize the user stories closed in a sprint: counts, points, contributors and tags.")
                    .foregroundStyle(.secondary)
                Form {
                    TextField("Iteration path", text: $iterationPath, prompt: Text(#"Project\Team\Sprint 42"#))
                    TextField("State", text: $state, prompt: Text("Closed"))
                }
                ClosedStoriesPanel(
                    iterationPath: iterationPath.trimmed,
                    state: state.trimmed.isEmpty ? "Closed" : state.trimmed
                )
            }
            .padding(20)
            .frame(maxWidth: 960, alignment: .leading)
        }
        .navigationTitle("Sprint Report")
        .onAppear {
            if iterationPath.isEmpty {
                iterationPath = settings.iterationPath
            }
        }
    }
}

/// Runs `iteration-closed-stories` for a path and shows the summary plus a story table.
struct ClosedStoriesPanel: View {
    let iterationPath: String
    var state: String = "Closed"

    @EnvironmentObject private var cli: CLIRunner
    @StateObject private var task = TaskState()
    @State private var result: ClosedStoriesResult?
    @State private var selection = Set<ClosedStory.ID>()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                RunButton(
                    result == nil ? "Load Closed Stories" : "Reload",
                    systemImage: "tray.and.arrow.down",
                    isRunning: task.isRunning,
                    action: load
                )
                .disabled(iterationPath.isEmpty)
                if let result {
                    Button {
                        Desktop.copy(markdown(for: result))
                    } label: {
                        Label("Copy as Markdown", systemImage: "doc.on.clipboard")
                    }
                }
                Spacer()
            }

            if let message = task.errorMessage {
                ErrorBanner(message: message)
            }

            if let result {
                summary(result.summary)
                storiesTable(result.stories)
            }
        }
    }

    private func summary(_ summary: ClosedStoriesResult.Summary) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                StatTile(title: "Stories", value: "\(summary.storyCount)")
                StatTile(title: "Story points", value: Format.points(summary.totalStoryPoints))
                StatTile(title: "Contributors", value: "\(summary.byAssignee.count)")
            }
            let assignees = sortedAssignees(summary.byAssignee)
            if !assignees.isEmpty {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                    ForEach(assignees, id: \.name) { entry in
                        GridRow {
                            Text(entry.name)
                            Text("\(entry.count)").monospacedDigit().foregroundStyle(.secondary)
                        }
                    }
                }
            }
            if !summary.topTags.isEmpty {
                Text("Top tags: " + summary.topTags.map { "\($0.tag) (\($0.count))" }.joined(separator: " · "))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func storiesTable(_ stories: [ClosedStory]) -> some View {
        Table(stories, selection: $selection) {
            TableColumn("ID") { (story: ClosedStory) in
                Text("#\(story.id)").monospacedDigit()
            }
            .width(70)
            TableColumn("Title") { (story: ClosedStory) in
                Text(story.title ?? "")
            }
            TableColumn("Assignee") { (story: ClosedStory) in
                Text(story.assignedTo ?? "Unassigned")
            }
            .width(min: 100, ideal: 150)
            TableColumn("Points") { (story: ClosedStory) in
                Text(Format.points(story.storyPoints)).monospacedDigit()
            }
            .width(55)
            TableColumn("Closed") { (story: ClosedStory) in
                Text(Format.day(story.closedDate)).monospacedDigit()
            }
            .width(90)
        }
        .contextMenu(forSelectionType: ClosedStory.ID.self) { ids in
            Button("Open in Azure DevOps") { open(ids, in: stories) }
            Button("Copy Links") {
                Desktop.copy(stories.filter { ids.contains($0.id) }.map(\.url).joined(separator: "\n"))
            }
        } primaryAction: { ids in
            open(ids, in: stories)
        }
        .frame(height: 320)
    }

    private func load() {
        let args = ["iteration-closed-stories", "--iteration-path=\(iterationPath)", "--state=\(state)"]
        task.run {
            result = try await cli.run(args, as: ClosedStoriesResult.self)
            selection = []
        }
    }

    private func open(_ ids: Set<ClosedStory.ID>, in stories: [ClosedStory]) {
        for story in stories where ids.contains(story.id) {
            Desktop.open(story.url)
        }
    }

    private func sortedAssignees(_ counts: [String: Int]) -> [(name: String, count: Int)] {
        counts
            .map { (name: $0.key, count: $0.value) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.name < $1.name }
    }

    private func markdown(for result: ClosedStoriesResult) -> String {
        var lines = [
            "## \(iterationPath)",
            "",
            "**\(result.summary.storyCount) stories · \(Format.points(result.summary.totalStoryPoints)) points**",
            "",
        ]
        for story in result.stories {
            let points = Format.points(story.storyPoints)
            let owner = story.assignedTo ?? "Unassigned"
            lines.append("- [#\(story.id)](\(story.url)) \(story.title ?? "") — \(points) pts, \(owner)")
        }
        return lines.joined(separator: "\n")
    }
}
