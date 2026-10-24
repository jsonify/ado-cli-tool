import AppKit
import SwiftUI

struct ExportsView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                ClosedStoriesExportBox()
                ModificationsExportBox()
            }
            .padding(20)
            .frame(maxWidth: 960, alignment: .leading)
        }
        .navigationTitle("Exports")
    }
}

private struct ClosedStoriesExportBox: View {
    @EnvironmentObject private var cli: CLIRunner
    @EnvironmentObject private var settings: SettingsStore
    @StateObject private var task = TaskState()

    @State private var fromDate = ClosedStoriesExportBox.startOfYear()
    @State private var limitToDate = false
    @State private var toDate = Date()
    @State private var workItemType = "User Story"
    @State private var states = "Closed,Resolved"
    @State private var assignee = ""
    @State private var outputURL: URL?
    @State private var result: ExportClosedResult?

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                Text("Closed Stories").font(.headline)
                Text("Exports stories closed by an assignee within a date range to a JSON file.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Form {
                    DatePicker("From", selection: $fromDate, displayedComponents: .date)
                    Toggle("Limit end date", isOn: $limitToDate)
                    if limitToDate {
                        DatePicker("To", selection: $toDate, in: fromDate..., displayedComponents: .date)
                    }
                    TextField("Work item type", text: $workItemType)
                    TextField("States", text: $states, prompt: Text("Comma-separated"))
                    TextField(
                        "Assigned to",
                        text: $assignee,
                        prompt: Text(settings.assignee.isEmpty ? "Display name" : settings.assignee)
                    )
                    LabeledContent("Output file") {
                        HStack {
                            Text((outputURL ?? defaultOutputURL).path)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .foregroundStyle(.secondary)
                            Button("Choose…") {
                                let name = (outputURL ?? defaultOutputURL).lastPathComponent
                                if let url = Desktop.chooseSaveLocation(defaultName: name) {
                                    outputURL = url
                                }
                            }
                        }
                    }
                }
                HStack {
                    if let result {
                        SuccessLabel(message: "Exported \(result.count) item(s)")
                        Button("Reveal in Finder") { Desktop.reveal(result.output) }
                        Button("Open") { NSWorkspace.shared.open(URL(fileURLWithPath: result.output)) }
                    }
                    Spacer()
                    RunButton("Export", systemImage: "square.and.arrow.up", isRunning: task.isRunning, action: export)
                }
                if let message = task.errorMessage {
                    ErrorBanner(message: message)
                }
            }
            .padding(6)
        }
    }

    private var defaultOutputURL: URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        return documents
            .appendingPathComponent("ADO Exports", isDirectory: true)
            .appendingPathComponent("ado_closed_stories_since_\(Format.ymd.string(from: fromDate)).json")
    }

    private func export() {
        var args = [
            "export-closed-stories",
            "--from-date=\(Format.ymd.string(from: fromDate))",
            "--output=\((outputURL ?? defaultOutputURL).path)",
        ]
        if limitToDate {
            args.append("--to-date=\(Format.ymd.string(from: toDate))")
        }
        if !workItemType.trimmed.isEmpty {
            args.append("--work-item-type=\(workItemType.trimmed)")
        }
        if !states.trimmed.isEmpty {
            args.append("--states=\(states.trimmed)")
        }
        if !assignee.trimmed.isEmpty {
            args.append("--assigned-to=\(assignee.trimmed)")
        }
        let finalArgs = args
        result = nil
        task.run {
            result = try await cli.run(finalArgs, as: ExportClosedResult.self)
        }
    }

    private static func startOfYear() -> Date {
        let calendar = Calendar.current
        return calendar.date(from: calendar.dateComponents([.year], from: Date())) ?? Date()
    }
}

private struct ModificationsExportBox: View {
    @EnvironmentObject private var cli: CLIRunner
    @EnvironmentObject private var settings: SettingsStore
    @StateObject private var task = TaskState()

    @State private var user = ""
    @State private var fromDate = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date()
    @State private var limitToDate = false
    @State private var toDate = Date()
    @State private var result: ModificationsResult?
    @State private var selection = Set<Modification.ID>()
    @State private var saveError: String?

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                Text("Modifications").font(.headline)
                Text("Every work item revision made by a user in a date range. Scans project history, so wide ranges can take a while.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Form {
                    TextField(
                        "User",
                        text: $user,
                        prompt: Text(settings.assignee.isEmpty ? "Display name" : settings.assignee)
                    )
                    DatePicker("From", selection: $fromDate, displayedComponents: .date)
                    Toggle("Limit end date", isOn: $limitToDate)
                    if limitToDate {
                        DatePicker("To", selection: $toDate, in: fromDate..., displayedComponents: .date)
                    }
                }
                HStack {
                    if let result {
                        Text("\(result.count) revision(s)").foregroundStyle(.secondary)
                        Button("Save JSON…") { save(result) }
                    }
                    Spacer()
                    RunButton("Run", systemImage: "magnifyingglass", isRunning: task.isRunning, action: run)
                }
                if let message = task.errorMessage ?? saveError {
                    ErrorBanner(message: message)
                }
                if let result, !result.items.isEmpty {
                    table(result.items)
                }
            }
            .padding(6)
        }
    }

    private func table(_ items: [Modification]) -> some View {
        Table(items, selection: $selection) {
            TableColumn("Changed") { (item: Modification) in
                Text(Format.minute(item.changedDate)).monospacedDigit()
            }
            .width(130)
            TableColumn("ID") { (item: Modification) in
                Text("#\(item.workItemID)").monospacedDigit()
            }
            .width(70)
            TableColumn("Rev") { (item: Modification) in
                Text(item.revision.map { String($0) } ?? "").monospacedDigit()
            }
            .width(40)
            TableColumn("Type") { (item: Modification) in
                Text(item.workItemType ?? "")
            }
            .width(90)
            TableColumn("Title") { (item: Modification) in
                Text(item.title ?? "")
            }
            TableColumn("State") { (item: Modification) in
                Text(item.state ?? "")
            }
            .width(80)
        }
        .contextMenu(forSelectionType: Modification.ID.self) { ids in
            Button("Open in Azure DevOps") { open(ids, in: items) }
        } primaryAction: { ids in
            open(ids, in: items)
        }
        .frame(height: 320)
    }

    private func run() {
        let name = user.trimmed.isEmpty ? settings.assignee.trimmed : user.trimmed
        guard !name.isEmpty else {
            task.errorMessage = "Enter a user display name."
            return
        }
        var args = ["export-modifications", "--user=\(name)", "--from-date=\(Format.ymd.string(from: fromDate))"]
        if limitToDate {
            args.append("--to-date=\(Format.ymd.string(from: toDate))")
        }
        let finalArgs = args
        result = nil
        saveError = nil
        task.run {
            result = try await cli.run(finalArgs, as: ModificationsResult.self)
            selection = []
        }
    }

    private func open(_ ids: Set<Modification.ID>, in items: [Modification]) {
        // Several revisions can share a work item; open each item once.
        var opened = Set<Int>()
        for item in items where ids.contains(item.id) {
            if opened.insert(item.workItemID).inserted {
                Desktop.open(item.url)
            }
        }
    }

    private func save(_ result: ModificationsResult) {
        let name = "ado_modifications_\(result.fromDate).json"
        guard let url = Desktop.chooseSaveLocation(defaultName: name) else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        do {
            try encoder.encode(result).write(to: url, options: .atomic)
            saveError = nil
        } catch {
            saveError = "Could not save file: \(error.localizedDescription)"
        }
    }
}
