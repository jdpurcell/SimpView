import AppKit
import Combine
import UniformTypeIdentifiers

@MainActor
final class WindowManager: NSObject, ObservableObject, NSWindowDelegate {
    static let shared = WindowManager()

    @Published private(set) var activeImageURL: URL?
    @Published private(set) var hasOpenWindows = false

    private var windowControllers: [ViewerWindowController] = []
    private weak var lastFocusedWindowController: ViewerWindowController?

    var hasNoWindows: Bool {
        windowControllers.isEmpty
    }

    func newWindow(opening url: URL? = nil) {
        let controller = makeWindowController()
        windowControllers.append(controller)
        updateWindowAvailability()

        if let url {
            controller.open(url)
        }

        controller.showWindow(nil)
        controller.window?.center()
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func openImage() {
        let controller = mostRecentWindowController ?? makeWindow()
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Choose an image to view."

        guard let window = controller.window else {
            return
        }

        panel.beginSheetModal(for: window) { [weak self, weak controller] response in
            guard
                response == .OK,
                let url = panel.url,
                let controller
            else {
                return
            }

            controller.open(url)
        }
    }

    func closeActiveWindow() {
        (NSApp.keyWindow ?? mostRecentWindowController?.window)?.performClose(nil)
    }

    func closeAllWindows() {
        let windows = windowControllers.compactMap(\.window)
        for window in windows {
            window.performClose(nil)
        }
    }

    func showInFinder() {
        guard let url = mostRecentWindowController?.imageDocument.fileURL else {
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func windowDidBecomeKey(_ notification: Notification) {
        guard let controller = controller(for: notification.object as? NSWindow) else {
            return
        }
        lastFocusedWindowController = controller
        updateActiveImageURL()
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else {
            return
        }

        controller(for: window)?.closeImage()
        windowControllers.removeAll { $0.window === window }
        updateWindowAvailability()
        if lastFocusedWindowController?.window === window {
            lastFocusedWindowController = windowControllers.last
        }
        updateActiveImageURL()
    }

    private func makeWindow() -> ViewerWindowController {
        let controller = makeWindowController()
        windowControllers.append(controller)
        updateWindowAvailability()
        controller.showWindow(nil)
        controller.window?.center()
        controller.window?.makeKeyAndOrderFront(nil)
        return controller
    }

    private func makeWindowController() -> ViewerWindowController {
        let controller = ViewerWindowController()
        controller.window?.delegate = self
        controller.didOpenImage = { [weak self, weak controller] in
            guard let self, let controller else {
                return
            }
            self.lastFocusedWindowController = controller
            self.updateActiveImageURL()
        }
        controller.didFailToOpenImage = { [weak self] url in
            self?.presentOpenError(for: url)
        }
        return controller
    }

    private func controller(for window: NSWindow?) -> ViewerWindowController? {
        windowControllers.first { $0.window === window }
    }

    private var mostRecentWindowController: ViewerWindowController? {
        lastFocusedWindowController ?? windowControllers.last
    }

    private func updateActiveImageURL() {
        activeImageURL = mostRecentWindowController?.imageDocument.fileURL
    }

    private func updateWindowAvailability() {
        hasOpenWindows = !windowControllers.isEmpty
    }

    private func presentOpenError(for url: URL) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "The image couldn’t be opened."
        alert.informativeText = "\(url.lastPathComponent) is not an image format that macOS can decode, or the file is damaged."
        alert.runModal()
    }
}
