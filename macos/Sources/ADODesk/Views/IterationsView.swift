import SwiftUI

struct IterationsView: View {
    enum Timeframe: String, CaseIterable, Identifiable {
        case all, current, past, future
        var id: Self { self }
        var label: String { rawValue.capitalized }
    }

    @EnvironmentObject private var cli: CLIRunner
    @EnvironmentObject private var settings: SettingsStore
    @StateObject private var task = TaskState()

    @State private var team = ""
    @State private var timeframe: Timeframe = .all
    @State private var iterations: [Iteration] = []
    @State private var selection: Iteration.ID?
    @State private var loaded = false

    private var selectedIteration: Iteration? {
        iterations.first { $0.id == selection }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                TextField("Team", text: $team, prompt: Text(settings.team.isEmpty ? "Team name" : settings.team))
                    .frame(maxWidth: 260)
                    .onSubmit(load)
                Picker("Timeframe", selection: $timeframe) {
                    ForEach(Timeframe.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 320)
                RunButton("Load", systemImage: "arrow.clockwise", isRunning: task.isRunning, action: load)
                Spacer()
            }
            .padding(12)

            if let message = task.errorMessage {
                ErrorBanner(message: message)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
            }

            VSplitView {
                Table(iterations, selection: $selection) {
                    TableColumn("Name") { (iteration: Iteration) in
                        Text(iteration.name ?? "—")
                    }
                    TableColumn("Start") { (iteration: Iteration) in
                        Text(Format.day(iteration.startDate)).monospacedDigit()
                    }
                    .width(90)
                    TableColumn("Finish") { (iteration: Iteration) in
                        Text(Format.day(iteration.finishDate)).monospacedDigit()
                    }
                    .width(90)
                    TableColumn("Timeframe") { (iteration: Iteration) in
                        Text(iteration.timeFrame ?? "")
                    }
                    .width(80)
                    TableColumn("Path") { (iteration: Iteration) in
                        Text(iteration.path ?? "").foregroundStyle(.secondary)
                    }
                }
                .frame(minHeight: 160)

                Group {
                    if let iteration = selectedIteration {
                        IterationDetailView(iteration: iteration, team: team.trimmed)
                            .id(iteration.id)
                    } else {
                        Text(loaded ? "Select an iteration to see its goal and closed stories." : "Load your team's iterations to get started.")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .frame(minHeight: 260)
            }
        }
        .navigationTitle("Iterations")
    }

    private func load() {
        var args = ["iteration-list"]
        if !team.trimmed.isEmpty {
            args.append("--team=\(team.trimmed)")
        }
        if timeframe != .all {
            args.append("--timeframe=\(timeframe.rawValue)")
        }
        let finalArgs = args
        task.run {
            let list = try await cli.run(finalArgs, as: IterationList.self)
            iterations = list.iterations
            loaded = true
            if selectedIteration == nil {
                selection = list.iterations.first { $0.timeFrame == "current" }?.id
            }
        }
    }
}

struct IterationDetailView: View {
    let iteration: Iteration
    let team: String

    @EnvironmentObject private var cli: CLIRunner
    @StateObject private var goalTask = TaskState()
    @State private var goal = ""
    @State private var savedGoal = ""
    @State private var savedMessage: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    Text(iteration.name ?? "Iteration").font(.title2.bold())
                    Text("\(Format.day(iteration.startDate)) → \(Format.day(iteration.finishDate))")
                        .foregroundStyle(.secondary)
                    Spacer()
                    if let path = iteration.path {
                        Button {
                            Desktop.copy(path)
                        } label: {
                            Label("Copy Path", systemImage: "doc.on.doc")
                        }
                    }
                }

                GroupBox("Sprint Goal") {
                    VStack(alignment: .leading, spacing: 8) {
                        TextEditor(text: $goal)
                            .font(.body)
                            .frame(minHeight: 70)
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
                        HStack {
                            if let savedMessage {
                                SuccessLabel(message: savedMessage)
                            }
                            Spacer()
                            Button("Revert") { goal = savedGoal }
                                .disabled(goal == savedGoal)
                            RunButton("Save Goal", systemImage: "flag", isRunning: goalTask.isRunning, action: saveGoal)
                                .disabled(goal == savedGoal || iteration.iterationID == nil)
                        }
                        if let message = goalTask.errorMessage {
                            ErrorBanner(message: message)
                        }
                    }
                    .padding(6)
                }

                GroupBox("Closed Stories") {
                    ClosedStoriesPanel(iterationPath: iteration.path ?? "")
                        .padding(6)
                }
            }
            .padding(16)
        }
        .onAppear(perform: loadGoal)
    }

    private var teamArgs: [String] {
        team.isEmpty ? [] : ["--team=\(team)"]
    }

    private func loadGoal() {
        guard let id = iteration.iterationID else { return }
        let args = ["iteration-get", "--id=\(id)"] + teamArgs
        goalTask.run {
            let detail = try await cli.run(args, as: IterationDetail.self)
            goal = detail.goalText ?? ""
            savedGoal = goal
        }
    }

    private func saveGoal() {
        guard let id = iteration.iterationID else { return }
        let args = ["iteration-update-goal", "--id=\(id)", "--goal=\(goal)"] + teamArgs
        savedMessage = nil
        goalTask.run {
            let result = try await cli.run(args, as: GoalResult.self)
            goal = result.goalText ?? goal
            savedGoal = goal
            savedMessage = "Goal saved."
        }
    }
}
