import AppKit
import SwiftUI

@main
struct ADODeskApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var settings = SettingsStore.shared
    @StateObject private var cli = CLIRunner()
    @StateObject private var model = AppModel()

    var body: some Scene {
        // One window: the menu commands below drive this window's state.
        Window("ADO Desk", id: "main") {
            ContentView()
                .environmentObject(settings)
                .environmentObject(cli)
                .environmentObject(model)
                .frame(minWidth: 1040, minHeight: 680)
        }
        .commands {
            SidebarCommands()
            AppCommands(model: model)
        }

        Settings {
            SettingsView()
                .environmentObject(settings)
                .environmentObject(cli)
        }
    }
}

struct AppCommands: Commands {
    @ObservedObject var model: AppModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Work Item…") { model.showNewItem = true }
                .keyboardShortcut("n")
        }
        CommandMenu("Go") {
            Button("Command Palette…") { model.showPalette = true }
                .keyboardShortcut("k")
            Divider()
            ForEach(Array(Pane.allCases.enumerated()), id: \.element) { index, pane in
                Button(pane.title) { model.pane = pane }
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")))
            }
            Divider()
            Button(model.showActivity ? "Hide Activity" : "Show Activity") { model.showActivity.toggle() }
                .keyboardShortcut("y", modifiers: [.command, .shift])
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when launched via `swift run`, where there is no app bundle.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
