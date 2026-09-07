import AppKit
import Combine
import SwiftUI

@MainActor
final class ViewerWindowController: NSWindowController {
    let imageDocument = ImageDocument()
    let viewportController = ImageViewportController()
    private var navigator = ImageNavigator(source: FileImageSource())
    private var decodeTask: Task<CGImage?, Error>?
    private var isSavingCopy = false
    private(set) var isStickyZoom = AppPreferences.shared.stickyZoom

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
        observeListing()
        AppPreferences.shared.$stickyZoom
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] enabled in self?.setStickyZoom(enabled) }
            .store(in: &cancellables)
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
                    await self.navigator.source.setPreloadingEnabled(enabled)
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
        if !(navigator.source is FileImageSource) { setSource(FileImageSource()) }
        openImage(.file(url.standardizedFileURL))
    }

    func openCamera(_ image: ImageReference, session: CameraSession) {
        setSource(CameraImageSource(session: session))
        openImage(image)
    }

    private func setSource(_ source: any ImageSource) {
        decodeTask?.cancel()
        openTask?.cancel()
        navigator.close()
        navigator = ImageNavigator(source: source)
        observeListing()
    }

    private func observeListing() {
        navigator.listingChanged = { [weak self] in
            self?.updateWindowTitle()
            self?.updateImagePreloads()
            self?.documentStateChanged?()
        }
    }

    var canNavigate: Bool { imageDocument.reference != nil && navigator.source.isAvailable }

    var canSaveCopy: Bool {
        canNavigate && !imageDocument.isLoading && !isSavingCopy
    }

    func saveImageCopy() {
        guard canSaveCopy, let image = imageDocument.reference,
              let window, window.attachedSheet == nil else { return }
        // Capture the source and image now, not whichever image is current when
        // the asynchronous save finishes. Saving never changes navigation state.
        let source = navigator.source
        let panel = NSSavePanel()
        panel.title = "Save a Copy"
        // A content-type restriction can canonicalize .JPG to .jpeg. This is
        // an unchanged copy, not an export format picker; keep the supplied name.
        panel.nameFieldStringValue = image.name
        panel.isExtensionHidden = false
        isSavingCopy = true
        documentStateChanged?()
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            guard response == .OK, let destination = panel.url else {
                self.isSavingCopy = false
                self.documentStateChanged?()
                return
            }
            Task { @MainActor in
                let progress = NSAlert()
                progress.messageText = "Saving a Copy…"
                progress.informativeText = image.name
                progress.addButton(withTitle: "Cancel")
                let spinner = NSProgressIndicator(frame: NSRect(x: 0, y: 0, width: 240, height: 16))
                spinner.style = .bar
                spinner.isIndeterminate = true
                spinner.startAnimation(nil)
                progress.accessoryView = spinner
                let save = Task { try await source.saveCopy(image, to: destination) }
                progress.beginSheetModal(for: window) { _ in save.cancel() }
                var failure: Error?
                do { try await save.value }
                catch is CancellationError { }
                catch { failure = error }
                if progress.window.sheetParent != nil { window.endSheet(progress.window) }
                self.isSavingCopy = false
                self.documentStateChanged?()
                if let failure {
                    let alert = NSAlert(error: failure)
                    alert.messageText = "Couldn’t Save a Copy"
                    alert.beginSheetModal(for: window, completionHandler: nil)
                }
            }
        }
    }

    private func openImage(_ url: ImageReference) {
        pendingRestoredWindowState = nil
        willOpenImage?()
        navigator.prepareForExternalOpen(url)
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
        setStickyZoom(state.stickyZoom ?? false)
        pendingRestoredWindowState = state
        guard let imagePath = state.imagePath else {
            return
        }

        let url = ImageReference.file(URL(fileURLWithPath: imagePath).standardizedFileURL)
        navigator.prepareForExternalOpen(url)
        decodeTask?.cancel()
        openTask?.cancel()
        openTask = Task { [weak self] in
            guard let self else {
                return
            }

            let didOpen = await performOpen(
                resolvingImage: { url },
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
        // Camera object identities are scoped to a connection, not restorable
        // filesystem paths. Omit these windows from saved sessions for now.
        if case .camera = imageDocument.reference { return nil }

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
            isMiniaturized: window.isMiniaturized,
            stickyZoom: isStickyZoom
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
        guard canNavigate, let currentURL = imageDocument.reference else {
            return false
        }

        return await performOpen { [navigator] in
            await navigator.navigationImage(
                from: currentURL,
                target: Self.navigationTarget(for: command)
            )
        }
    }

    func waitForCurrentOpen() async {
        await openTask?.value
    }

    func markFolderListingDirty() {
        navigator.markListingDirty()
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
        // Once navigation has resolved a target image, the document already points
        // at that provisional target. A second navigation can then intentionally
        // skip past a slow decode. Before that, while the folder listing is
        // still resolving the target, another navigation would only restart the
        // same lookup from the same old image and reset the loading grace period.
        !(imageDocument.isLoading && imageDocument.isResolvingImage)
    }

    private func navigate(_ command: ImageNavigationCommand) {
        guard canStartNavigation else {
            return
        }

        guard canNavigate, let currentURL = imageDocument.reference else {
            return
        }

        open { [navigator] in
            await navigator.navigationImage(
                from: currentURL,
                target: Self.navigationTarget(for: command)
            )
        }
    }

    private static func navigationTarget(
        for command: ImageNavigationCommand
    ) -> ImageNavigator.NavigationTarget {
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
        resolvingImage: @escaping () async -> ImageReference?
    ) {
        decodeTask?.cancel()
        openTask?.cancel()
        openTask = Task { [weak self] in
            guard !Task.isCancelled, let self else {
                return
            }

            _ = await performOpen(resolvingImage: resolvingImage)
        }
    }

    @discardableResult
    private func performOpen(
        resolvingImage: () async -> ImageReference?,
        addToRecentDocuments: Bool = true,
        showsLoadingIndicatorImmediately: Bool = false
    ) async -> Bool {
        let decodeMode = AppPreferences.shared.imageDynamicRange.decodeMode
        viewportController.captureBeforeImageChange()
        let result = await imageDocument.open(
            resolvingImage: resolvingImage,
            didResolveImage: { [weak self] url in
                guard let self else {
                    return
                }
                zoomPercentage = nil
                updateWindowTitle(revealingBubble: true)
                documentStateChanged?()
            },
            decode: { [weak self] url in
                try await self?.decodeImage(at: url, mode: decodeMode)
            },
            showsLoadingIndicatorImmediately: showsLoadingIndicatorImmediately
        )
        guard !Task.isCancelled else {
            return false
        }

        switch result {
        case .opened(let url):
            displayedImageDecodeMode = decodeMode
            navigator.didOpen(url)
            zoomPercentage = nil
            viewportController.prepareForNewImage(size: imageDocument.image?.size, preservingZoom: isStickyZoom)
            updateWindowTitle(revealingBubble: true)
            didOpenImage?(addToRecentDocuments)
            await waitForPresentation()
            updateImagePreloads()
            schedulePendingImageDecodeModeReload()
            return true
        case .failed(let url):
            displayedImageDecodeMode = decodeMode
            navigator.didOpen(url)
            zoomPercentage = nil
            viewportController.prepareForNewImage(size: nil, preservingZoom: isStickyZoom)
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
        at image: ImageReference,
        mode: ImageDecodeMode
    ) async throws -> CGImage? {
        decodeTask?.cancel()
        let source = navigator.source
        let task = Task {
            try Task.checkCancellation()
            let image = try await source.load(image, mode: mode)
            try Task.checkCancellation()
            return image
        }
        decodeTask = task
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
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
                await self.navigator.source.setDecodeMode(mode)
                guard
                    AppPreferences.shared.imageDynamicRange.decodeMode == mode
                else {
                    return
                }
                self.updateImagePreloads()
            }
            return
        }

        guard let url = imageDocument.reference else {
            Task {
                guard
                    AppPreferences.shared.imageDynamicRange.decodeMode == mode
                else {
                    return
                }
                await navigator.source.setDecodeMode(mode)
            }
            return
        }

        let viewportState = imageDocument.image == nil
            ? nil
            : viewportController.captureSessionState()

        decodeTask?.cancel()
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
        at url: ImageReference,
        mode: ImageDecodeMode,
        viewportState: ViewportSessionState?
    ) async {
        guard
            !Task.isCancelled,
            AppPreferences.shared.imageDynamicRange.decodeMode == mode
        else {
            return
        }

        await navigator.source.setDecodeMode(mode)
        guard
            !Task.isCancelled,
            AppPreferences.shared.imageDynamicRange.decodeMode == mode
        else {
            return
        }

        let result = await imageDocument.open(
            resolvingImage: { url },
            decode: { [weak self] url in
                try await self?.decodeImage(at: url, mode: mode)
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
        decodeTask?.cancel()
        openTask?.cancel()
        pendingRestoredWindowState = nil
        displayedImageDecodeMode = nil
        pendingImageDecodeMode = nil
        imageDocument.close()
        decodeTask = nil
        navigator.close()
    }

    private func updateImagePreloads() {
        guard
            AppPreferences.shared.preloadAdjacentImages,
            !isImagePreloadingSuspended,
            let currentURL = imageDocument.reference,
            !imageDocument.isLoading
        else {
            return
        }

        let adjacentImages = navigator.adjacentImages(
            to: currentURL
        )
        Task {
            await navigator.source.preload(
                current: currentURL,
                neighbors: adjacentImages,
                mode: AppPreferences.shared.imageDynamicRange.decodeMode
            )
        }
    }

    var isZoomToFit: Bool {
        viewportController.isZoomToFit
    }

    func setStickyZoom(_ enabled: Bool) {
        guard isStickyZoom != enabled else { return }
        isStickyZoom = enabled
        zoomModeChanged?()
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

    func setZoomLevel() {
        guard let window, window.attachedSheet == nil,
              imageDocument.image != nil, !imageDocument.isLoading else { return }

        let alert = NSAlert()
        alert.messageText = "Set Zoom Level"
        alert.informativeText = "Zoom level (%)"
        let okay = alert.addButton(withTitle: "OK")
        okay.keyEquivalent = "\r"
        alert.addButton(withTitle: "Cancel").keyEquivalent = "\u{1b}"

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = String(format: "%.1f", viewportController.captureSessionState().magnification * 100)
        field.setAccessibilityLabel("Zoom level (%)")
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        @MainActor func percentage() -> Double? {
            guard let value = Double(field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)),
                  value.isFinite, value > 0 else { return nil }
            return value
        }
        // Invalid/empty input cannot dismiss the prompt with OK. The viewport
        // applies its usual zoom limits when an accepted value is committed.
        let observer = NotificationCenter.default.publisher(
            for: NSControl.textDidChangeNotification, object: field
        ).sink { _ in okay.isEnabled = percentage() != nil }
        alert.beginSheetModal(for: window) { [weak self] response in
            observer.cancel()
            guard response == .alertFirstButtonReturn, let value = percentage() else { return }
            self?.viewportController.setZoomLevel(value)
        }
        alert.window.makeFirstResponder(field)
        field.selectText(nil)
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

        if imageDocument.isLoading, imageDocument.isResolvingImage {
            setWindowTitle(
                "SimpView (Refreshing folder…)",
                revealingBubble: revealingBubble
            )
            return
        }

        guard imageDocument.reference != nil else {
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
        if let position = navigator.position(of: imageDocument.reference) {
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
