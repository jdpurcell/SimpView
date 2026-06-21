import AppKit
import SwiftUI

enum ViewportZoomMode {
    case manual
    case fit
    case fill
}

@MainActor
final class ImageViewportController {
    private(set) var zoomMode: ViewportZoomMode = .fit

    var isZoomToFit: Bool {
        zoomMode == .fit
    }

    var isZoomToFill: Bool {
        zoomMode == .fill
    }

    var zoomChanged: ((Double?) -> Void)?
    var zoomModeChanged: (() -> Void)?

    private weak var viewport: ZoomableImageView?

    func attach(_ viewport: ZoomableImageView) {
        self.viewport = viewport
        viewport.controller = self
        viewport.zoomChanged = { [weak self] percentage in
            self?.zoomChanged?(percentage)
        }
        viewport.zoomModeChanged = { [weak self] mode in
            guard let self else {
                return
            }
            zoomMode = mode
            zoomModeChanged?()
        }
        viewport.setZoomMode(zoomMode)
    }

    func detach(_ viewport: ZoomableImageView) {
        if self.viewport === viewport {
            self.viewport = nil
        }
    }

    func prepareForNewImage() {
        setZoomMode(.fit)
    }

    func setZoomToFit(_ enabled: Bool) {
        setZoomMode(enabled ? .fit : .manual)
    }

    func setZoomToFill(_ enabled: Bool) {
        setZoomMode(enabled ? .fill : .manual)
    }

    func actualSize() {
        viewport?.actualSize()
    }

    func zoomIn() {
        viewport?.zoom(by: ZoomableImageView.zoomStep)
    }

    func zoomOut() {
        viewport?.zoom(by: 1 / ZoomableImageView.zoomStep)
    }

    private func setZoomMode(_ mode: ViewportZoomMode) {
        zoomMode = mode
        zoomModeChanged?()
        viewport?.setZoomMode(mode)
    }
}

struct ImageViewport: NSViewRepresentable {
    let image: NSImage
    let controller: ImageViewportController

    func makeNSView(context: Context) -> ZoomableImageView {
        let viewport = ZoomableImageView()
        controller.attach(viewport)
        viewport.image = image
        return viewport
    }

    func updateNSView(_ viewport: ZoomableImageView, context: Context) {
        controller.attach(viewport)
        if viewport.image !== image {
            viewport.image = image
        }
    }

    static func dismantleNSView(
        _ viewport: ZoomableImageView,
        coordinator: Void
    ) {
        viewport.controller?.detach(viewport)
    }
}

@MainActor
final class ZoomableImageView: NSView {
    static let zoomStep: CGFloat = 1.25
    static let scrollZoomSpeed: CGFloat = 2

    var zoomChanged: ((Double?) -> Void)?
    var zoomModeChanged: ((ViewportZoomMode) -> Void)?
    weak var controller: ImageViewportController?

    var image: NSImage? {
        didSet {
            guard oldValue !== image else {
                return
            }
            cancelRecenterAnimation()
            imageView.image = image
            imageView.frame = NSRect(origin: .zero, size: image?.size ?? .zero)
            shouldCenterAutomaticZoom = true
            needsLayout = true
        }
    }

    private let scrollView = MagnifyingScrollView()
    private let clipView = CenteringClipView()
    private let imageView = NSImageView()
    private var zoomMode: ViewportZoomMode = .fit
    private var isApplyingAutomaticZoom = false
    private var shouldCenterAutomaticZoom = true
    private var recenterTask: Task<Void, Never>?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        imageView.imageAlignment = .alignCenter
        imageView.imageScaling = .scaleNone

        scrollView.allowsMagnification = true
        scrollView.minMagnification = 0.01
        scrollView.maxMagnification = 64
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = false
        scrollView.usesPredominantAxisScrolling = false
        scrollView.drawsBackground = false
        scrollView.contentView = clipView
        scrollView.documentView = imageView
        scrollView.installMagnificationGestureRecognizer()

