import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ReportsView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                WeeklyReportBox()
                ClosedStoriesExportBox()
                ModificationsExportBox()
                RecentExportsBox()
            }
            .padding(20)
            .frame(maxWidth: 960, alignment: .leading)
        }
        .navigationTitle("Reports")
    }
}

private struct RecentExportsBox: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Recent Exports").font(.headline)
                    Spacer()
                    Button("Clear") { model.clearExports() }
                        .buttonStyle(.borderless)
                        .disabled(model.exports.isEmpty)
                }
                if model.exports.isEmpty {
                    Text("Files you export appear here.").foregroundStyle(.secondary)
                }
                ForEach(model.exports) { export in
                    HStack {
                        Image(systemName: "doc.text").foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(URL(fileURLWithPath: export.path).lastPathComponent)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Text("\(export.kind) · \(export.count) item(s) · \(export.date.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if FileManager.default.fileExists(atPath: export.path) {
                            Button("Open") { NSWorkspace.shared.open(URL(fileURLWithPath: export.path)) }
                            Button("Reveal in Finder") { Desktop.reveal(export.path) }
                        } else {
                            Text("Moved or deleted").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
            .padding(6)
        }
    }
}

private struct WeeklyReportBox: View {
    @EnvironmentObject private var cli: CLIRunner
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var settings: SettingsStore
    @StateObject private var task = TaskState()

    /// One area path per line, kept between launches.
    @AppStorage("reports.weeklyAreaPaths") private var areaPathsText = ""
    @AppStorage("reports.weeklyNextCount") private var nextCount = 3
    @State private var fromDate = Calendar.current.date(byAdding: .day, value: -6, to: Date()) ?? Date()
    @State private var toDate = Date()
    @State private var result: WeeklyReportResult?
    @State private var copied = false
    @State private var actionError: String?

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                Text("Weekly Report").font(.headline)
                Text("Your completed, progressed and blocked items, and what's next, for each area path. Copy it into an email or open it in Mail.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Form {
                    LabeledContent("Area paths") {
                        VStack(alignment: .leading, spacing: 4) {
                            TextEditor(text: $areaPathsText)
                                .font(.body.monospaced())
                                .frame(minHeight: 44, maxHeight: 80)
                                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.3)))
                            Text(areaPathsHint)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    DatePicker("From", selection: $fromDate, displayedComponents: .date)
                    DatePicker("To", selection: $toDate, in: fromDate..., displayedComponents: .date)
                    Stepper("Next week: \(nextCount) item(s) per area path", value: $nextCount, in: 1...10)
                }
                HStack {
                    if let result {
                        Button {
                            Desktop.copyRich(html: result.html, plain: result.markdown)
                            copied = true
                        } label: {
                            Label(copied ? "Copied" : "Copy for Email", systemImage: copied ? "checkmark" : "doc.on.clipboard")
                        }
                        Button {
                            if !Desktop.composeEmail(subject: "Weekly report: \(result.rangeLabel)", html: result.html) {
                                actionError = "No mail app is set up to compose messages. Use Copy for Email instead."
                            }
                        } label: {
                            Label("Open in Mail", systemImage: "envelope")
                        }
                        Button("Save Markdown…") { save(result) }
                    }
                    Spacer()
                    RunButton("Build Report", systemImage: "doc.text.magnifyingglass", isRunning: task.isRunning, action: run)
                }
                if let message = task.errorMessage ?? actionError {
                    ErrorBanner(message: message)
                }
                if let result {
                    preview(result)
                }
            }
            .padding(6)
        }
    }

    private var areaPaths: [String] {
        Format.lines(areaPathsText)
    }

    private var areaPathsHint: String {
        if areaPaths.isEmpty, !settings.areaPath.trimmed.isEmpty {
            return "One per line. Blank uses the default area path, \(settings.areaPath.trimmed)."
        }
        return #"One per line, for example CloudModernization\SREO Artifactory. Child areas are included."#
    }

    private func preview(_ result: WeeklyReportResult) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Weekly report: \(result.rangeLabel)").font(.title3.bold())
            ForEach(result.sections) { section in
                VStack(alignment: .leading, spacing: 8) {
                    Text(section.name).font(.headline)
                    group("Completed", section.completed) { item in "\(item.workItemType), \(item.state) \(Format.shortDay(item.date))" }
                    group("Progressed", section.progressed) { item in
                        "\(item.workItemType), \(item.fromState.flatMap { $0.isEmpty ? nil : $0 } ?? "Created") → \(item.state)"
                    }
                    group("Blockers", section.blocked) { item in
                        item.date == nil ? "\(item.workItemType), blocked" : "\(item.workItemType), blocked since \(Format.shortDay(item.date))"
                    }
                    group("Next week", section.upcoming) { item in "\(item.workItemType), \(item.state)" }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
    }

    private func group(_ title: String, _ items: [WeeklyReportItem], detail: @escaping (WeeklyReportItem) -> String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.subheadline.bold()).foregroundStyle(.secondary)
            if items.isEmpty {
                Text("None").foregroundStyle(.secondary)
            }
            ForEach(items) { item in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Button("#\(item.id)") { Desktop.open(item.url) }
                        .buttonStyle(.link)
                        .monospacedDigit()
                    Text(item.title)
                    Text("(\(detail(item)))").foregroundStyle(.secondary)
                }
                .textSelection(.enabled)
            }
        }
    }

    private func run() {
        var args = [
            "weekly-report",
            "--from-date=\(Format.ymd.string(from: fromDate))",
            "--to-date=\(Format.ymd.string(from: toDate))",
            "--next-count=\(nextCount)",
        ]
        args += areaPaths.map { "--area-path=\($0)" }
        let finalArgs = args
        result = nil
        copied = false
        actionError = nil
        task.run {
            result = try await cli.run(finalArgs, as: WeeklyReportResult.self)
        }
    }

    private func save(_ result: WeeklyReportResult) {
        let markdownType = UTType(filenameExtension: "md") ?? .plainText
        let name = "weekly_report_\(result.toDate).md"
        guard let url = Desktop.chooseSaveLocation(defaultName: name, types: [markdownType]) else { return }
        do {
            try Data(result.markdown.utf8).write(to: url, options: .atomic)
            actionError = nil
            let count = result.sections.reduce(0) { $0 + $1.completed.count + $1.progressed.count + $1.blocked.count }
            model.recordExport(kind: "Weekly report", path: url.path, count: count)
        } catch {
            actionError = "Could not save file: \(error.localizedDescription)"
        }
    }
}

private struct ClosedStoriesExportBox: View {
    @EnvironmentObject private var cli: CLIRunner
    @EnvironmentObject private var model: AppModel
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
            let exported = try await cli.run(finalArgs, as: ExportClosedResult.self)
            result = exported
            model.recordExport(kind: "Closed stories", path: exported.output, count: exported.count)
        }
    }

    private static func startOfYear() -> Date {
        let calendar = Calendar.current
        return calendar.date(from: calendar.dateComponents([.year], from: Date())) ?? Date()
    }
}

private struct ModificationsExportBox: View {
    @EnvironmentObject private var cli: CLIRunner
    @EnvironmentObject private var model: AppModel
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
            model.recordExport(kind: "Modifications", path: url.path, count: result.count)
        } catch {
            saveError = "Could not save file: \(error.localizedDescription)"
        }
    }
}
