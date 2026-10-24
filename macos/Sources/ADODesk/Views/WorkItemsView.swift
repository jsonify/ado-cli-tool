import SwiftUI

/// Recently opened items on the left, the selected item's inline editor on the right.
struct WorkItemsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var query = ""
    @State private var stateFilter = ""

    private var states: [String] {
        Array(Set(model.recents.map(\.state).filter { !$0.isEmpty })).sorted()
    }

    private var filtered: [RecentItem] {
        let text = query.trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        return model.recents.filter { item in
            (stateFilter.isEmpty || item.state == stateFilter)
                && (text.isEmpty || item.title.localizedCaseInsensitiveContains(text) || String(item.id).hasPrefix(text))
        }
    }

    /// "1234" or "#1234" in the search field opens that item.
    private var typedID: Int? {
        Int(query.trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "#")))
    }

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                VStack(spacing: 8) {
                    TextField("Open #ID or filter", text: $query)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit {
                            if let id = typedID {
                                model.openWorkItem(id)
                                query = ""
                            }
                        }
                    Picker("State", selection: $stateFilter) {
                        Text("All states").tag("")
                        ForEach(states, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden()
                }
                .padding(10)

                List(selection: $model.selectedItemID) {
                    if let id = typedID, !model.recents.contains(where: { $0.id == id }) {
                        Label("Open #\(id)", systemImage: "arrow.right.circle")
                            .foregroundStyle(Color.accentColor)
                            .tag(id)
                    }
                    Section("Recent") {
                        ForEach(filtered) { item in
                            RecentItemRow(item: item)
                                .tag(item.id)
                                .contextMenu {
                                    Button("Remove from Recents") { model.forget(item.id) }
                                }
                        }
                    }
                }

                if model.recents.isEmpty {
                    Text("Items you open or create show up here. Type an ID above to open one.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding()
                }
                Divider()
                HStack {
                    Text("\(filtered.count) item(s)").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Clear") { model.clearRecents() }
                        .buttonStyle(.borderless)
                        .disabled(model.recents.isEmpty)
                }
                .padding(8)
            }
            .frame(minWidth: 250, idealWidth: 290, maxWidth: 380)

            Group {
                if let id = model.selectedItemID {
                    WorkItemEditor(id: id)
                        .id(id)
                } else {
                    VStack(spacing: 10) {
                        Image(systemName: "checklist").font(.system(size: 36)).foregroundStyle(.tertiary)
                        Text("Select an item, or type its ID to open it.").foregroundStyle(.secondary)
                        Button("New Work Item…") { model.showNewItem = true }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(minWidth: 560, maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle("Work Items")
    }
}

private struct RecentItemRow: View {
    let item: RecentItem

    var body: some View {
        HStack(spacing: 8) {
            WorkItemTypeIcon(type: item.type)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title.isEmpty ? "Untitled" : item.title).lineLimit(1)
                HStack(spacing: 6) {
                    Text("#\(item.id)").monospacedDigit()
                    if !item.state.isEmpty {
                        StateBadge(state: item.state)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

private struct Criterion: Identifiable, Equatable {
    let id = UUID()
    var text: String
}

/// The editable parts of a work item. Each one that differs from the loaded value is sent on save.
private struct Draft: Equatable {
    var title = ""
    var state = ""
    var assignee = ""
    var secondary = ""
    var priority: Int?
    var points = ""
    var description = ""
    var criteria: [Criterion] = []

    init() {}

    init(_ item: WorkItemDetail) {
        title = item.title ?? ""
        state = item.state ?? ""
        assignee = item.field("System.AssignedTo")
        secondary = item.field("Custom.SecondaryAssignee")
        priority = Int(item.field("Microsoft.VSTS.Common.Priority"))
        points = item.field("Microsoft.VSTS.Scheduling.StoryPoints")
        description = Format.plainText(fromHTML: item.field("System.Description"))
        criteria = Format.lines(Format.plainText(fromHTML: item.field("Microsoft.VSTS.Common.AcceptanceCriteria")))
            .map { Criterion(text: $0.hasPrefix("• ") ? String($0.dropFirst(2)) : $0) }
    }

    var cleanCriteria: [String] { criteria.map(\.text.trimmed).filter { !$0.isEmpty } }
}

struct WorkItemEditor: View {
    let id: Int

    @EnvironmentObject private var cli: CLIRunner
    @EnvironmentObject private var model: AppModel
    @StateObject private var load = TaskState()
    @StateObject private var mutation = TaskState()

    @State private var item: WorkItemDetail?
    @State private var webURL: String?
    @State private var original = Draft()
    @State private var draft = Draft()
    @State private var comment = ""
    @State private var statusMessage: String?
    @State private var confirmDelete = false
    @State private var showAllFields = false

    private static let knownStates = ["New", "Active", "Resolved", "Closed", "Removed"]

    private var changeCount: Int {
        [
            draft.title != original.title,
            draft.state != original.state,
            draft.assignee != original.assignee,
            draft.secondary != original.secondary,
            draft.priority != original.priority,
            draft.points.trimmed != original.points.trimmed,
            draft.description != original.description,
            draft.cleanCriteria != original.cleanCriteria,
        ].filter { $0 }.count
    }

    var body: some View {
        Group {
            if let item {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        header(item)
                        if let message = load.errorMessage ?? mutation.errorMessage {
                            ErrorBanner(message: message)
                        }
                        if let statusMessage {
                            SuccessLabel(message: statusMessage)
                        }
                        properties(item)
                        descriptionSection
                        criteriaSection
                        commentSection
                        allFields(item)
                    }
                    .padding(20)
                    .frame(maxWidth: 900, alignment: .leading)
                }
                .safeAreaInset(edge: .bottom) {
                    if changeCount > 0 { unsavedBar }
                }
            } else if load.isRunning {
                ProgressView("Loading #\(id)…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 12) {
                    if let message = load.errorMessage {
                        ErrorBanner(message: message).frame(maxWidth: 520)
                    }
                    Button("Try Again", action: reload)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear(perform: reload)
        .confirmationDialog("Delete work item #\(id)?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive, action: delete)
        } message: {
            Text("The item moves to the Azure DevOps recycle bin, where it can be restored.")
        }
    }

    // MARK: Sections

    private func header(_ item: WorkItemDetail) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                WorkItemTypeIcon(type: item.field("System.WorkItemType"))
                Text("\(item.field("System.WorkItemType")) #\(item.id)")
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Spacer()
                if load.isRunning {
                    ProgressView().controlSize(.small)
                }
                Button {
                    Desktop.open(webURL)
                } label: {
                    Label("Open in Browser", systemImage: "safari")
                }
                .disabled(webURL == nil)
                Button {
                    if let webURL { Desktop.copy(webURL) }
                } label: {
                    Image(systemName: "link")
                }
                .help("Copy link")
                .disabled(webURL == nil)
                Menu {
                    Button("Reload", action: reload)
                    Button("Copy ID") { Desktop.copy(String(item.id)) }
                    Divider()
                    Button("Delete…", role: .destructive) { confirmDelete = true }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            TextField("Title", text: $draft.title, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.title.bold())
                .changedHighlight(draft.title != original.title)
        }
    }

    private func properties(_ item: WorkItemDetail) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 10) {
            GridRow {
                propertyLabel("State")
                Picker("State", selection: $draft.state) {
                    ForEach(stateOptions, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
                .frame(maxWidth: 200)
                .changedHighlight(draft.state != original.state)
                propertyLabel("Priority")
                Picker("Priority", selection: $draft.priority) {
                    ForEach(1...4, id: \.self) { Text("\($0)").tag(Optional($0)) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 180)
                .changedHighlight(draft.priority != original.priority)
            }
            GridRow {
                propertyLabel("Assigned to")
                TextField("Assigned to", text: $draft.assignee, prompt: Text("Unassigned"))
                    .labelsHidden()
                    .changedHighlight(draft.assignee != original.assignee)
                propertyLabel("Story points")
                HStack(spacing: 4) {
                    TextField("Story points", text: $draft.points, prompt: Text("–"))
                        .labelsHidden()
                        .frame(width: 70)
                    Stepper("Story points", onIncrement: { stepPoints(1) }, onDecrement: { stepPoints(-1) })
                        .labelsHidden()
                }
                .changedHighlight(draft.points.trimmed != original.points.trimmed)
            }
            GridRow {
                propertyLabel("Secondary")
                TextField("Secondary assignee", text: $draft.secondary, prompt: Text("None"))
                    .labelsHidden()
                    .changedHighlight(draft.secondary != original.secondary)
                propertyLabel("Tags")
                Text(item.field("System.Tags").isEmpty ? "—" : item.field("System.Tags"))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            GridRow {
                propertyLabel("Area")
                Text(item.field("System.AreaPath"))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                propertyLabel("Iteration")
                Text(item.field("System.IterationPath"))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
    }

    private var stateOptions: [String] {
        original.state.isEmpty || Self.knownStates.contains(original.state)
            ? Self.knownStates
            : [original.state] + Self.knownStates
    }

    private var descriptionSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle("Description", note: "Markdown is converted when saved.")
            TextEditor(text: $draft.description)
                .font(.body)
                .frame(minHeight: 110)
                .padding(4)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.25)))
                .changedHighlight(draft.description != original.description)
        }
    }

    private var criteriaSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle("Acceptance Criteria", note: nil)
            VStack(alignment: .leading, spacing: 4) {
                ForEach($draft.criteria) { $criterion in
                    HStack {
                        Image(systemName: "checkmark.circle").foregroundStyle(.secondary)
                        TextField("Criterion", text: $criterion.text)
                            .textFieldStyle(.plain)
                        Button {
                            draft.criteria.removeAll { $0.id == criterion.id }
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .help("Remove criterion")
                    }
                    .padding(.vertical, 3)
                }
                Button {
                    draft.criteria.append(Criterion(text: ""))
                } label: {
                    Label("Add Criterion", systemImage: "plus")
                }
                .buttonStyle(.borderless)
            }
            .changedHighlight(draft.cleanCriteria != original.cleanCriteria)
        }
    }

    private var commentSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle("Comment", note: "Posted to the item's discussion.")
            HStack(alignment: .bottom) {
                TextField("Add a comment…", text: $comment, axis: .vertical)
                    .lineLimit(2...6)
                    .textFieldStyle(.roundedBorder)
                RunButton("Post", systemImage: "paperplane", isRunning: mutation.isRunning, action: postComment)
                    .disabled(comment.trimmed.isEmpty)
            }
        }
    }

    private func allFields(_ item: WorkItemDetail) -> some View {
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

    private var unsavedBar: some View {
        HStack {
            Image(systemName: "pencil.circle.fill").foregroundStyle(Color.accentColor)
            Text("\(changeCount) unsaved change\(changeCount == 1 ? "" : "s")")
            Spacer()
            Button("Discard") {
                draft = original
                mutation.errorMessage = nil
            }
            .disabled(mutation.isRunning)
            RunButton("Save", systemImage: "square.and.arrow.down", isRunning: mutation.isRunning, action: save)
                .keyboardShortcut("s")
                .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    private func propertyLabel(_ text: String) -> some View {
        Text(text).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
    }

    private func sectionTitle(_ title: String, note: String?) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.headline)
            if let note {
                Text(note).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func stepPoints(_ delta: Double) {
        let current = Double(draft.points.trimmed) ?? 0
        draft.points = Format.points(max(0, current + delta))
    }

    // MARK: Actions

    private func reload() {
        load.run {
            let envelope = try await cli.runEnvelope(["get", "--id=\(id)"], as: WorkItemDetail.self)
            guard let loaded = envelope.result else { return }
            item = loaded
            webURL = WebLinks.workItem(org: envelope.organization, project: envelope.project, id: id)
            original = Draft(loaded)
            draft = original
            model.remember(
                id: id,
                title: loaded.title,
                state: loaded.state,
                type: loaded.field("System.WorkItemType")
            )
        }
    }

    private func save() {
        var args = ["update", "--id=\(id)"]
        if draft.title != original.title {
            guard !draft.title.trimmed.isEmpty else {
                mutation.errorMessage = "The title can't be empty."
                return
            }
            args.append("--title=\(draft.title.trimmed)")
        }
        if draft.state != original.state { args.append("--state=\(draft.state)") }
        if draft.assignee != original.assignee { args.append("--assigned-to=\(draft.assignee.trimmed)") }
        if draft.secondary != original.secondary { args.append("--secondary-assignee=\(draft.secondary.trimmed)") }
        if draft.priority != original.priority, let priority = draft.priority {
            args.append("--priority=\(priority)")
        }
        if draft.points.trimmed != original.points.trimmed {
            guard let points = Double(draft.points.trimmed) else {
                mutation.errorMessage = "Story points must be a number."
                return
            }
            args.append("--story-points=\(Format.points(points))")
        }
        if draft.description != original.description { args.append("--description=\(draft.description)") }
        if draft.cleanCriteria != original.cleanCriteria {
            guard !draft.cleanCriteria.isEmpty else {
                mutation.errorMessage = "The engine can't remove every acceptance criterion. Keep at least one."
                return
            }
            args += draft.cleanCriteria.map { "--ac=\($0)" }
        }

        let finalArgs = args
        statusMessage = nil
        mutation.run {
            let result = try await cli.run(finalArgs, as: UpdateResult.self)
            statusMessage = "Saved \(result.updatedFieldsCount) field\(result.updatedFieldsCount == 1 ? "" : "s")."
            reload()
        }
    }

    private func postComment() {
        let body = comment.trimmed
        statusMessage = nil
        mutation.run {
            _ = try await cli.run(["comment", "--id=\(id)", "--body=\(body)"], as: CommentResult.self)
            comment = ""
            statusMessage = "Comment posted."
        }
    }

    private func delete() {
        mutation.run {
            _ = try await cli.run(["delete", "--id=\(id)"], as: DeleteResult.self)
            model.forget(id)
        }
    }
}
