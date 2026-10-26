import SwiftUI

/// Home: the team's current iteration, loaded on open.
struct CurrentSprintView: View {
    @EnvironmentObject private var cli: CLIRunner
    @EnvironmentObject private var model: AppModel
    @StateObject private var task = TaskState()
    @State private var loaded = false

    var body: some View {
        Group {
            if let iteration = model.currentIteration {
                SprintDetailView(iteration: iteration, onReload: reload)
                    .id(iteration.id)
            } else if task.isRunning {
                ProgressView("Loading the current sprint…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 12) {
                    if let message = task.errorMessage {
                        ErrorBanner(message: message).frame(maxWidth: 560)
                    } else if loaded {
                        Text("Your team has no current iteration.").foregroundStyle(.secondary)
                    }
                    HStack {
                        Button("Try Again", action: load)
                        Button("Browse Sprints") { model.pane = .sprints }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle("Current Sprint")
        .onAppear {
            if model.currentIteration == nil && !loaded { load() }
        }
    }

    /// Drops the loaded sprint so its goal and stories are fetched again too.
    private func reload() {
        model.currentIteration = nil
        load()
    }

    private func load() {
        task.run {
            let list = try await cli.run(["iteration-list", "--timeframe=current"], as: IterationList.self)
            model.currentIteration = list.iterations.first
            loaded = true
        }
    }
}

/// All iterations grouped by timeframe, with the selected one's detail beside the list.
struct SprintsView: View {
    @EnvironmentObject private var cli: CLIRunner
    @StateObject private var task = TaskState()
    @State private var iterations: [Iteration] = []
    @State private var selection: Iteration.ID?
    @State private var loaded = false

    private var selectedIteration: Iteration? {
        iterations.first { $0.id == selection }
    }

    private var groups: [(title: String, items: [Iteration])] {
        let current = iterations.filter { $0.timeFrame == "current" }
        let upcoming = iterations.filter { $0.timeFrame == "future" }
        // Most recent first: that's the one people look back at.
        let past = iterations.filter { $0.timeFrame == "past" }.reversed()
        let other = iterations.filter { !["current", "future", "past"].contains($0.timeFrame ?? "") }
        return [("Current", current), ("Upcoming", upcoming), ("Past", Array(past)), ("Other", other)]
            .filter { !$0.items.isEmpty }
    }

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                List(selection: $selection) {
                    ForEach(groups, id: \.title) { group in
                        Section(group.title) {
                            ForEach(group.items) { iteration in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(iteration.name ?? "—")
                                    Text("\(Format.shortDay(iteration.startDate)) – \(Format.shortDay(iteration.finishDate))")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                .tag(iteration.id)
                            }
                        }
                    }
                }
                if let message = task.errorMessage {
                    ErrorBanner(message: message).padding(8)
                }
                Divider()
                HStack {
                    Text(loaded ? "\(iterations.count) iteration(s)" : " ")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    RunButton("Reload", systemImage: "arrow.clockwise", isRunning: task.isRunning, action: load)
                        .buttonStyle(.borderless)
                }
                .padding(8)
            }
            .frame(minWidth: 220, idealWidth: 250, maxWidth: 340)

            Group {
                if let iteration = selectedIteration {
                    SprintDetailView(iteration: iteration)
                        .id(iteration.id)
                } else {
                    Text(loaded ? "Select a sprint." : "Loading iterations…")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(minWidth: 520, maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle("Sprints")
        .onAppear {
            if !loaded { load() }
        }
    }

    private func load() {
        task.run {
            let list = try await cli.run(["iteration-list"], as: IterationList.self)
            iterations = list.iterations
            loaded = true
            if selectedIteration == nil {
                selection = (list.iterations.first { $0.timeFrame == "current" } ?? list.iterations.last)?.id
            }
        }
    }
}

/// One sprint: dates and progress, an editable goal, and its closed stories.
struct SprintDetailView: View {
    let iteration: Iteration
    var onReload: (() -> Void)?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                SprintGoalEditor(iteration: iteration)
                ClosedStoriesPanel(iterationName: iteration.name ?? "Sprint", iterationPath: iteration.path ?? "")
            }
            .padding(20)
            .frame(maxWidth: 1000, alignment: .leading)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(iteration.name ?? "Iteration").font(.largeTitle.bold())
                if let timeFrame = iteration.timeFrame {
                    Text(timeFrame.capitalized)
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                }
                Spacer()
                if let path = iteration.path {
                    Button {
                        Desktop.copy(path)
                    } label: {
                        Label("Copy Path", systemImage: "doc.on.doc")
                    }
                }
                if let onReload {
                    Button(action: onReload) {
                        Label("Reload", systemImage: "arrow.clockwise")
                    }
                }
            }
            if let progress = SprintProgress(start: iteration.startDate, finish: iteration.finishDate) {
                HStack(spacing: 12) {
                    Text("\(Format.shortDay(iteration.startDate)) – \(Format.shortDay(iteration.finishDate))")
                        .foregroundStyle(.secondary)
                    ProgressView(value: progress.fraction)
                        .frame(maxWidth: 260)
                    Text(progress.label)
                        .font(.callout.weight(.medium))
                        .monospacedDigit()
                }
            }
        }
    }
}

/// Days elapsed and left in a sprint, from its ISO start and finish dates.
struct SprintProgress {
    let fraction: Double
    let label: String

