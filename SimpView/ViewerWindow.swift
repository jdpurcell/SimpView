import AppKit

final class ViewerWindow: NSWindow {
    var keyboardNavigationHandler: ((NSEvent) -> Bool)?
    var windowButtonHoverChanged: ((Bool) -> Void)?

    private weak var windowButtonTrackingView: NSView?
    private var windowButtonTrackingArea: NSTrackingArea?

    func updateWindowButtonTrackingArea() {
        if
            let windowButtonTrackingView,
            let windowButtonTrackingArea
        {
            windowButtonTrackingView.removeTrackingArea(windowButtonTrackingArea)
        }

        guard
            let closeButton = standardWindowButton(.closeButton),
            let trackingView = closeButton.superview
        else {
            windowButtonTrackingView = nil
            windowButtonTrackingArea = nil
            windowButtonHoverChanged?(false)
            return
        }

        let buttons = [
            closeButton,
            standardWindowButton(.miniaturizeButton),
            standardWindowButton(.zoomButton),
        ].compactMap { $0 }
        let trackingRect = buttons
            .map { trackingView.convert($0.bounds, from: $0) }
            .reduce(NSRect.null) { $0.union($1) }
            .insetBy(dx: -6, dy: -6)
        let trackingArea = NSTrackingArea(
            rect: trackingRect,
            options: [.mouseEnteredAndExited, .activeAlways],
            owner: self,
            userInfo: nil
        )

        trackingView.addTrackingArea(trackingArea)
        windowButtonTrackingView = trackingView
        windowButtonTrackingArea = trackingArea

        let mouseLocation = trackingView.convert(
            mouseLocationOutsideOfEventStream,
            from: nil
        )
        windowButtonHoverChanged?(trackingRect.contains(mouseLocation))
    }

    override func mouseEntered(with event: NSEvent) {
        if event.trackingArea === windowButtonTrackingArea {
            windowButtonHoverChanged?(true)
        } else {
            super.mouseEntered(with: event)
        }
    }

    override func mouseExited(with event: NSEvent) {
        if event.trackingArea === windowButtonTrackingArea {
            windowButtonHoverChanged?(false)
        } else {
            super.mouseExited(with: event)
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // Handle arrows before AppKit routes them through menu key equivalents.
        if keyboardNavigationHandler?(event) == true {
            return true
        }

        return super.performKeyEquivalent(with: event)
    }

    override func sendEvent(_ event: NSEvent) {
        if
            event.type == .keyUp,
            keyboardNavigationHandler?(event) == true
        {
            return
        }

        super.sendEvent(event)
    }
}
