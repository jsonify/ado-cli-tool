import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    var body: some View {
        TabView {
            ConnectionSettings()
                .tabItem { Label("Connection", systemImage: "network") }
            DefaultsSettings()
                .tabItem { Label("Defaults", systemImage: "slider.horizontal.3") }
            EngineSettings()
                .tabItem { Label("Engine", systemImage: "terminal") }
        }
        .frame(width: 580)
        .padding(20)
    }
}

private struct ConnectionSettings: View {
    @EnvironmentObject private var settings: SettingsStore
    @State private var tokenInput = ""
    @State private var tokenMessage: String?

    var body: some View {
        Form {
            TextField("Organization", text: $settings.org, prompt: Text("my-org or https://dev.azure.com/my-org"))
            TextField("Project", text: $settings.project)
            TextField("Team", text: $settings.team, prompt: Text("Needed for iteration commands"))
            LabeledContent("Personal access token") {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        SecureField(
                            "Personal access token",
                            text: $tokenInput,
                            prompt: Text(settings.hasToken ? "Stored in Keychain" : "Paste a PAT")
                        )
                        .labelsHidden()
                        Button("Save") {
                            tokenMessage = settings.saveToken(tokenInput)
                                ? "Saved to the Keychain."
                                : "Could not save to the Keychain."
                            tokenInput = ""
                        }
                        .disabled(tokenInput.trimmed.isEmpty)
                        if settings.hasToken {
                            Button("Remove") {
                                settings.clearToken()
                                tokenMessage = "Removed from the Keychain."
                            }
                        }
                    }
                    Text(tokenMessage ?? (settings.hasToken
                        ? "A token is stored in the Keychain."
                        : "Needs Work Items (read & write) scope."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Text("Blank fields fall back to the engine's .env file and environment variables (ADO_ORG, ADO_PROJECT, ADO_TOKEN…).")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct DefaultsSettings: View {
    @EnvironmentObject private var settings: SettingsStore

    var body: some View {
        Form {
            TextField("Assignee", text: $settings.assignee, prompt: Text("Your display name"))
            TextField("Area path", text: $settings.areaPath, prompt: Text(#"Project\Team"#))
            TextField("Iteration path", text: $settings.iterationPath, prompt: Text(#"Project\Team\Sprint 42"#))
            Text("Used as defaults when creating work items and running reports.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct EngineSettings: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var cli: CLIRunner
    @State private var verifying = false
    @State private var verifyMessage: String?
    @State private var verifyOK = false

    var body: some View {
        Form {
            TextField("Python", text: $settings.pythonPath, prompt: Text("python3 from PATH"))
            fileRow("Script", text: $settings.scriptPath, prompt: "Bundled ado_cli.py", types: [.pythonScript])
            fileRow(".env file", text: $settings.envFile, prompt: "Optional", types: [])
            fileRow("SSL CA bundle", text: $settings.sslCertFile, prompt: "Optional (corporate proxies)", types: [])

            LabeledContent("Using") {
                Text(settings.resolvedScriptURL?.path ?? "ado_cli.py not found")
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .foregroundStyle(settings.resolvedScriptURL == nil ? Color.red : Color.secondary)
            }

            HStack {
                Button(action: verify) {
                    HStack(spacing: 6) {
                        if verifying { ProgressView().controlSize(.small) }
                        Text("Verify Engine")
                    }
                }
                .disabled(verifying)
                if let verifyMessage {
                    Label(verifyMessage, systemImage: verifyOK ? "checkmark.circle.fill" : "xmark.octagon.fill")
                        .foregroundStyle(verifyOK ? Color.green : Color.red)
                        .lineLimit(3)
                }
            }
        }
    }

    private func fileRow(_ title: String, text: Binding<String>, prompt: String, types: [UTType]) -> some View {
        LabeledContent(title) {
            HStack {
                TextField(title, text: text, prompt: Text(prompt))
                    .labelsHidden()
                Button("Choose…") {
                    if let path = Desktop.chooseFile(allowedTypes: types) {
                        text.wrappedValue = path
                    }
                }
            }
        }
    }

    private func verify() {
        verifying = true
        verifyMessage = nil
        Task { @MainActor in
            defer { verifying = false }
            do {
                let output = try await cli.execute(["--help"])
                verifyOK = output.status == 0
                if verifyOK {
                    verifyMessage = "Engine is reachable."
                } else {
                    verifyMessage = output.stderrText.isEmpty ? "Exit code \(output.status)" : output.stderrText
                }
            } catch {
                verifyOK = false
                verifyMessage = error.localizedDescription
            }
        }
    }
}
