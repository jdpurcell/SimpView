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
    @Published private(set) var activeCanZoom = false
    @Published private(set) var recentDocumentURLs: [URL] = []

    private var windowControllers: [ViewerWindowController] = []
    private weak var lastFocusedWindowController: ViewerWindowController?
    private weak var keyboardNavigationController: ViewerWindowController?
    private var keyboardNavigationDirection: Int?
    private var hasKeyboardNavigationRepeated = false
    private var keyboardNavigationIdentifier = UUID()
    private var keyboardNavigationTask: Task<Void, Never>?
    private var recentDocumentRefreshGeneration = 0
    private var recentDocumentRefreshTask: Task<Void, Never>?

    var hasNoWindows: Bool {
        windowControllers.isEmpty
    }

    var hasImagesForSession: Bool {
        windowControllers.contains { $0.hasImageForSession }
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

    func markFolderListingsDirty() {
        for controller in windowControllers {
            controller.markFolderListingDirty()
        }
    }

    func saveSession() throws {
        let state = SessionState(
            formatVersion: SessionState.currentFormatVersion,
            windows: controllersInSessionOrder.compactMap {
                $0.captureSessionState()
            }
        )
        try SessionStateStore.save(state)
    }

    func clearSavedSession() throws {
        try SessionStateStore.clear()
    }

    @discardableResult
    func restoreSavedSession() -> Bool {
        guard case .loaded(let state) = SessionStateStore.load() else {
            return false
        }

        stopKeyboardNavigation()
        var restoredControllers: [ViewerWindowController] = []

        for windowState in state.windows {
            let controller = makeWindowController()
            guard let window = controller.window else {
                continue
            }

            windowControllers.append(controller)
            controller.setImagePreloadingSuspended(true)
            window.setFrame(
                restoredFrame(for: windowState.frame, window: window),
                display: false
            )
            controller.showWindow(nil)
            controller.restoreSession(windowState)

            if windowState.isMiniaturized {
                window.miniaturize(nil)
            } else {
                window.orderFront(nil)
            }

            restoredControllers.append(controller)
        }

        updateWindowAvailability()

        let keyController =
            restoredControllers.last {
                $0.window?.isMiniaturized == false
            }
            ?? restoredControllers.last
        lastFocusedWindowController = keyController

        if let window = keyController?.window, !window.isMiniaturized {
            window.makeKeyAndOrderFront(nil)
        }

        updateActiveImageURL()
        updateActiveZoomState()

        Task {
            for controller in restoredControllers {
                await controller.waitForCurrentOpen()
            }
            for controller in restoredControllers {
                controller.setImagePreloadingSuspended(false)
            }
        }

        return true
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
        recentDocumentURLs = []
        refreshRecentDocuments()
    }

    func refreshRecentDocuments() {
        recentDocumentRefreshGeneration += 1
        let generation = recentDocumentRefreshGeneration
        recentDocumentRefreshTask?.cancel()
        recentDocumentRefreshTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard
                !Task.isCancelled,
                let self
            else {
                return
            }

            let urls = NSDocumentController.shared.recentDocumentURLs

            guard
                !Task.isCancelled,
                recentDocumentRefreshGeneration == generation
            else {
                return
            }

            if recentDocumentURLs != urls {
                recentDocumentURLs = urls
            }
            recentDocumentRefreshTask = nil
        }
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

    func firstImage() {
        stopKeyboardNavigation()
        mostRecentWindowController?.firstImage()
    }

    func lastImage() {
        stopKeyboardNavigation()
        mostRecentWindowController?.lastImage()
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
    }

    func windowWillEnterFullScreen(_ notification: Notification) {
        controller(for: notification.object as? NSWindow)?
            .windowWillEnterFullScreen()
    }

    func windowDidFailToEnterFullScreen(_ window: NSWindow) {
        controller(for: window)?.windowDidFailToEnterFullScreen()
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        controller(for: notification.object as? NSWindow)?
            .windowDidExitFullScreen()
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
        controller.didOpenImage = {
            [weak self, weak controller] addToRecentDocuments in
            guard let self, let controller else {
                return
            }
            if
                addToRecentDocuments,
                let url = controller.imageDocument.fileURL
            {
                NSDocumentController.shared.noteNewRecentDocumentURL(url)
                self.refreshRecentDocuments()
            }
            self.lastFocusedWindowController = controller
            self.updateActiveImageURL()
            self.updateActiveZoomState()
        }
        controller.willOpenImage = { [weak self] in
            self?.stopKeyboardNavigation()
        }
        controller.documentStateChanged = { [weak self, weak controller] in
            guard
                let self,
                controller === self.mostRecentWindowController
            else {
                return
            }
            self.updateActiveImageURL()
            self.updateActiveZoomState()
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
        return controller
    }

    private func controller(for window: NSWindow?) -> ViewerWindowController? {
        windowControllers.first { $0.window === window }
    }

    private var mostRecentWindowController: ViewerWindowController? {
        lastFocusedWindowController ?? windowControllers.last
    }

    private var controllersInSessionOrder: [ViewerWindowController] {
        var seen: Set<ObjectIdentifier> = []
        let regularFrontToBack = NSApp.orderedWindows.compactMap {
            controller(for: $0)
        }.filter {
            guard
                $0.window?.isMiniaturized == false,
                !$0.isFullScreenForSession
            else {
                return false
            }
            return seen.insert(ObjectIdentifier($0)).inserted
        }
        let remainingRegularControllers = windowControllers.filter {
            guard !$0.isFullScreenForSession else {
                return false
            }
            return seen.insert(ObjectIdentifier($0)).inserted
        }
        let fullScreenControllers = windowControllers.filter {
            $0.isFullScreenForSession
        }

        // Regular visible windows are stored bottom to top so orderFront(_:)
        // recreates their stack. Full-screen windows are stored last and
        // restored as ordinary topmost windows using their pre-full-screen
        // frames.
        return remainingRegularControllers
            + regularFrontToBack.reversed()
            + fullScreenControllers
    }

    private func updateActiveImageURL() {
        activeImageURL = mostRecentWindowController?.imageDocument.fileURL
    }

    private func updateActiveZoomState() {
        let controller = mostRecentWindowController
        activeCanZoom =
            controller?.imageDocument.image != nil
            && controller?.imageDocument.isLoading == false
        activeZoomToFit = activeCanZoom
            ? controller?.isZoomToFit ?? false
            : false
        activeZoomToFill = activeCanZoom
            ? controller?.isZoomToFill ?? false
            : false
    }

    private func updateWindowAvailability() {
        hasOpenWindows = !windowControllers.isEmpty
    }

    private func restoredFrame(
        for savedFrame: SessionRect,
        window: NSWindow
    ) -> NSRect {
        let frame = NSRect(
            x: savedFrame.x,
            y: savedFrame.y,
            width: savedFrame.width,
            height: savedFrame.height
        )
        guard
            frame.origin.x.isFinite,
            frame.origin.y.isFinite,
            frame.size.width.isFinite,
            frame.size.height.isFinite,
            frame.size.width > 0,
            frame.size.height > 0
        else {
            return window.frame
        }

        let bestScreen = NSScreen.screens.max {
            intersectionArea(of: frame, with: $0.frame)
                < intersectionArea(of: frame, with: $1.frame)
        }
        let screen =
            bestScreen.flatMap {
                intersectionArea(of: frame, with: $0.frame) > 0
                    ? $0
                    : nil
            }
            ?? NSScreen.main
        return window.constrainFrameRect(frame, to: screen)
    }

    private func intersectionArea(
        of frame: NSRect,
        with screenFrame: NSRect
    ) -> CGFloat {
        let intersection = frame.intersection(screenFrame)
        guard !intersection.isNull else {
            return 0
        }
        return intersection.width * intersection.height
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

                try? await Task.sleep(
                    for: .milliseconds(
                        AppPreferences.shared
                            .navigationIntervalMilliseconds
                    )
                )
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

}
