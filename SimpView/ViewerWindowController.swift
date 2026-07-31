import AppKit
import Combine
import SwiftUI

@MainActor
final class ViewerWindowController: NSWindowController {
    let imageDocument = ImageDocument()
    let viewportController = ImageViewportController()
    private let folderNavigator = FolderNavigator()
    private let imagePreloadCache = ImagePreloadCache()

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
    private var isImagePreloadingSuspended = false
    private var displayedImageDecodeMode: ImageDecodeMode?
    private var pendingImageDecodeMode: ImageDecodeMode?

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
        viewportController.adjacentNavigationRequested = {
            [weak self] offset in
            guard offset != 0 else {
                return
            }
            self?.navigate(offset < 0 ? .previous : .next)
        }
        folderNavigator.listingChanged = { [weak self] in
            self?.updateWindowTitle()
            self?.updateImagePreloads()
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
        AppPreferences.shared.$preloadAdjacentImages
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] enabled in
                guard let self else {
                    return
                }

                Task {
                    await self.imagePreloadCache.setEnabled(enabled)
                    if enabled {
                        self.updateImagePreloads()
                    }
                }
            }
            .store(in: &cancellables)
        AppPreferences.shared.$imageDynamicRange
            .map(\.decodeMode)
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] mode in
                self?.imageDecodeModeDidChange(to: mode)
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
                addToRecentDocuments: false,
                showsLoadingIndicatorImmediately: true
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
        navigate(.previous)
    }

    func nextImage() {
        navigate(.next)
    }

    func jumpBackImage() {
        navigate(.jumpBack)
    }

    func jumpForwardImage() {
        navigate(.jumpForward)
    }

    func firstImage() {
        navigate(.first)
    }

    func lastImage() {
        navigate(.last)
    }

    func randomImage() {
        navigate(.random)
    }

    func navigateByKeyboard(_ command: ImageNavigationCommand) async -> Bool {
        guard let currentURL = imageDocument.fileURL else {
            return false
        }

        return await performOpen { [folderNavigator] in
            await folderNavigator.navigationURL(
                from: currentURL,
                target: Self.navigationTarget(for: command)
            )
        }
    }

    func waitForCurrentOpen() async {
        await openTask?.value
    }

    func markFolderListingDirty() {
        folderNavigator.markListingDirty()
    }

    func setImagePreloadingSuspended(_ suspended: Bool) {
        guard isImagePreloadingSuspended != suspended else {
            return
        }

        isImagePreloadingSuspended = suspended
        if !suspended {
            updateImagePreloads()
        }
    }

    private var canStartNavigation: Bool {
        // Once navigation has resolved a target image, fileURL already points
        // at that provisional target. A second navigation can then intentionally
        // skip past a slow decode. Before that, while the folder listing is
        // still resolving the target, another navigation would only restart the
        // same lookup from the same old image and reset the loading grace period.
        !(imageDocument.isLoading && imageDocument.isResolvingURL)
    }

    private func navigate(_ command: ImageNavigationCommand) {
        guard canStartNavigation else {
            return
        }

        guard let currentURL = imageDocument.fileURL else {
            return
        }

        open { [folderNavigator] in
            await folderNavigator.navigationURL(
                from: currentURL,
                target: Self.navigationTarget(for: command)
            )
        }
    }

    private static func navigationTarget(
        for command: ImageNavigationCommand
    ) -> FolderNavigator.NavigationTarget {
        switch command {
        case .previous:
            return .relative(offset: -1, clampsToBounds: false)
        case .next:
            return .relative(offset: 1, clampsToBounds: false)
        case .jumpBack:
            return .relative(
                offset: -AppPreferences.shared.navigationJumpDistance,
                clampsToBounds: true
            )
        case .jumpForward:
            return .relative(
                offset: AppPreferences.shared.navigationJumpDistance,
                clampsToBounds: true
            )
        case .first:
            return .endpoint(first: true)
        case .last:
            return .endpoint(first: false)
        case .random:
            return .random
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
        addToRecentDocuments: Bool = true,
        showsLoadingIndicatorImmediately: Bool = false
    ) async -> Bool {
        let decodeMode = AppPreferences.shared.imageDynamicRange.decodeMode
        let result = await imageDocument.open(
            resolvingURL: resolvingURL,
            didResolveURL: { [weak self] url in
                guard let self else {
                    return
                }
                zoomPercentage = nil
                updateWindowTitle(revealingBubble: true)
                documentStateChanged?()
            },
            decode: { [weak self] url in
                await self?.decodeImage(at: url, mode: decodeMode)
            },
            showsLoadingIndicatorImmediately: showsLoadingIndicatorImmediately
        )
        guard !Task.isCancelled else {
            return false
        }

        switch result {
        case .opened(let url):
            displayedImageDecodeMode = decodeMode
            folderNavigator.didOpen(url)
            zoomPercentage = nil
            viewportController.prepareForNewImage()
            updateWindowTitle(revealingBubble: true)
            didOpenImage?(addToRecentDocuments)
            await waitForPresentation()
            updateImagePreloads()
            schedulePendingImageDecodeModeReload()
            return true
        case .failed(let url):
            displayedImageDecodeMode = decodeMode
            folderNavigator.didOpen(url)
            zoomPercentage = nil
            viewportController.prepareForNewImage()
            updateWindowTitle(revealingBubble: true)
            didOpenImage?(false)
            await waitForPresentation()
            updateImagePreloads()
            schedulePendingImageDecodeModeReload()
            return true
        case .unchanged:
            schedulePendingImageDecodeModeReload()
            return false
        case .superseded:
            return false
        }
    }

    private func decodeImage(
        at url: URL,
        mode: ImageDecodeMode
    ) async -> CGImage? {
        if AppPreferences.shared.preloadAdjacentImages {
            return await imagePreloadCache.image(at: url, mode: mode)
        }

        return await Task.detached(priority: .userInitiated) {
            ImageDocument.decodeImage(at: url, mode: mode)
        }.value
    }

    private func imageDecodeModeDidChange(to mode: ImageDecodeMode) {
        pendingImageDecodeMode = mode

        guard !imageDocument.isLoading else {
            return
        }

        beginPendingImageDecodeModeReload()
    }

    private func schedulePendingImageDecodeModeReload() {
        guard pendingImageDecodeMode != nil else {
            return
        }

        Task { [weak self] in
            await Task.yield()
            self?.beginPendingImageDecodeModeReload()
        }
    }

    private func beginPendingImageDecodeModeReload() {
        guard
            !imageDocument.isLoading,
            let mode = pendingImageDecodeMode
        else {
            return
        }

        pendingImageDecodeMode = nil

        guard displayedImageDecodeMode != mode else {
            Task { [weak self] in
                guard
                    let self,
                    AppPreferences.shared.imageDynamicRange.decodeMode == mode
                else {
                    return
                }
                await self.imagePreloadCache.setDecodeMode(mode)
                guard
                    AppPreferences.shared.imageDynamicRange.decodeMode == mode
                else {
                    return
                }
                self.updateImagePreloads()
            }
            return
        }

        guard let url = imageDocument.fileURL else {
            Task {
                guard
                    AppPreferences.shared.imageDynamicRange.decodeMode == mode
                else {
                    return
                }
                await imagePreloadCache.setDecodeMode(mode)
            }
            return
        }

        let viewportState = imageDocument.image == nil
            ? nil
            : viewportController.captureSessionState()

        openTask?.cancel()
        openTask = Task { [weak self] in
            await self?.reloadImage(
                at: url,
                mode: mode,
                viewportState: viewportState
            )
        }
    }

    private func reloadImage(
        at url: URL,
        mode: ImageDecodeMode,
        viewportState: ViewportSessionState?
    ) async {
        guard
            !Task.isCancelled,
            AppPreferences.shared.imageDynamicRange.decodeMode == mode
        else {
            return
        }

        await imagePreloadCache.setDecodeMode(mode)
        guard
            !Task.isCancelled,
            AppPreferences.shared.imageDynamicRange.decodeMode == mode
        else {
            return
        }

        let result = await imageDocument.open(
            resolvingURL: { url },
            decode: { [weak self] url in
                await self?.decodeImage(at: url, mode: mode)
            }
        )
        guard !Task.isCancelled else {
            return
        }

        switch result {
        case .opened:
            displayedImageDecodeMode = mode
            await waitForPresentation()
            if let viewportState {
                viewportController.restoreSessionState(viewportState)
            }
            updateWindowTitle(revealingBubble: true)
            updateImagePreloads()
            schedulePendingImageDecodeModeReload()
        case .failed:
            displayedImageDecodeMode = mode
            updateWindowTitle(revealingBubble: true)
            updateImagePreloads()
            schedulePendingImageDecodeModeReload()
        case .unchanged, .superseded:
            break
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
        displayedImageDecodeMode = nil
        pendingImageDecodeMode = nil
        imageDocument.close()
        Task {
            await self.imagePreloadCache.removeAll()
        }
    }

    private func updateImagePreloads() {
        guard
            AppPreferences.shared.preloadAdjacentImages,
            !isImagePreloadingSuspended,
            let currentURL = imageDocument.fileURL,
            !imageDocument.isLoading
        else {
            return
        }

        let adjacentImages = folderNavigator.adjacentImages(
            to: currentURL
        )
        Task {
            await imagePreloadCache.updateNeighborhood(
                currentURL: currentURL,
                adjacentImages: adjacentImages,
                mode: AppPreferences.shared.imageDynamicRange.decodeMode
            )
        }
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

        if imageDocument.isLoading, imageDocument.isResolvingURL {
            setWindowTitle(
                "SimpView (Refreshing folder…)",
                revealingBubble: revealingBubble
            )
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
