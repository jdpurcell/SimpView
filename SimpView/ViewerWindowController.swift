import AppKit
import SwiftUI

@MainActor
final class ViewerWindowController: NSWindowController {
    let imageDocument = ImageDocument()
    let viewportController = ImageViewportController()
    private let folderNavigator = FolderNavigator()

    var didOpenImage: ((_ addToRecentDocuments: Bool) -> Void)?
    var didFailToOpenImage: ((URL) -> Void)?
    var willOpenImage: (() -> Void)?
    var zoomModeChanged: (() -> Void)?

    private var openTask: Task<Void, Never>?
    private var pendingRestoredWindowState: SessionWindowState?
    private var zoomPercentage: Double?

    init() {
        super.init(window: nil)

        let contentView = ImageViewerView(
            document: imageDocument,
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

        viewportController.zoomChanged = { [weak self] percentage in
            self?.zoomPercentage = percentage
            self?.updateWindowTitle()
        }
        viewportController.zoomModeChanged = { [weak self] in
            self?.zoomModeChanged?()
        }
        folderNavigator.listingChanged = { [weak self] in
            self?.updateWindowTitle()
        }
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
                reportFailure: false,
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

        let frame = window.frame
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
            viewport: imageDocument.image == nil
                ? restoredState?.viewport
                : viewportController.captureSessionState(),
            isKeyWindow: window.isKeyWindow,
            isMiniaturized: window.isMiniaturized
        )
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
        reportFailure: Bool = true,
        addToRecentDocuments: Bool = true
    ) async -> Bool {
        let result = await imageDocument.open(
            resolvingURL: resolvingURL
        )
        guard !Task.isCancelled else {
            return false
        }

        switch result {
        case .opened(let url):
            folderNavigator.didOpen(url)
            zoomPercentage = nil
            viewportController.prepareForNewImage()
            updateWindowTitle()
            window?.representedURL = url
            didOpenImage?(addToRecentDocuments)
            return true
        case .failed(let url):
            if reportFailure {
                didFailToOpenImage?(url)
            }
            return false
        case .unchanged, .superseded:
            return false
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

    private func updateWindowTitle() {
        guard imageDocument.fileURL != nil else {
            window?.title = "SimpView"
            return
        }

        var components: [String] = []
        if let zoomPercentage {
            components.append(String(format: "%.1f%%", zoomPercentage))
        }
        if let position = folderNavigator.position(of: imageDocument.fileURL) {
            components.append("\(position.index)/\(position.count)")
        }
        components.append(imageDocument.displayName)
        window?.title = components.joined(separator: " - ")
    }
}
