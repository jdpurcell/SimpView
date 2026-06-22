import SwiftUI

@main
struct SimpViewApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            SettingsView()
        }
        .commands {
            SimpViewCommands()
        }
    }
}
