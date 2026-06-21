import AppKit
import SwiftUI

@MainActor
final class ViewerWindowController: NSWindowController {
    let imageDocument = ImageDocument()
    let viewportController = ImageViewportController()

    var didOpenImage: (() -> Void)?
    var didFailToOpenImage: ((URL) -> Void)?
    var zoomToFitChanged: (() -> Void)?

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
        let window = NSWindow(contentViewController: hostingController)

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
        viewportController.zoomToFitChanged = { [weak self] _ in
            self?.zoomToFitChanged?()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func open(_ url: URL) {
        openTask?.cancel()
        openTask = Task { [weak self] in
            guard !Task.isCancelled, let self else {
                return
            }

            let result = await imageDocument.open(url)
            guard !Task.isCancelled else {
                return
            }

            switch result {
            case .opened:
                zoomPercentage = nil
                viewportController.prepareForNewImage()
                updateWindowTitle()
                window?.representedURL = url
                didOpenImage?()
            case .failed:
                didFailToOpenImage?(url)
            case .superseded:
                break
            }
        }
    }

    func closeImage() {
        openTask?.cancel()
        imageDocument.close()
    }

    var isZoomToFit: Bool {
        viewportController.isZoomToFit
    }

    func setZoomToFit(_ enabled: Bool) {
        viewportController.setZoomToFit(enabled)
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

        if let zoomPercentage {
            window?.title = String(
                format: "%.1f%% - %@",
                zoomPercentage,
                imageDocument.displayName
            )
        } else {
            window?.title = imageDocument.displayName
        }
    }
}