        scrollView.userMagnificationBegan = { [weak self] in
            guard let self else {
                return
            }
            cancelRecenterAnimation(restoreCentering: false)
            setManualZoomMode()
            clipView.isCenteringEnabled = false
        }
        scrollView.userMagnified = { [weak self] magnification, point in
            guard let self else {
                return
            }
            let clampedMagnification = clampedMagnification(magnification)
            guard clampedMagnification != scrollView.magnification else {
                return
            }
            scrollView.setMagnification(
                clampedMagnification,
                centeredAt: point
            )
            reportZoom()
        }
        scrollView.userMagnificationEnded = { [weak self, weak scrollView] in
            self?.animateRecentering(scrollView: scrollView)
        }
        scrollView.userScrollZoomBegan = { [weak self] in
            guard let self else {
                return
            }
            cancelRecenterAnimation(restoreCentering: false)
            setManualZoomMode()
            clipView.isCenteringEnabled = false
        }
        scrollView.userScrollZoomed = { [weak self] factor, point in
            guard let self else {
                return
            }
            let clampedMagnification = clampedMagnification(
                scrollView.magnification * factor
            )
            guard clampedMagnification != scrollView.magnification else {
                return
            }
            scrollView.setMagnification(
                clampedMagnification,
                centeredAt: point
            )
            reportZoom()
        }
        scrollView.userScrollZoomEnded = { [weak self, weak scrollView] in
            self?.animateRecentering(scrollView: scrollView)
        }
        scrollView.userPanBegan = { [weak self] in
            guard let self else {
                return
            }
            cancelRecenterAnimation(restoreCentering: false)
            clipView.isCenteringEnabled = false
        }
        scrollView.userPanned = { [weak self] proposedOrigin in
            guard let self else {
                return
            }
            let bounds = clipView.resistedBounds(
                for: NSRect(
                    origin: proposedOrigin,
                    size: clipView.bounds.size
                )
            )
            clipView.setBoundsOrigin(bounds.origin)
            scrollView.reflectScrolledClipView(clipView)
        }
        scrollView.userPanEnded = { [weak self, weak scrollView] in
            self?.animateRecentering(scrollView: scrollView)
        }
        scrollView.userAutomaticZoomRequested = { [weak self] mode in
            self?.setZoomMode(mode, centeringImage: true)
        }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(liveScrollWillStart(_:)),
            name: NSScrollView.willStartLiveScrollNotification,
            object: scrollView
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(liveScrollDidEnd(_:)),
            name: NSScrollView.didEndLiveScrollNotification,
            object: scrollView
        )

        addSubview(scrollView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func liveScrollWillStart(_ notification: Notification) {
        cancelRecenterAnimation()
        scrollView.beginNativeScrollSequence()
    }

    @objc private func liveScrollDidEnd(_ notification: Notification) {
        scrollView.endNativeScrollSequence()
    }

    override func layout() {
        super.layout()

        let shouldPreserveViewportCenter =
            zoomMode == .manual
                || (zoomMode == .fill && !shouldCenterAutomaticZoom)
        let previousViewportCenter = shouldPreserveViewportCenter
            ? viewportCenterInDocument()
            : nil

        scrollView.frame = bounds

        if zoomMode != .manual {
            if applyAutomaticZoom(centeredAt: previousViewportCenter) {
                shouldCenterAutomaticZoom = false
            }
        } else if let previousViewportCenter {
            centerViewport(at: previousViewportCenter)
        }
    }

    func setZoomMode(
        _ mode: ViewportZoomMode,
        centeringImage: Bool = false
    ) {
        cancelRecenterAnimation()

        if centeringImage {
            shouldCenterAutomaticZoom = true
        }

        guard zoomMode != mode else {
            if mode != .manual {
                needsLayout = true
                layoutSubtreeIfNeeded()
            }
            return
        }

        zoomMode = mode
        if mode != .manual {
            shouldCenterAutomaticZoom = true
        }
        zoomModeChanged?(mode)
        if mode != .manual {
            needsLayout = true
            layoutSubtreeIfNeeded()
        }
    }

    func actualSize() {
        cancelRecenterAnimation()
        setManualZoomMode()
        setMagnification(1)
    }

    func zoom(by factor: CGFloat) {
        cancelRecenterAnimation()
        setManualZoomMode()
        setMagnification(scrollView.magnification * factor)
    }

    private func setManualZoomMode() {
        guard zoomMode != .manual else {
            return
        }
        zoomMode = .manual
        zoomModeChanged?(.manual)
    }

    private func setMagnification(_ magnification: CGFloat) {
        guard image != nil else {
            return
        }

        let viewportCenter = viewportCenterInDocument()
        scrollView.setMagnification(
            clampedMagnification(magnification),
            centeredAt: viewportCenter
        )
        reportZoom()
    }

    private func viewportCenterInDocument() -> NSPoint {
        NSPoint(
            x: clipView.bounds.midX,
            y: clipView.bounds.midY
        )
    }

    private func centerViewport(at point: NSPoint) {
        guard point.isFinite else {
            return
        }

        let proposedBounds = NSRect(
            x: point.x - clipView.bounds.width / 2,
            y: point.y - clipView.bounds.height / 2,
            width: clipView.bounds.width,
            height: clipView.bounds.height
        )
        let centeredBounds = clipView.centeredBounds(for: proposedBounds)
        clipView.setBoundsOrigin(centeredBounds.origin)
        scrollView.reflectScrolledClipView(clipView)
    }

    @discardableResult
    private func applyAutomaticZoom(centeredAt focalPoint: NSPoint?) -> Bool {
        guard
            !isApplyingAutomaticZoom,
            let image,
            image.size.width > 0,
            image.size.height > 0,
            scrollView.contentSize.width > 0,
            scrollView.contentSize.height > 0
        else {
            return false
        }

        isApplyingAutomaticZoom = true
        defer { isApplyingAutomaticZoom = false }

        let widthScale = scrollView.contentSize.width / image.size.width
        let heightScale = scrollView.contentSize.height / image.size.height
        let magnification = switch zoomMode {
        case .fit:
            min(widthScale, heightScale)
        case .fill:
            max(widthScale, heightScale)
        case .manual:
            scrollView.magnification
        }
        let zoomCenter = focalPoint ?? NSPoint(
            x: image.size.width / 2,
            y: image.size.height / 2
        )
        scrollView.setMagnification(
            clampedMagnification(magnification),
            centeredAt: zoomCenter
        )
        centerViewport(at: zoomCenter)
        reportZoom()
        return true
    }

    private func clampedMagnification(_ value: CGFloat) -> CGFloat {
        guard value.isFinite else {
            return scrollView.magnification.isFinite
                ? scrollView.magnification
                : 1
        }
        return min(
            max(value, scrollView.minMagnification),
            scrollView.maxMagnification
        )
    }

    private func reportZoom() {
        guard image != nil else {
            zoomChanged?(nil)
            return
        }
        zoomChanged?(scrollView.magnification * 100)
    }

    private func animateRecentering(scrollView: NSScrollView?) {
        cancelRecenterAnimation(restoreCentering: false)

        let centeredBounds = clipView.centeredBounds(for: clipView.bounds)
        let start = clipView.bounds.origin
        let end = centeredBounds.origin

        guard
            start.isFinite,
            end.isFinite,
            start != end
        else {
            clipView.isCenteringEnabled = true
            return
        }

        recenterTask = Task { [weak self, weak scrollView] in
            guard let self else {
                return
            }
            defer {
                if !Task.isCancelled {
                    recenterTask = nil
                }
            }

            let duration = 0.2
            let startTime = CACurrentMediaTime()

            while !Task.isCancelled {
                let elapsed = CACurrentMediaTime() - startTime
                let progress = min(elapsed / duration, 1)
                let easedProgress = sqrt(
                    max(0, 1 - pow(progress - 1, 2))
                )
                let origin = NSPoint(
                    x: start.x + (end.x - start.x) * easedProgress,
                    y: start.y + (end.y - start.y) * easedProgress
                )

                guard origin.isFinite else {
                    break
                }

                clipView.setBoundsOrigin(origin)
                scrollView?.reflectScrolledClipView(clipView)

                if progress >= 1 {
                    clipView.isCenteringEnabled = true
                    return
                }

                try? await Task.sleep(for: .milliseconds(8))
            }
        }
    }

    private func cancelRecenterAnimation(restoreCentering: Bool = true) {
        guard recenterTask != nil else {
            return
        }

        recenterTask?.cancel()
        recenterTask = nil

        clipView.isCenteringEnabled = false
        clipView.isCenteringEnabled = restoreCentering
        scrollView.reflectScrolledClipView(clipView)
    }
}

