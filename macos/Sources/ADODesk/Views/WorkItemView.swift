import SwiftUI

struct WorkItemView: View {
    @EnvironmentObject private var cli: CLIRunner
    @StateObject private var lookup = TaskState()
    @StateObject private var mutation = TaskState()

    @State private var idText = ""
    @State private var item: WorkItemDetail?
    @State private var webURL: String?
    @State private var showAllFields = false
    @State private var statusMessage: String?
    @State private var confirmDelete = false

    // Update form: blank means "leave unchanged".
    @State private var newTitle = ""
    @State private var newState = ""
    @State private var newAssignee = ""
    @State private var newSecondary = ""
    @State private var newPriority = ""
    @State private var newPoints = ""
    @State private var newDescription = ""
    @State private var newCriteria = ""
    @State private var newHistory = ""

    @State private var commentText = ""

    private static let summaryFields: [(key: String, label: String)] = [
        ("System.WorkItemType", "Type"),
        ("System.State", "State"),
        ("System.AssignedTo", "Assigned to"),
        ("Custom.SecondaryAssignee", "Secondary"),
        ("System.AreaPath", "Area"),
        ("System.IterationPath", "Iteration"),
        ("Microsoft.VSTS.Common.Priority", "Priority"),
        ("Microsoft.VSTS.Scheduling.StoryPoints", "Story points"),
        ("System.Tags", "Tags"),
        ("System.CreatedDate", "Created"),
        ("System.ChangedDate", "Changed"),
    ]