    init?(start: String?, finish: String?, now: Date = Date()) {
        guard let start = Format.date(start), let finish = Format.date(finish), finish > start else { return nil }
        let calendar = Calendar.current
        let total = max(1, (calendar.dateComponents([.day], from: start, to: finish).day ?? 0) + 1)
        let elapsed = (calendar.dateComponents([.day], from: calendar.startOfDay(for: start), to: now).day ?? 0)
        fraction = min(1, max(0, Double(elapsed) / Double(total)))
        let left = total - elapsed
        if elapsed < 0 {
            label = "Starts in \(-elapsed) day\(-elapsed == 1 ? "" : "s")"
        } else if left <= 0 {
            label = "Finished"
        } else {
            label = "\(left) day\(left == 1 ? "" : "s") left"
        }
    }
}

/// The sprint goal, shown as text with a pencil button that switches to an editor.
struct SprintGoalEditor: View {
    let iteration: Iteration

    @EnvironmentObject private var cli: CLIRunner
    @StateObject private var task = TaskState()
    @State private var goal = ""
    @State private var draft = ""
    @State private var editing = false
    @State private var loaded = false

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("Sprint Goal", systemImage: "target").font(.headline)
                    Spacer()
                    if task.isRunning {
                        ProgressView().controlSize(.small)
                    } else if !editing && iteration.iterationID != nil {
                        Button {
                            draft = goal
                            editing = true
                        } label: {
                            Image(systemName: "pencil")
                        }
                        .buttonStyle(.borderless)
                        .help("Edit the sprint goal")
                    }
                }
                if editing {
                    TextEditor(text: $draft)
                        .font(.body)
                        .frame(minHeight: 80)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
                    HStack {
                        Spacer()
                        Button("Cancel") { editing = false }
                            .keyboardShortcut(.cancelAction)
                        Button("Save Goal", action: save)
                            .keyboardShortcut("s")
                            .buttonStyle(.borderedProminent)
                            .disabled(draft == goal || task.isRunning)
                    }
                } else if goal.trimmed.isEmpty {
                    Text(loaded ? "No goal set for this sprint." : " ")
                        .foregroundStyle(.secondary)
                } else {
                    Text(goal).textSelection(.enabled)
                }
                if let message = task.errorMessage {
                    ErrorBanner(message: message)
                }
            }
            .padding(6)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear(perform: load)
    }

    private func load() {
        guard let id = iteration.iterationID, !loaded else { return }
        task.run {
            let detail = try await cli.run(["iteration-get", "--id=\(id)"], as: IterationDetail.self)
            goal = detail.goalText ?? ""
            loaded = true
        }
    }

    private func save() {
        guard let id = iteration.iterationID else { return }
        let text = draft
        task.run {
            let result = try await cli.run(["iteration-update-goal", "--id=\(id)", "--goal=\(text)"], as: GoalResult.self)
            goal = result.goalText ?? text
            editing = false
        }
    }
}