private final class MagnifyingScrollView: NSScrollView {
    private enum ScrollMode {
        case native
        case zoom
    }

    var userMagnificationBegan: (() -> Void)?
    var userMagnified: ((CGFloat, NSPoint) -> Void)?
    var userMagnificationEnded: (() -> Void)?
    var userScrollZoomBegan: (() -> Void)?
    var userScrollZoomed: ((CGFloat, NSPoint) -> Void)?
    var userScrollZoomEnded: (() -> Void)?
    var userPanBegan: (() -> Void)?
    var userPanned: ((NSPoint) -> Void)?
    var userPanEnded: (() -> Void)?
    var userAutomaticZoomRequested: ((ViewportZoomMode) -> Void)?

    private var isMagnifying = false
    private var magnificationAtGestureStart: CGFloat?
    private var magnificationAnchor: NSPoint?
    private var magnificationGestureRecognizer:
        NSMagnificationGestureRecognizer?
    fileprivate var isScrollSequenceActive = false
    private var dragStartLocation: NSPoint?
    private var dragStartOrigin: NSPoint?
    private var isScrollZooming = false
    private var scrollZoomEndTask: Task<Void, Never>?
    private var isSuppressingScrollGesture = false
    private var scrollMode: ScrollMode?
    private var isNativeMomentumActive = false