    private static let stateSuggestions = ["New", "Active", "Resolved", "Closed", "Removed"]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                lookupBar
                if let message = lookup.errorMessage {
                    ErrorBanner(message: message)
                }
                if let item {
                    details(item)
                    updateForm(item)
                    commentBox(item)
                    dangerZone(item)
                } else if !lookup.isRunning {
                    Text("Enter a work item ID to view, update, comment on, or delete it.")
                        .foregroundStyle(.secondary)
                        .padding(.top, 40)
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(20)
            .frame(maxWidth: 920, alignment: .leading)
        }
        .navigationTitle("Work Item")
        .confirmationDialog(
            "Delete work item #\(item?.id ?? 0)?",
            isPresented: $confirmDelete,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive, action: delete)
        } message: {
            Text("The item moves to the Azure DevOps recycle bin.")
        }
    }

    // MARK: Sections

    private var lookupBar: some View {
        HStack {
            TextField("Work item ID", text: $idText, prompt: Text("Work item ID"))
                .frame(width: 180)
                .onSubmit(fetch)
            RunButton("Fetch", systemImage: "arrow.down.circle", isRunning: lookup.isRunning, action: fetch)
                .keyboardShortcut(.defaultAction)
            if item != nil {
                Button {
                    if let id = item?.id { reload(id) }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(lookup.isRunning)
            }
            Spacer()
        }
    }

    private func details(_ item: WorkItemDetail) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    Text("#\(item.id)").font(.title2).foregroundStyle(.secondary)
                    Text(item.title ?? "Untitled").font(.title2.bold()).textSelection(.enabled)
                    Spacer()
                    if let webURL {
                        Button {
                            Desktop.open(webURL)
                        } label: {
                            Label("Open in Azure DevOps", systemImage: "safari")
                        }
                        Button {
                            Desktop.copy(webURL)
                        } label: {
                            Image(systemName: "link")
                        }
                        .help("Copy link")
                    }
                }

                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                    ForEach(Self.summaryFields, id: \.key) { entry in
                        let value = item.field(entry.key)
                        if !value.isEmpty {
                            GridRow {
                                Text(entry.label).foregroundStyle(.secondary)
                                Text(value).textSelection(.enabled)
                            }
                        }
                    }
                }

                let description = Format.plainText(fromHTML: item.field("System.Description"))
                if !description.isEmpty {
                    Divider()
                    Text("Description").font(.headline)
                    Text(description).textSelection(.enabled)
                }

                let criteria = Format.plainText(fromHTML: item.field("Microsoft.VSTS.Common.AcceptanceCriteria"))
                if !criteria.isEmpty {
                    Divider()
                    Text("Acceptance Criteria").font(.headline)
                    Text(criteria).textSelection(.enabled)
                }

                DisclosureGroup("All fields (\(item.fields.count))", isExpanded: $showAllFields) {
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                        ForEach(item.fields.keys.sorted(), id: \.self) { key in
                            GridRow {
                                Text(key).font(.caption.monospaced()).foregroundStyle(.secondary)
                                Text(item.fields[key]?.displayText ?? "")
                                    .font(.caption)
                                    .lineLimit(4)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                    .padding(.top, 6)
                }
            }
            .padding(6)
        }
    }

    private func updateForm(_ item: WorkItemDetail) -> some View {
        GroupBox("Update") {
            VStack(alignment: .leading, spacing: 10) {
                Text("Only filled-in fields are sent; blank fields keep their current values.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Form {
                    TextField("Title", text: $newTitle, prompt: Text(item.title ?? ""))
                    HStack {
                        TextField("State", text: $newState, prompt: Text(item.state ?? ""))
                        Menu {
                            ForEach(Self.stateSuggestions, id: \.self) { state in
                                Button(state) { newState = state }
                            }
                        } label: {
                            Image(systemName: "chevron.down")
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                    }
                    TextField("Assigned to", text: $newAssignee, prompt: Text(item.field("System.AssignedTo")))
                    TextField("Secondary assignee", text: $newSecondary, prompt: Text(item.field("Custom.SecondaryAssignee")))
                    TextField("Priority", text: $newPriority, prompt: Text(item.field("Microsoft.VSTS.Common.Priority")))
                    TextField("Story points", text: $newPoints, prompt: Text(item.field("Microsoft.VSTS.Scheduling.StoryPoints")))
                    TextField(
                        "Description",
                        text: $newDescription,
                        prompt: Text("Replaces the description (Markdown supported)"),
                        axis: .vertical
                    )
                    .lineLimit(3...10)
                    TextField(
                        "Acceptance criteria",
                        text: $newCriteria,
                        prompt: Text("Replaces criteria, one per line"),
                        axis: .vertical
                    )
                    .lineLimit(2...8)
                    TextField("History note", text: $newHistory, prompt: Text("Optional note added to the history"))
                }
                HStack {
                    if let statusMessage {
                        SuccessLabel(message: statusMessage)
                    }
                    Spacer()
                    Button("Clear", action: resetForm)
                    RunButton("Save Changes", systemImage: "square.and.arrow.down", isRunning: mutation.isRunning, action: save)
                }
                if let message = mutation.errorMessage {
                    ErrorBanner(message: message)
                }
            }
            .padding(6)
        }
    }

    private func commentBox(_ item: WorkItemDetail) -> some View {
        GroupBox("Comment") {
            VStack(alignment: .leading, spacing: 8) {
                TextEditor(text: $commentText)
                    .font(.body)
                    .frame(minHeight: 80)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
                HStack {
                    Spacer()
                    RunButton("Post Comment", systemImage: "text.bubble", isRunning: mutation.isRunning, action: postComment)
                        .disabled(commentText.trimmed.isEmpty)
                }
            }
            .padding(6)
        }
    }

    private func dangerZone(_ item: WorkItemDetail) -> some View {
        HStack {
            Spacer()
            Button(role: .destructive) {
                confirmDelete = true
            } label: {
                Label("Delete Work Item…", systemImage: "trash")
            }
            .disabled(mutation.isRunning)
        }
    }

    // MARK: Actions

    private func fetch() {
        guard let id = Int(idText.trimmed) else {
            lookup.errorMessage = "Enter a numeric work item ID."
            return
        }
        statusMessage = nil
        mutation.errorMessage = nil
        resetForm()
        reload(id)
    }

    private func reload(_ id: Int) {
        lookup.run {
            let envelope = try await cli.runEnvelope(["get", "--id=\(id)"], as: WorkItemDetail.self)
            item = envelope.result
            webURL = WebLinks.workItem(org: envelope.organization, project: envelope.project, id: id)
        }
    }

    private func save() {
        guard let id = item?.id else { return }
        statusMessage = nil

        var args = ["update", "--id=\(id)"]
        func add(_ flag: String, _ value: String) {
            let value = value.trimmed
            if !value.isEmpty { args.append("--\(flag)=\(value)") }
        }

        if !newPriority.trimmed.isEmpty, Int(newPriority.trimmed) == nil {
            mutation.errorMessage = "Priority must be a whole number."
            return
        }
        if !newPoints.trimmed.isEmpty, Double(newPoints.trimmed) == nil {
            mutation.errorMessage = "Story points must be a number."
            return
        }

        add("title", newTitle)
        add("state", newState)
        add("assigned-to", newAssignee)
        add("secondary-assignee", newSecondary)
        add("priority", newPriority)
        add("story-points", newPoints)
        add("description", newDescription)
        for criterion in Format.lines(newCriteria) {
            args.append("--ac=\(criterion)")
        }
        add("add-comment", newHistory)

        guard args.count > 2 else {
            mutation.errorMessage = "Nothing to update — fill in at least one field."
            return
        }

        let finalArgs = args
        mutation.run {
            let result = try await cli.run(finalArgs, as: UpdateResult.self)
            resetForm()
            statusMessage = "Updated \(result.updatedFieldsCount) field(s)."
            reload(id)
        }
    }

    private func postComment() {
        guard let id = item?.id else { return }
        let body = commentText.trimmed
        statusMessage = nil
        mutation.run {
            _ = try await cli.run(["comment", "--id=\(id)", "--body=\(body)"], as: CommentResult.self)
            commentText = ""
            statusMessage = "Comment posted."
        }
    }

    private func delete() {
        guard let id = item?.id else { return }
        mutation.run {
            _ = try await cli.run(["delete", "--id=\(id)"], as: DeleteResult.self)
            item = nil
            webURL = nil
            idText = ""
            resetForm()
            lookup.errorMessage = nil
            statusMessage = nil
        }
    }

    private func resetForm() {
        newTitle = ""
        newState = ""
        newAssignee = ""
        newSecondary = ""
        newPriority = ""
        newPoints = ""
        newDescription = ""
        newCriteria = ""
        newHistory = ""
    }
}
