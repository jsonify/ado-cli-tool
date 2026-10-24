import SwiftUI

/// First run: connect to Azure DevOps here, or point the engine at an existing .env file.
struct SetupCard: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var model: AppModel
    @State private var token = ""
    @State private var tokenError: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Image(systemName: "link.circle.fill")
                        .font(.system(size: 40))
                        .foregroundStyle(Color.accentColor)
                    Text("Connect to Azure DevOps").font(.title.bold())
                    Text("ADO Desk runs ado_cli.py for every action. Tell it where your work lives.")
                        .foregroundStyle(.secondary)
                }

                GroupBox {
                    Form {
                        TextField("Organization", text: $settings.org, prompt: Text("my-org or https://dev.azure.com/my-org"))
                        TextField("Project", text: $settings.project)
                        TextField("Team", text: $settings.team, prompt: Text("Needed for sprints"))
                        SecureField("Personal access token", text: $token, prompt: Text("Stored in the Keychain"))
                        Text("The token needs the Work Items (read & write) scope.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(6)
                }

                if let tokenError {
                    ErrorBanner(message: tokenError)
                }

                HStack {
                    Button("Use Existing .env File…") {
                        if let path = Desktop.chooseFile() {
                            settings.envFile = path
                            model.showSetup = false
                        }
                    }
                    Button("Skip for Now") {
                        model.setupDismissed = true
                        model.showSetup = false
                    }
                    Spacer()
                    Button("Connect", action: connect)
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                        .disabled(settings.org.trimmed.isEmpty || settings.project.trimmed.isEmpty || token.trimmed.isEmpty)
                }
                Text("Everything here can be changed later in Settings (⌘,).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(28)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
        }
    }

    private func connect() {
        if settings.saveToken(token) {
            token = ""
            tokenError = nil
            model.showSetup = false
        } else {
            tokenError = "Could not save the token to the Keychain."
        }
    }
}
