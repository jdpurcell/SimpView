import SwiftUI

@main
struct SimpViewApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
        .commands {
            SimpViewCommands()
        }
    }
}
