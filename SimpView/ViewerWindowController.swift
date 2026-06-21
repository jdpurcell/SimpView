import AppKit
import SwiftUI

@MainActor
final class ViewerWindowController: NSWindowController {
    let imageDocument = ImageDocument()
    let viewportController = ImageViewportController()
    private let folderNavigator = FolderNavigator()

    var didOpenImage: (() -> Void)?
    var didFailToOpenImage: ((URL) -> Void)?
    var willOpenImage: (() -> Void)?
    var zoomModeChanged: (() -> Void)?
    var navigationStateChanged: (() -> Void)?

    private var openTask: Task<Void, Never>?
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
            self?.navigationStateChanged?()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func open(_ url: URL) {
        willOpenImage?()
        folderNavigator.prepareForExternalOpen(url)
        open {
            url
        }
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

    var canNavigateToPreviousImage: Bool {
        folderNavigator.canNavigate(from: imageDocument.fileURL, offset: -1)
    }

    var canNavigateToNextImage: Bool {
        folderNavigator.canNavigate(from: imageDocument.fileURL, offset: 1)
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
        resolvingURL: () async -> URL?
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
            didOpenImage?()
            navigationStateChanged?()
            return true
        case .failed(let url):
            didFailToOpenImage?(url)
            return false
        case .unchanged, .superseded:
            return false
        }
    }

    func closeImage() {
        openTask?.cancel()
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
