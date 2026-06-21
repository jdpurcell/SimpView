import AppKit

final class ViewerWindow: NSWindow {
    var keyboardNavigationHandler: ((NSEvent) -> Bool)?

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
