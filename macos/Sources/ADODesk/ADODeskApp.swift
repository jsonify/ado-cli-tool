import AppKit
import SwiftUI

@main
struct ADODeskApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var settings = SettingsStore.shared
    @StateObject private var cli = CLIRunner()

    var body: some Scene {
        WindowGroup("ADO Desk") {
            ContentView()
                .environmentObject(settings)
                .environmentObject(cli)
                .frame(minWidth: 960, minHeight: 640)
        }
        .commands {
            SidebarCommands()
        }

        Settings {
            SettingsView()
                .environmentObject(settings)
                .environmentObject(cli)
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