    fileprivate func beginNativeScrollSequence() {
        isScrollSequenceActive = true
    }

    fileprivate func endNativeScrollSequence() {
        guard !isNativeMomentumActive else {
            return
        }
        finishNativeScrollSequence()
    }

    private func finishNativeScrollSequence() {
        isScrollSequenceActive = false
        isSuppressingScrollGesture = false
        if scrollMode == .native {
            scrollMode = nil
        }
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .openHand)
    }

    override func mouseDown(with event: NSEvent) {
        guard event.buttonNumber == 0 else {
            super.mouseDown(with: event)
            return
        }

        userPanBegan?()
        dragStartLocation = event.locationInWindow
        dragStartOrigin = contentView.bounds.origin
        NSCursor.closedHand.push()
    }

    override func mouseDragged(with event: NSEvent) {
        guard
            let dragStartLocation,
            let dragStartOrigin
        else {
            super.mouseDragged(with: event)
            return
        }

        let location = event.locationInWindow
        let scale = magnification
        guard scale.isFinite, scale > 0 else {
            return
        }

        let origin = NSPoint(
            x: dragStartOrigin.x
                - (location.x - dragStartLocation.x) / scale,
            y: dragStartOrigin.y
                - (location.y - dragStartLocation.y) / scale
        )
        userPanned?(origin)
    }

    override func mouseUp(with event: NSEvent) {
        guard dragStartLocation != nil else {
            super.mouseUp(with: event)
            return
        }

        dragStartLocation = nil
        dragStartOrigin = nil
        NSCursor.pop()
        window?.invalidateCursorRects(for: self)
        userPanEnded?()
    }

    override func otherMouseDown(with event: NSEvent) {
        guard event.buttonNumber == 2 else {
            super.otherMouseDown(with: event)
            return
        }

        let mode: ViewportZoomMode =
            event.modifierFlags.contains(.command) ? .fill : .fit
        userAutomaticZoomRequested?(mode)
    }

    override func magnify(with event: NSEvent) {
    }

    fileprivate func installMagnificationGestureRecognizer() {
        let recognizer = NSMagnificationGestureRecognizer(
            target: self,
            action: #selector(handleMagnificationGesture(_:))
        )
        addGestureRecognizer(recognizer)
        magnificationGestureRecognizer = recognizer
    }

    @objc private func handleMagnificationGesture(
        _ recognizer: NSMagnificationGestureRecognizer
    ) {
        switch recognizer.state {
        case .began:
            guard !isScrollSequenceActive, let documentView else {
                return
            }

            isMagnifying = true
            magnificationAtGestureStart = magnification

            let locationInClipView = recognizer.location(in: contentView)
            magnificationAnchor = documentView.convert(
                locationInClipView,
                from: contentView
            )
            userMagnificationBegan?()
            applyRecognizedMagnification(recognizer.magnification)

        case .changed:
            guard isMagnifying else {
                return
            }
            applyRecognizedMagnification(recognizer.magnification)

        case .ended, .cancelled, .failed:
            guard isMagnifying else {
                return
            }
            applyRecognizedMagnification(recognizer.magnification)
            isMagnifying = false
            magnificationAtGestureStart = nil
            magnificationAnchor = nil
            userMagnificationEnded?()

        default:
            break
        }
    }

    private func applyRecognizedMagnification(_ gestureMagnification: CGFloat) {
        guard
            let magnificationAtGestureStart,
            let magnificationAnchor
        else {
            return
        }

        userMagnified?(
            magnificationAtGestureStart * (1 + gestureMagnification),
            magnificationAnchor
        )
    }

    override func scrollWheel(with event: NSEvent) {
        let isCommandScroll = event.modifierFlags.contains(.command)
        let isMomentum = !event.momentumPhase.isEmpty

        if !isMomentum {
            scrollMode = isCommandScroll ? .native : .zoom
        }

        if event.momentumPhase.contains(.began)
            || event.momentumPhase.contains(.changed)
        {
            isNativeMomentumActive = scrollMode == .native
        }

        let shouldScrollNatively =
            isMomentum
                ? scrollMode == .native
                : isCommandScroll

        if isSuppressingScrollGesture {
            if event.phase.contains(.ended)
                || event.phase.contains(.cancelled)
            {
                isSuppressingScrollGesture = false
            }
            return
        }

        if shouldScrollNatively {
            super.scrollWheel(with: event)
            if event.momentumPhase.contains(.ended) {
                isNativeMomentumActive = false
                finishNativeScrollSequence()
            }
            return
        }

        if isScrollSequenceActive {
            let beginsNewGesture =
                event.phase.contains(.began)
                && event.momentumPhase.isEmpty

            if beginsNewGesture {
                isSuppressingScrollGesture = true
                return
            }

            super.scrollWheel(with: event)
            if event.momentumPhase.contains(.ended) {
                isNativeMomentumActive = false
                finishNativeScrollSequence()
            }
            return
        }

        if event.momentumPhase.contains(.ended) {
            finishScrollZoom()
            return
        }

        if event.phase.contains(.ended)
            || event.phase.contains(.cancelled)
        {
            scheduleScrollZoomEnd()
            return
        }

        let horizontalDelta = event.scrollingDeltaX
        let verticalDelta = event.scrollingDeltaY
        guard
            verticalDelta != 0,
            abs(verticalDelta) >= abs(horizontalDelta),
            let documentView
        else {
            return
        }

        scrollZoomEndTask?.cancel()

        if !isScrollZooming {
            isScrollZooming = true
            userScrollZoomBegan?()
        }

        let normalizedDelta = event.hasPreciseScrollingDeltas
            ? verticalDelta
            : verticalDelta * 120
        let stepAmount =
            abs(normalizedDelta) / 120 * ZoomableImageView.scrollZoomSpeed
        let stepFactor = 1 + (ZoomableImageView.zoomStep - 1) * stepAmount
        let factor = normalizedDelta > 0 ? stepFactor : 1 / stepFactor

        let locationInClipView = contentView.convert(
            event.locationInWindow,
            from: nil
        )
        let locationInDocument = documentView.convert(
            locationInClipView,
            from: contentView
        )
        userScrollZoomed?(factor, locationInDocument)

        if event.phase.isEmpty && event.momentumPhase.isEmpty {
            scheduleScrollZoomEnd()
        }
    }

    private func scheduleScrollZoomEnd() {
        guard isScrollZooming else {
            return
        }

        scrollZoomEndTask?.cancel()
        scrollZoomEndTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(80))
            guard !Task.isCancelled, let self else {
                return
            }
            finishScrollZoom()
        }
    }

    private func finishScrollZoom() {
        scrollZoomEndTask?.cancel()
        scrollZoomEndTask = nil

        guard isScrollZooming else {
            return
        }

        isScrollZooming = false
        userScrollZoomEnded?()
    }
}

