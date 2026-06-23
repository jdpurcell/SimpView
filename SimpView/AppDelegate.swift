import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var isSystemTermination = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = false
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(workspaceWillPowerOff(_:)),
            name: NSWorkspace.willPowerOffNotification,
            object: nil
        )
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let restoredSession = WindowManager.shared.restoreSavedSession()
        DispatchQueue.main.async {
            if !restoredSession, WindowManager.shared.hasNoWindows {
                WindowManager.shared.newWindow()
            }
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        AppPreferences.shared.refresh()
        WindowManager.shared.refreshRecentDocuments()
    }

    func applicationWillResignActive(_ notification: Notification) {
        WindowManager.shared.stopKeyboardNavigation()
    }

    func applicationShouldTerminate(
        _ sender: NSApplication
    ) -> NSApplication.TerminateReply {
        if isSystemTermination {
            try? WindowManager.shared.saveSession()
            return .terminateNow
        }

        guard WindowManager.shared.hasImagesForSession else {
            return clearSessionForTermination()
        }

        switch AppPreferences.shared.sessionQuitBehavior {
        case .followSystemSetting:
            return systemKeepsWindowsWhenQuitting
                ? saveSessionForTermination()
                : clearSessionForTermination()
        case .askWhenQuitting:
            return presentSessionQuitAlert()
        }
    }

    private func presentSessionQuitAlert()
        -> NSApplication.TerminateReply
    {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.informativeText =
            "Would you like to remember your opened images and re-open them at next launch?"
        alert.addButton(withTitle: "Remember")
        alert.addButton(withTitle: "End Session")
        alert.addButton(withTitle: "Cancel")

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            return saveSessionForTermination()
        case .alertSecondButtonReturn:
            return clearSessionForTermination()
        default:
            return .terminateCancel
        }
    }

    private var systemKeepsWindowsWhenQuitting: Bool {
        let key = "NSQuitAlwaysKeepsWindows"
        return (UserDefaults.standard.object(forKey: key) as? NSNumber)?
            .boolValue ?? true
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            WindowManager.shared.newWindow(opening: url)
        }
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        if !flag {
            WindowManager.shared.newWindow()
        }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(
        _ sender: NSApplication
    ) -> Bool {
        AppPreferences.shared.quitOnLastWindowClosed
    }

    @objc
    private func workspaceWillPowerOff(_ notification: Notification) {
        isSystemTermination = true
        try? WindowManager.shared.saveSession()
    }

    private func saveSessionForTermination()
        -> NSApplication.TerminateReply
    {
        do {
            try WindowManager.shared.saveSession()
            return .terminateNow
        } catch {
            presentSessionError(
                message: "The session couldn’t be remembered.",
                error: error
            )
            return .terminateCancel
        }
    }

    private func clearSessionForTermination()
        -> NSApplication.TerminateReply
    {
        do {
            try WindowManager.shared.clearSavedSession()
            return .terminateNow
        } catch {
            presentSessionError(
                message: "The saved session couldn’t be cleared.",
                error: error
            )
            return .terminateCancel
        }
    }

    private func presentSessionError(message: String, error: Error) {
        let alert = NSAlert(error: error)
        alert.alertStyle = .warning
        alert.messageText = message
        alert.runModal()
    }
}
