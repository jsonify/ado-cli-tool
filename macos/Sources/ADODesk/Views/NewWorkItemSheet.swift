import SwiftUI

/// ⌘N: create a work item. Suggests an iteration so there's no separate picker step.
struct NewWorkItemSheet: View {
    @EnvironmentObject private var cli: CLIRunner
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
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
    @State private var suggestion: IterationPick?
    @State private var createAnother = false
    @State private var lastCreated: WorkItemSummary?

    private static let types = ["User Story", "Task", "Bug", "Feature", "Epic"]

    private var effectiveArea: String {
        areaPath.trimmed.isEmpty ? settings.areaPath.trimmed : areaPath.trimmed
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    Picker("Type", selection: $type) {
                        ForEach(Self.types, id: \.self) { Text($0).tag($0) }
                    }
                    TextField("Title", text: $title)
                    TextField(
                        "Description",
                        text: $description,
                        prompt: Text("Markdown: # headings, - bullets, `code`"),
                        axis: .vertical
                    )
                    .lineLimit(3...8)
                    TextField(
                        "Acceptance criteria",
                        text: $criteria,
                        prompt: Text("One criterion per line"),
                        axis: .vertical
                    )
                    .lineLimit(2...6)
                }

                Section("Placement") {
                    TextField(
                        "Area path",
                        text: $areaPath,
                        prompt: Text(settings.areaPath.isEmpty ? "Engine default" : settings.areaPath)
                    )
                    .onSubmit(suggestIteration)
                    TextField(
                        "Iteration",
                        text: $iterationPath,
                        prompt: Text(settings.iterationPath.isEmpty ? "Engine default" : settings.iterationPath)
                    )
                    iterationChips
                    TextField("Parent ID", text: $parentID, prompt: Text("Optional"))
                }

                Section("Assignment") {
                    TextField(
                        "Assigned to",
                        text: $assignedTo,
                        prompt: Text(settings.assignee.isEmpty ? "Email or display name" : settings.assignee)
                    )
                    TextField("Secondary", text: $secondaryAssignee, prompt: Text("Optional"))
                }

                if let message = createTask.errorMessage {
                    ErrorBanner(message: message)
                }
                if let lastCreated {
                    SuccessLabel(message: "Created #\(lastCreated.id): \(lastCreated.title ?? "")")
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Toggle("Create another", isOn: $createAnother)
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                RunButton("Create \(type)", systemImage: "plus.circle.fill", isRunning: createTask.isRunning, action: create)
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent)
                    .disabled(title.trimmed.isEmpty)
            }
            .padding(14)
        }
        .frame(width: 560, height: 640)
        .onAppear(perform: suggestIteration)
    }

    @ViewBuilder
    private var iterationChips: some View {
        let current = model.currentIteration
        if current?.path != nil || suggestion != nil || pickTask.isRunning || pickTask.errorMessage != nil {
            HStack(spacing: 8) {
                if let current, let path = current.path {
                    chip("Current sprint: \(current.name ?? path)", selected: iterationPath == path) {
                        iterationPath = path
                    }
                }
                if let suggestion, suggestion.path != current?.path {
                    chip("Suggested: \(suggestion.name)", selected: iterationPath == suggestion.path) {
                        iterationPath = suggestion.path
                    }
                    .help("iteration-pick for \(effectiveArea)")
                }
                if pickTask.isRunning {
                    ProgressView().controlSize(.small)
                } else if pickTask.errorMessage != nil {
                    Text("No suggestion for this area path.").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
        }
    }

    private func chip(_ text: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(text, systemImage: selected ? "checkmark" : "sparkles")
                .font(.caption)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(Color.accentColor.opacity(selected ? 0.25 : 0.12)))
        }
        .buttonStyle(.plain)
    }

    private func suggestIteration() {
        let area = effectiveArea
        guard !area.isEmpty else { return }
        suggestion = nil
        pickTask.run {
            suggestion = try await cli.run(["iteration-pick", "--area-path=\(area)"], as: IterationPick.self)
        }
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
        let itemType = type
        lastCreated = nil
        createTask.run {
            let created = try await cli.run(finalArgs, as: WorkItemSummary.self)
            model.remember(id: created.id, title: created.title, state: created.state, type: itemType)
            if createAnother {
                // Keep placement and assignment so related items can be created in a row.
                lastCreated = created
                title = ""
                description = ""
                criteria = ""
            } else {
                model.openWorkItem(created.id)
                dismiss()
            }
        }
    }
}
