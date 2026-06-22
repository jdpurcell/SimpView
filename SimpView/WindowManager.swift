import AppKit
import Combine
import UniformTypeIdentifiers

@MainActor
final class WindowManager: NSObject, ObservableObject, NSWindowDelegate {
    static let shared = WindowManager()

    @Published private(set) var activeImageURL: URL?
    @Published private(set) var hasOpenWindows = false
    @Published private(set) var activeZoomToFit = false
    @Published private(set) var activeZoomToFill = false
    @Published private(set) var canNavigateToPreviousImage = false
    @Published private(set) var canNavigateToNextImage = false
    @Published private(set) var recentDocumentURLs: [URL] = []

    private var windowControllers: [ViewerWindowController] = []
    private weak var lastFocusedWindowController: ViewerWindowController?
    private weak var keyboardNavigationController: ViewerWindowController?
    private var keyboardNavigationDirection: Int?
    private var hasKeyboardNavigationRepeated = false
    private var keyboardNavigationIdentifier = UUID()
    private var keyboardNavigationTask: Task<Void, Never>?

    var hasNoWindows: Bool {
        windowControllers.isEmpty
    }

    private override init() {
        super.init()
        refreshRecentDocuments()
    }

    func stopKeyboardNavigation() {
        // Invalidate the loop without interrupting an image already decoding.
        keyboardNavigationDirection = nil
        keyboardNavigationController = nil
        hasKeyboardNavigationRepeated = false
        keyboardNavigationIdentifier = UUID()
    }