private final class CenteringClipView: NSClipView {
    private static let overscrollResistance: CGFloat = 0.05

    var isCenteringEnabled = true

    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        guard isCenteringEnabled else {
            return proposedBounds.isFinite
                ? proposedBounds
                : finiteBounds(
                    for: super.constrainBoundsRect(proposedBounds)
                )
        }

        return centeredBounds(for: proposedBounds)
    }

    func centeredBounds(for proposedBounds: NSRect) -> NSRect {
        var bounds = super.constrainBoundsRect(proposedBounds)

        guard let documentView else {
            return finiteBounds(for: bounds)
        }

        if documentView.frame.width < bounds.width {
            bounds.origin.x = (documentView.frame.width - bounds.width) / 2
        }
        if documentView.frame.height < bounds.height {
            bounds.origin.y = (documentView.frame.height - bounds.height) / 2
        }

        return finiteBounds(for: bounds)
    }

    private func finiteBounds(for proposedBounds: NSRect) -> NSRect {
        var result = proposedBounds

        if !result.origin.x.isFinite {
            result.origin.x = bounds.origin.x
        }
        if !result.origin.y.isFinite {
            result.origin.y = bounds.origin.y
        }
        if !result.size.width.isFinite || result.size.width < 0 {
            result.size.width = bounds.width
        }
        if !result.size.height.isFinite || result.size.height < 0 {
            result.size.height = bounds.height
        }

        return result
    }

    func resistedBounds(for proposedBounds: NSRect) -> NSRect {
        let constrainedBounds = centeredBounds(for: proposedBounds)
        var bounds = proposedBounds

        bounds.origin.x = resistedPosition(
            proposedBounds.origin.x,
            constrained: constrainedBounds.origin.x
        )
        bounds.origin.y = resistedPosition(
            proposedBounds.origin.y,
            constrained: constrainedBounds.origin.y
        )

        return bounds
    }

    private func resistedPosition(
        _ proposed: CGFloat,
        constrained: CGFloat
    ) -> CGFloat {
        constrained + (proposed - constrained) * Self.overscrollResistance
    }
}

private extension NSPoint {
    var isFinite: Bool {
        x.isFinite && y.isFinite
    }
}

private extension NSRect {
    var isFinite: Bool {
        origin.isFinite
            && size.width.isFinite
            && size.height.isFinite
    }
}