/// Stat tiles plus a table of the stories closed in an iteration, loaded automatically.
struct ClosedStoriesPanel: View {
    let iterationName: String
    let iterationPath: String

    @EnvironmentObject private var cli: CLIRunner
    @EnvironmentObject private var model: AppModel
    @StateObject private var task = TaskState()
    @State private var result: ClosedStoriesResult?
    @State private var activeCount: Int?
    @State private var selection = Set<ClosedStory.ID>()
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                StatTile(title: "Stories closed", value: result.map { "\($0.summary.storyCount)" } ?? "–")
                StatTile(title: "Points closed", value: result.map { Format.points($0.summary.totalStoryPoints) } ?? "–")
                StatTile(title: "Stories active", value: activeCount.map { "\($0)" } ?? "–")
                StatTile(title: "Contributors", value: result.map { "\($0.summary.byAssignee.count)" } ?? "–")
                Spacer()
            }

            HStack {
                Text("Closed Stories").font(.headline)
                if task.isRunning {
                    ProgressView().controlSize(.small)
                }
                Spacer()
                Button {
                    load()
                } label: {
                    Label("Reload", systemImage: "arrow.clockwise")
                }
                .disabled(task.isRunning || iterationPath.isEmpty)
                Button {
                    if let result {
                        Desktop.copy(markdown(for: result))
                        copied = true
                    }
                } label: {
                    Label(copied ? "Copied" : "Copy as Markdown", systemImage: copied ? "checkmark" : "doc.on.clipboard")
                }
                .disabled(result == nil)
            }

            if let message = task.errorMessage {
                ErrorBanner(message: message)
            }

            if let result {
                if result.stories.isEmpty {
                    Text("No stories closed yet.")
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 20)
                        .frame(maxWidth: .infinity)
                } else {
                    storiesTable(result.stories)
                }
                if !result.summary.topTags.isEmpty {
                    Text("Top tags: " + result.summary.topTags.map { "\($0.tag) (\($0.count))" }.joined(separator: " · "))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .onAppear {
            if result == nil && !iterationPath.isEmpty { load() }
        }
    }

    private func storiesTable(_ stories: [ClosedStory]) -> some View {
        Table(stories, selection: $selection) {
            TableColumn("ID") { (story: ClosedStory) in
                Button(Format.id(story.id)) { Desktop.open(story.url) }
                    .buttonStyle(.link)
                    .monospacedDigit()
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
            if ids.count == 1, let id = ids.first {
                Button("Open in ADO Desk") { model.openWorkItem(id) }
            }
            Button("Open in Azure DevOps") { open(ids, in: stories) }
            Button("Copy Links") {
                Desktop.copy(stories.filter { ids.contains($0.id) }.map(\.url).joined(separator: "\n"))
            }
        } primaryAction: { ids in
            if let id = ids.first { model.openWorkItem(id) }
        }
        .frame(height: min(420, CGFloat(stories.count) * 26 + 34))
    }

    private func load() {
        let path = iterationPath
        copied = false
        task.run {
            result = try await cli.run(
                ["iteration-closed-stories", "--iteration-path=\(path)", "--state=Closed"],
                as: ClosedStoriesResult.self
            )
            selection = []
            // The active count is extra context; a failure there shouldn't hide the closed stories.
            let active = try? await cli.run(
                ["iteration-closed-stories", "--iteration-path=\(path)", "--state=Active"],
                as: ClosedStoriesResult.self
            )
            activeCount = active?.summary.storyCount
        }
    }

    private func open(_ ids: Set<ClosedStory.ID>, in stories: [ClosedStory]) {
        for story in stories where ids.contains(story.id) {
            Desktop.open(story.url)
        }
    }

    private func markdown(for result: ClosedStoriesResult) -> String {
        var lines = [
            "## \(iterationName)",
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
