import SwiftUI

struct CreateView: View {
    @EnvironmentObject private var cli: CLIRunner
    @EnvironmentObject private var settings: SettingsStore
    @StateObject private var createTask = TaskState()
    @StateObject private var pickTask = TaskState()

    @State private var type = "User Story"
    @State private var title = ""
    @State private var description = ""
    @State private var criteria = ""
    @State private var areaPath = ""
    @State private var iterationPath = ""
    @State private var parentID = ""
    @State private var assignedTo = ""
    @State private var secondaryAssignee = ""
    @State private var created: WorkItemSummary?

    private static let types = ["User Story", "Task", "Bug", "Feature", "Epic"]

    var body: some View {
        Form {
            Section("Work Item") {
                Picker("Type", selection: $type) {
                    ForEach(Self.types, id: \.self) { Text($0).tag($0) }
                }
                TextField("Title", text: $title)
                TextField(
                    "Description",
                    text: $description,
                    prompt: Text("Markdown: # headings, - bullets, `code`, ``` blocks"),
                    axis: .vertical
                )
                .lineLimit(4...12)
                TextField(
                    "Acceptance criteria",
                    text: $criteria,
                    prompt: Text("One criterion per line"),
                    axis: .vertical
                )
                .lineLimit(3...10)
            }

            Section("Placement") {
                TextField(
                    "Area path",
                    text: $areaPath,
                    prompt: Text(settings.areaPath.isEmpty ? "Engine default" : settings.areaPath)
                )
                HStack {
                    TextField(
                        "Iteration path",
                        text: $iterationPath,
                        prompt: Text(settings.iterationPath.isEmpty ? "Engine default" : settings.iterationPath)
                    )
                    RunButton("Pick Current", systemImage: "scope", isRunning: pickTask.isRunning, action: pickIteration)
                        .help("Find the nearest iteration under the area path (iteration-pick)")
                }
                if let message = pickTask.errorMessage {
                    ErrorBanner(message: message)
                }
                TextField("Parent ID", text: $parentID, prompt: Text("Optional"))
            }

            Section("Assignment") {
                TextField("Assigned to", text: $assignedTo, prompt: Text("Email or display name"))
                TextField("Secondary assignee", text: $secondaryAssignee, prompt: Text("Optional"))
            }

            Section {
                HStack {
                    Spacer()
                    Button("Clear", action: reset)
                    RunButton("Create \(type)", systemImage: "plus.circle.fill", isRunning: createTask.isRunning, action: create)
                        .keyboardShortcut(.return, modifiers: .command)
                        .disabled(title.trimmed.isEmpty)
                }
                if let message = createTask.errorMessage {
                    ErrorBanner(message: message)
                }
                if let created {
                    HStack {
                        SuccessLabel(message: "Created #\(created.id) — \(created.title ?? "")")
                        Spacer()
                        Button("Copy Link") { Desktop.copy(created.url) }
                        Button("Open in Azure DevOps") { Desktop.open(created.url) }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Create Work Item")
    }

    private func create() {
        var args = ["create", "--title=\(title.trimmed)", "--type=\(type)"]
        if !description.trimmed.isEmpty {
            args.append("--description=\(description)")
        }
        for criterion in Format.lines(criteria) {
            args.append("--ac=\(criterion)")
        }
        if !areaPath.trimmed.isEmpty {
            args.append("--area-path=\(areaPath.trimmed)")
        }
        if !iterationPath.trimmed.isEmpty {
            args.append("--iteration-path=\(iterationPath.trimmed)")
        }
        if !parentID.trimmed.isEmpty {
            guard let parent = Int(parentID.trimmed) else {
                createTask.errorMessage = "Parent ID must be a number."
                return
            }
            args.append("--parent-id=\(parent)")
        }
        if !assignedTo.trimmed.isEmpty {
            args.append("--assigned-to=\(assignedTo.trimmed)")
        }
        if !secondaryAssignee.trimmed.isEmpty {
            args.append("--secondary-assignee=\(secondaryAssignee.trimmed)")
        }

        let finalArgs = args
        created = nil
        createTask.run {
            created = try await cli.run(finalArgs, as: WorkItemSummary.self)
            // Keep placement and assignment so several related items can be created in a row.
            title = ""
            description = ""
            criteria = ""
        }
    }

    private func pickIteration() {
        let area = areaPath.trimmed.isEmpty ? settings.areaPath.trimmed : areaPath.trimmed
        guard !area.isEmpty else {
            pickTask.errorMessage = "Enter an area path first."
            return
        }
        pickTask.run {
            let pick = try await cli.run(["iteration-pick", "--area-path=\(area)"], as: IterationPick.self)
            iterationPath = pick.path
        }
    }

    private func reset() {
        title = ""
        description = ""
        criteria = ""
        areaPath = ""
        iterationPath = ""
        parentID = ""
        assignedTo = ""
        secondaryAssignee = ""
        created = nil
        createTask.errorMessage = nil
        pickTask.errorMessage = nil
    }
}
