import AppKit
import SwiftUI

@MainActor
final class ViewerWindowController: NSWindowController {
    let imageDocument = ImageDocument()

    var didOpenImage: (() -> Void)?
    var didFailToOpenImage: ((URL) -> Void)?

    init() {
        super.init(window: nil)

        let contentView = ImageViewerView(document: imageDocument) { [weak self] url in
            guard let self else {
                return false
            }

            if self.open(url) {
                return true
            }

            self.didFailToOpenImage?(url)
            return false
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

    @discardableResult
    func open(_ url: URL) -> Bool {
        guard imageDocument.open(url) else {
            return false
        }

        window?.title = imageDocument.displayName
        window?.representedURL = url
        didOpenImage?()
        return true
    }
}
