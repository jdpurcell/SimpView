import AppKit
import Combine
import SwiftUI

@MainActor
final class ViewerWindowController: NSWindowController {
    let imageDocument = ImageDocument()
    let viewportController = ImageViewportController()
    private let folderNavigator = FolderNavigator()

    var didOpenImage: ((_ addToRecentDocuments: Bool) -> Void)?
    var documentStateChanged: (() -> Void)?
    var willOpenImage: (() -> Void)?
    var zoomModeChanged: (() -> Void)?

    private var openTask: Task<Void, Never>?
    private var pendingRestoredWindowState: SessionWindowState?
    private var zoomPercentage: Double?
    private var cancellables: Set<AnyCancellable> = []
    private let presentation = ViewerWindowPresentation()
    private var isTitleBarHidden = false
    private var isHoveringWindowButtons = false
    private var frameBeforeFullScreen: NSRect?

    init() {
        super.init(window: nil)

        let contentView = ImageViewerView(
            document: imageDocument,
            presentation: presentation,
            viewportController: viewportController,
            openDroppedFile: { [weak self] url in
                guard let self else {
                    return false
                }

                self.open(url)
                return true
            }
        )
        let hostingController = NSHostingController(rootView: contentView)
        let window = ViewerWindow(contentViewController: hostingController)

        window.title = "SimpView"
        window.setContentSize(NSSize(width: 900, height: 650))
        window.minSize = NSSize(width: 320, height: 240)
        window.tabbingMode = .disallowed
        window.styleMask = [
            .titled,
            .closable,
            .miniaturizable,
            .resizable,
        ]
        window.isReleasedWhenClosed = false
        window.isRestorable = false

        self.window = window
        presentation.title = window.title
        window.windowButtonHoverChanged = { [weak self] hovering in
            self?.isHoveringWindowButtons = hovering
            self?.updateWindowButtonOpacity()
        }

        viewportController.zoomChanged = { [weak self] percentage in
            self?.zoomPercentage = percentage
            self?.updateWindowTitle(revealingBubble: true)
        }
        viewportController.zoomModeChanged = { [weak self] in
            self?.zoomModeChanged?()
        }
        folderNavigator.listingChanged = { [weak self] in
            self?.updateWindowTitle()
        }
        imageDocument.$isLoading
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in
                self?.documentStateChanged?()
            }
            .store(in: &cancellables)
        imageDocument.$isShowingLoadingIndicator
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] isShowing in
                if isShowing {
                    self?.updateWindowTitle(revealingBubble: true)
                }
            }
            .store(in: &cancellables)
        AppPreferences.shared.$hideTitleBar
            .removeDuplicates()
            .sink { [weak self] in
                self?.setTitleBarHidden($0)
            }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(
            for: NSWindow.didBecomeKeyNotification,
            object: window
        )
        .merge(with: NotificationCenter.default.publisher(
            for: NSWindow.didResignKeyNotification,
            object: window
        ))
        .sink { [weak self] _ in
            self?.updateWindowButtonOpacity()
        }
        .store(in: &cancellables)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func open(_ url: URL) {
        pendingRestoredWindowState = nil
        willOpenImage?()
        folderNavigator.prepareForExternalOpen(url)
        open {
            url
        }
    }

    private func setTitleBarHidden(_ hidden: Bool) {
        guard let window else {
            return
        }

        isTitleBarHidden = hidden
        let frame = window.frame
        if hidden {
            window.styleMask.insert(.fullSizeContentView)
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.standardWindowButton(.documentIconButton)?
                .isHidden = true
        } else {
            window.styleMask.remove(.fullSizeContentView)
            window.titlebarAppearsTransparent = false
            window.titleVisibility = .visible
            window.standardWindowButton(.documentIconButton)?
                .isHidden = false
        }

        // Changing the title-bar style changes the content area. Preserve the
        // outer frame and let the viewport respond to its newly available size.
        window.setFrame(frame, display: true)
        (window as? ViewerWindow)?.updateWindowButtonTrackingArea()
        updateWindowButtonOpacity()
    }

    private func updateWindowButtonOpacity() {
        guard let window else {
            return
        }

        let shouldDim = isTitleBarHidden
            && window.isKeyWindow
            && !isHoveringWindowButtons
        let opacity: CGFloat = shouldDim ? 0.5 : 1

        [
            NSWindow.ButtonType.closeButton,
            .miniaturizeButton,
            .zoomButton,
        ].forEach {
            window.standardWindowButton($0)?.alphaValue = opacity
        }
    }

    func restoreSession(_ state: SessionWindowState) {
        pendingRestoredWindowState = state
        guard let imagePath = state.imagePath else {
            return
        }

        let url = URL(fileURLWithPath: imagePath)
        folderNavigator.prepareForExternalOpen(url)
        openTask?.cancel()
        openTask = Task { [weak self] in
            guard let self else {
                return
            }

            let didOpen = await performOpen(
                resolvingURL: { url },
                addToRecentDocuments: false
            )
            guard didOpen else {
                if !Task.isCancelled {
                    pendingRestoredWindowState = nil
                }
                return
            }
            if let viewport = state.viewport {
                viewportController.restoreSessionState(viewport)
            }
            pendingRestoredWindowState = nil
        }
    }

    func captureSessionState() -> SessionWindowState? {
        guard let window else {
            return nil
        }

        let frame = frameBeforeFullScreen ?? window.frame
        let restoredState = pendingRestoredWindowState
        return SessionWindowState(
            frame: SessionRect(
                x: Double(frame.origin.x),
                y: Double(frame.origin.y),
                width: Double(frame.size.width),
                height: Double(frame.size.height)
            ),
            imagePath:
                imageDocument.fileURL?.path
                ?? restoredState?.imagePath,
            viewport: imageDocument.isLoading
                || imageDocument.image == nil
                ? restoredState?.viewport
                : viewportController.captureSessionState(),
            isMiniaturized: window.isMiniaturized
        )
    }

    var isFullScreenForSession: Bool {
        frameBeforeFullScreen != nil
            || window?.styleMask.contains(.fullScreen) == true
    }

    func windowWillEnterFullScreen() {
        guard frameBeforeFullScreen == nil else {
            return
        }
        frameBeforeFullScreen = window?.frame
    }

    func windowDidExitFullScreen() {
        frameBeforeFullScreen = nil
    }

    func windowDidFailToEnterFullScreen() {
        frameBeforeFullScreen = nil
    }

    var hasImageForSession: Bool {
        imageDocument.fileURL != nil
            || pendingRestoredWindowState?.imagePath != nil
    }

    func previousImage() {
        navigate(by: -1)
    }

    func nextImage() {
        navigate(by: 1)
    }

    func firstImage() {
        navigateToEndpoint(first: true)
    }

    func lastImage() {
        navigateToEndpoint(first: false)
    }

    func navigateByKeyboard(by offset: Int) async -> Bool {
        guard let currentURL = imageDocument.fileURL else {
            return false
        }

        return await performOpen { [folderNavigator] in
            await folderNavigator.adjacentURL(
                from: currentURL,
                offset: offset
            )
        }
    }

    func waitForCurrentOpen() async {
        await openTask?.value
    }

    private func navigate(by offset: Int) {
        guard let currentURL = imageDocument.fileURL else {
            return
        }

        open { [folderNavigator] in
            await folderNavigator.adjacentURL(
                from: currentURL,
                offset: offset
            )
        }
    }

    private func navigateToEndpoint(first: Bool) {
        guard let currentURL = imageDocument.fileURL else {
            return
        }

        open { [folderNavigator] in
            await folderNavigator.endpointURL(
                from: currentURL,
                first: first
            )
        }
    }

    private func open(
        resolvingURL: @escaping () async -> URL?
    ) {
        openTask?.cancel()
        openTask = Task { [weak self] in
            guard !Task.isCancelled, let self else {
                return
            }

            _ = await performOpen(resolvingURL: resolvingURL)
        }
    }

    @discardableResult
    private func performOpen(
        resolvingURL: () async -> URL?,
        addToRecentDocuments: Bool = true
    ) async -> Bool {
        let result = await imageDocument.open(
            resolvingURL: resolvingURL,
            didResolveURL: { [weak self] url in
                guard let self else {
                    return
                }
                zoomPercentage = nil
                updateWindowTitle(revealingBubble: true)
                window?.representedURL = url
                documentStateChanged?()
            }
        )
        guard !Task.isCancelled else {
            return false
        }

        switch result {
        case .opened(let url):
            folderNavigator.didOpen(url)
            zoomPercentage = nil
            viewportController.prepareForNewImage()
            updateWindowTitle(revealingBubble: true)
            window?.representedURL = url
            didOpenImage?(addToRecentDocuments)
            await waitForPresentation()
            return true
        case .failed(let url):
            folderNavigator.didOpen(url)
            zoomPercentage = nil
            viewportController.prepareForNewImage()
            updateWindowTitle(revealingBubble: true)
            window?.representedURL = url
            didOpenImage?(false)
            await waitForPresentation()
            return true
        case .unchanged, .superseded:
            return false
        }
    }

    private func waitForPresentation() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { [weak window] in
                window?.contentView?.layoutSubtreeIfNeeded()
                window?.displayIfNeeded()

                DispatchQueue.main.async {
                    continuation.resume()
                }
            }
        }
    }

    func closeImage() {
        openTask?.cancel()
        pendingRestoredWindowState = nil
        imageDocument.close()
    }

    var isZoomToFit: Bool {
        viewportController.isZoomToFit
    }

    var isZoomToFill: Bool {
        viewportController.isZoomToFill
    }

    func setZoomToFit(_ enabled: Bool) {
        viewportController.setZoomToFit(enabled)
    }

    func setZoomToFill(_ enabled: Bool) {
        viewportController.setZoomToFill(enabled)
    }

    func actualSize() {
        viewportController.actualSize()
    }

    func zoomIn() {
        viewportController.zoomIn()
    }

    func zoomOut() {
        viewportController.zoomOut()
    }

    private func updateWindowTitle(
        revealingBubble: Bool = false
    ) {
        // During the loading grace period, keep presenting the previous title.
        // Navigation still advances internally, but the new file is revealed
        // only if loading takes long enough to show its placeholder.
        if
            imageDocument.isLoading,
            !imageDocument.isShowingLoadingIndicator
        {
            return
        }

        guard imageDocument.fileURL != nil else {
            setWindowTitle(
                "SimpView",
                revealingBubble: revealingBubble
            )
            return
        }

        var components: [String] = []
        if let zoomPercentage {
            components.append(String(format: "%.1f%%", zoomPercentage))
        } else if imageDocument.isLoading || imageDocument.hasDecodeError {
            components.append("100.0%")
        }
        if let position = folderNavigator.position(of: imageDocument.fileURL) {
            components.append("\(position.index)/\(position.count)")
        }
        components.append(imageDocument.displayName)
        setWindowTitle(
            components.joined(separator: " - "),
            revealingBubble: revealingBubble
        )
    }

    private func setWindowTitle(
        _ title: String,
        revealingBubble: Bool
    ) {
        window?.title = title
        DispatchQueue.main.async { [weak presentation] in
            presentation?.update(
                title: title,
                revealingBubble: revealingBubble
            )
        }
    }
}

@MainActor
final class ViewerWindowPresentation: ObservableObject {
    @Published var title = "SimpView"
    @Published private(set) var isTitleBubbleVisible = false

    private var titleBubbleHideTask: Task<Void, Never>?

    func update(title: String, revealingBubble: Bool) {
        if self.title != title {
            self.title = title
        }

        guard revealingBubble else {
            return
        }

        titleBubbleHideTask?.cancel()
        isTitleBubbleVisible = true
        titleBubbleHideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, let self else {
                return
            }
            isTitleBubbleVisible = false
            titleBubbleHideTask = nil
        }
    }
}
