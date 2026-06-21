import AppKit
import SwiftUI

@MainActor
final class ViewerWindowController: NSWindowController {
    let imageDocument = ImageDocument()

    var didOpenImage: (() -> Void)?
    var didFailToOpenImage: ((URL) -> Void)?

    private var openTask: Task<Void, Never>?

    init() {
        super.init(window: nil)

        let contentView = ImageViewerView(document: imageDocument) { [weak self] url in
            guard let self else {
                return false
            }

            self.open(url)
            return true
        }
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
                window?.title = imageDocument.displayName
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
}
