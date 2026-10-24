import SwiftUI

struct PickIterationView: View {
    @EnvironmentObject private var cli: CLIRunner
    @EnvironmentObject private var settings: SettingsStore
    @StateObject private var task = TaskState()

    @State private var areaPath = ""
    @State private var useToday = true
    @State private var date = Date()
    @State private var result: IterationPick?

    var body: some View {
        Form {
            Section {
                TextField(
                    "Area path",
                    text: $areaPath,
                    prompt: Text(settings.areaPath.isEmpty ? #"Project\Team"# : settings.areaPath)
                )
                Toggle("Use today's date", isOn: $useToday)
                if !useToday {
                    DatePicker("Reference date", selection: $date, displayedComponents: .date)
                }
            } footer: {
                Text("Finds the nearest `FY##\\Month YYYY` iteration under the area subtree, fiscal-year aware (FY starts in September).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                HStack {
                    Spacer()
                    RunButton("Pick Iteration", systemImage: "scope", isRunning: task.isRunning, action: pick)
                        .keyboardShortcut(.defaultAction)
                }
                if let message = task.errorMessage {
                    ErrorBanner(message: message)
                }
            }

            if let result {
                Section("Result") {
                    LabeledContent("Iteration", value: result.name)
                    LabeledContent("Fiscal year", value: result.fiscalYear)
                    LabeledContent("Path") {
                        HStack {
                            Text(result.path).textSelection(.enabled)
                            Button {
                                Desktop.copy(result.path)
                            } label: {
                                Image(systemName: "doc.on.doc")
                            }
                            .buttonStyle(.borderless)
                            .help("Copy path")
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Pick Iteration")
    }

    private func pick() {
        let area = areaPath.trimmed.isEmpty ? settings.areaPath.trimmed : areaPath.trimmed
        guard !area.isEmpty else {
            task.errorMessage = "Enter an area path."
            return
        }
        var args = ["iteration-pick", "--area-path=\(area)"]
        if !useToday {
            args.append("--on=\(Format.ymd.string(from: date))")
        }
        let finalArgs = args
        result = nil
        task.run {
            result = try await cli.run(finalArgs, as: IterationPick.self)
        }
    }
}