    func newWindow(opening url: URL? = nil) {
        stopKeyboardNavigation()
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
        stopKeyboardNavigation()
        let controller = mostRecentWindowController ?? makeWindow()
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Choose an image to view."

        guard let window = controller.window else {
            return
        }

        panel.beginSheetModal(for: window) { [weak controller] response in
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

    func openRecentDocument(_ url: URL) {
        stopKeyboardNavigation()
        let controller = mostRecentWindowController ?? makeWindow()
        controller.open(url)
    }

    func clearRecentDocuments() {
        NSDocumentController.shared.clearRecentDocuments(nil)
        refreshRecentDocuments()
    }

    func refreshRecentDocuments() {
        recentDocumentURLs =
            NSDocumentController.shared.recentDocumentURLs
    }

    func closeActiveWindow() {
        stopKeyboardNavigation()
        (NSApp.keyWindow ?? mostRecentWindowController?.window)?.performClose(nil)
    }

    func closeAllWindows() {
        stopKeyboardNavigation()
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

    func previousImage() {
        stopKeyboardNavigation()
        mostRecentWindowController?.previousImage()
    }

    func nextImage() {
        stopKeyboardNavigation()
        mostRecentWindowController?.nextImage()
    }

    func setZoomToFit(_ enabled: Bool) {
        mostRecentWindowController?.setZoomToFit(enabled)
        updateActiveZoomState()
    }

    func setZoomToFill(_ enabled: Bool) {
        mostRecentWindowController?.setZoomToFill(enabled)
        updateActiveZoomState()
    }

    func actualSize() {
        mostRecentWindowController?.actualSize()
        updateActiveZoomState()
    }

    func zoomIn() {
        mostRecentWindowController?.zoomIn()
        updateActiveZoomState()
    }

    func zoomOut() {
        mostRecentWindowController?.zoomOut()
        updateActiveZoomState()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        guard let controller = controller(for: notification.object as? NSWindow) else {
            return
        }
        lastFocusedWindowController = controller
        updateActiveImageURL()
        updateActiveZoomState()
        updateActiveNavigationState()
    }

    func windowDidResignKey(_ notification: Notification) {
        guard
            let controller = controller(
                for: notification.object as? NSWindow
            ),
            controller === keyboardNavigationController
        else {
            return
        }

        stopKeyboardNavigation()
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else {
            return
        }

        if controller(for: window) === keyboardNavigationController {
            stopKeyboardNavigation()
        }
        controller(for: window)?.closeImage()
        windowControllers.removeAll { $0.window === window }
        updateWindowAvailability()
        if lastFocusedWindowController?.window === window {
            lastFocusedWindowController = windowControllers.last
        }
        updateActiveImageURL()
        updateActiveZoomState()
        updateActiveNavigationState()
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
        (controller.window as? ViewerWindow)?
            .keyboardNavigationHandler = { [weak self] event in
                self?.handleKeyboardNavigationEvent(event) ?? false
            }
        controller.didOpenImage = { [weak self, weak controller] in
            guard let self, let controller else {
                return
            }
            if let url = controller.imageDocument.fileURL {
                NSDocumentController.shared.noteNewRecentDocumentURL(url)
                self.refreshRecentDocuments()
            }
            self.lastFocusedWindowController = controller
            self.updateActiveImageURL()
            self.updateActiveZoomState()
            self.updateActiveNavigationState()
        }
        controller.willOpenImage = { [weak self] in
            self?.stopKeyboardNavigation()
        }
        controller.didFailToOpenImage = { [weak self] url in
            self?.presentOpenError(for: url)
        }
        controller.zoomModeChanged = { [weak self, weak controller] in
            guard
                let self,
                controller === self.mostRecentWindowController
            else {
                return
            }
            self.updateActiveZoomState()
        }
        controller.navigationStateChanged = { [weak self, weak controller] in
            guard
                let self,
                controller === self.mostRecentWindowController
            else {
                return
            }
            self.updateActiveNavigationState()
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

    private func updateActiveZoomState() {
        activeZoomToFit = mostRecentWindowController?.isZoomToFit ?? false
        activeZoomToFill = mostRecentWindowController?.isZoomToFill ?? false
    }

    private func updateActiveNavigationState() {
        canNavigateToPreviousImage =
            mostRecentWindowController?.canNavigateToPreviousImage ?? false
        canNavigateToNextImage =
            mostRecentWindowController?.canNavigateToNextImage ?? false
    }

    private func updateWindowAvailability() {
        hasOpenWindows = !windowControllers.isEmpty
    }

    private func handleKeyboardNavigationEvent(
        _ event: NSEvent
    ) -> Bool {
        guard let direction = navigationDirection(for: event) else {
            return false
        }

        if event.type == .keyUp {
            if keyboardNavigationDirection == direction {
                stopKeyboardNavigation()
                return true
            }
            return false
        }

        let disallowedModifiers: NSEvent.ModifierFlags = [
            .command,
            .control,
            .option,
            .shift,
        ]
        guard event.modifierFlags.intersection(disallowedModifiers).isEmpty,
            let controller = controller(for: NSApp.keyWindow),
            controller.imageDocument.fileURL != nil
        else {
            return false
        }

        if event.isARepeat {
            hasKeyboardNavigationRepeated = true
            startKeyboardNavigationLoop()
            return true
        }

        stopKeyboardNavigation()
        keyboardNavigationDirection = direction
        keyboardNavigationController = controller
        if direction < 0 {
            controller.previousImage()
        } else {
            controller.nextImage()
        }
        return true
    }

    private func navigationDirection(for event: NSEvent) -> Int? {
        switch event.keyCode {
        case 123:
            -1
        case 124:
            1
        default:
            nil
        }
    }

    private func startKeyboardNavigationLoop() {
        guard keyboardNavigationTask == nil else {
            return
        }

        let identifier = keyboardNavigationIdentifier
        keyboardNavigationTask = Task { [weak self] in
            guard let self else {
                return
            }

            guard
                keyboardNavigationIdentifier == identifier,
                let controller = keyboardNavigationController
            else {
                keyboardNavigationTask = nil
                if keyboardNavigationDirection != nil,
                    keyboardNavigationController != nil,
                    hasKeyboardNavigationRepeated
                {
                    startKeyboardNavigationLoop()
                }
                return
            }

            await controller.waitForCurrentOpen()

            while
                keyboardNavigationIdentifier == identifier,
                keyboardNavigationController === controller,
                let direction = keyboardNavigationDirection
            {
                let startedAt = ProcessInfo.processInfo.systemUptime
                let didNavigate = await controller.navigateByKeyboard(
                    by: direction
                )

                guard
                    keyboardNavigationIdentifier == identifier,
                    keyboardNavigationController === controller
                else {
                    break
                }

                if !didNavigate {
                    if keyboardNavigationDirection == direction {
                        stopKeyboardNavigation()
                    }
                    continue
                }

                let elapsedMilliseconds =
                    (ProcessInfo.processInfo.systemUptime - startedAt) * 1_000
                let remainingMilliseconds =
                    Double(
                        AppPreferences.shared
                            .navigationIntervalMilliseconds
                    ) - elapsedMilliseconds

                if remainingMilliseconds > 0 {
                    try? await Task.sleep(
                        for: .milliseconds(
                            Int(remainingMilliseconds.rounded(.up))
                        )
                    )
                }
            }

            keyboardNavigationTask = nil
            if keyboardNavigationIdentifier != identifier,
                keyboardNavigationDirection != nil,
                keyboardNavigationController != nil,
                hasKeyboardNavigationRepeated
            {
                startKeyboardNavigationLoop()
            }
        }
    }

    private func presentOpenError(for url: URL) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "The image couldn’t be opened."
        alert.informativeText = "\(url.lastPathComponent) is not an image format that macOS can decode, or the file is damaged."
        alert.runModal()
    }
}
