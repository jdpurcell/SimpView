import AppKit
import SwiftUI

@MainActor
final class ImageViewportController {
    private(set) var isZoomToFit = true

    var zoomChanged: ((Double?) -> Void)?
    var zoomToFitChanged: ((Bool) -> Void)?

    private weak var viewport: ZoomableImageView?

    func attach(_ viewport: ZoomableImageView) {
        self.viewport = viewport
        viewport.controller = self
        viewport.zoomChanged = { [weak self] percentage in
            self?.zoomChanged?(percentage)
        }
        viewport.zoomToFitChanged = { [weak self] enabled in
            guard let self else {
                return
            }
            isZoomToFit = enabled
            zoomToFitChanged?(enabled)
        }
        viewport.setZoomToFit(isZoomToFit)
    }

    func detach(_ viewport: ZoomableImageView) {
        if self.viewport === viewport {
            self.viewport = nil
        }
    }

    func prepareForNewImage() {
        isZoomToFit = true
        zoomToFitChanged?(true)
        viewport?.setZoomToFit(true)
    }

    func setZoomToFit(_ enabled: Bool) {
        isZoomToFit = enabled
        zoomToFitChanged?(enabled)
        viewport?.setZoomToFit(enabled)
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

    var zoomChanged: ((Double?) -> Void)?
    var zoomToFitChanged: ((Bool) -> Void)?
    weak var controller: ImageViewportController?

    var image: NSImage? {
        didSet {
            guard oldValue !== image else {
                return
            }
            cancelRecenterAnimation()
            imageView.image = image
            imageView.frame = NSRect(origin: .zero, size: image?.size ?? .zero)
            needsLayout = true
        }
    }

    private let scrollView = MagnifyingScrollView()
    private let clipView = CenteringClipView()
    private let imageView = NSImageView()
    private var isZoomToFit = true
    private var isApplyingFit = false
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
        scrollView.drawsBackground = false
        scrollView.contentView = clipView
        scrollView.documentView = imageView

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
            scrollView.setMagnification(
                clampedMagnification(magnification),
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
            scrollView.setMagnification(
                clampedMagnification(scrollView.magnification * factor),
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
        scrollView.isScrollSequenceActive = true
    }

    @objc private func liveScrollDidEnd(_ notification: Notification) {
        scrollView.isScrollSequenceActive = false
    }

    override func layout() {
        super.layout()
        scrollView.frame = bounds
        if isZoomToFit {
            applyZoomToFit()
        }
    }

    func setZoomToFit(_ enabled: Bool) {
        cancelRecenterAnimation()

        guard isZoomToFit != enabled else {
            if enabled {
                needsLayout = true
            }
            return
        }

        isZoomToFit = enabled
        zoomToFitChanged?(enabled)
        if enabled {
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
        guard isZoomToFit else {
            return
        }
        isZoomToFit = false
        zoomToFitChanged?(false)
    }

    private func setMagnification(_ magnification: CGFloat) {
        guard image != nil else {
            return
        }

        let viewportCenter = NSPoint(
            x: scrollView.contentView.bounds.midX,
            y: scrollView.contentView.bounds.midY
        )
        scrollView.setMagnification(
            clampedMagnification(magnification),
            centeredAt: viewportCenter
        )
        reportZoom()
    }

    private func applyZoomToFit() {
        guard
            !isApplyingFit,
            let image,
            image.size.width > 0,
            image.size.height > 0,
            scrollView.contentSize.width > 0,
            scrollView.contentSize.height > 0
        else {
            return
        }

        isApplyingFit = true
        defer { isApplyingFit = false }

        let magnification = min(
            scrollView.contentSize.width / image.size.width,
            scrollView.contentSize.height / image.size.height
        )
        let imageCenter = NSPoint(
            x: image.size.width / 2,
            y: image.size.height / 2
        )
        scrollView.setMagnification(
            clampedMagnification(magnification),
            centeredAt: imageCenter
        )
        reportZoom()
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
    var userMagnificationBegan: (() -> Void)?
    var userMagnified: ((CGFloat, NSPoint) -> Void)?
    var userMagnificationEnded: (() -> Void)?
    var userScrollZoomBegan: (() -> Void)?
    var userScrollZoomed: ((CGFloat, NSPoint) -> Void)?
    var userScrollZoomEnded: (() -> Void)?
    var userPanBegan: (() -> Void)?
    var userPanned: ((NSPoint) -> Void)?
    var userPanEnded: (() -> Void)?

    private var isMagnifying = false
    fileprivate var isScrollSequenceActive = false
    private var dragStartLocation: NSPoint?
    private var dragStartOrigin: NSPoint?
    private var isScrollZooming = false
    private var scrollZoomEndTask: Task<Void, Never>?

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

    override func magnify(with event: NSEvent) {
        guard !isScrollSequenceActive else {
            return
        }

        if !isMagnifying {
            isMagnifying = true
            userMagnificationBegan?()
        }

        guard let documentView else {
            return
        }

        let locationInClipView = contentView.convert(
            event.locationInWindow,
            from: nil
        )
        let locationInDocument = documentView.convert(
            locationInClipView,
            from: contentView
        )
        userMagnified?(
            magnification + event.magnification,
            locationInDocument
        )

        if event.phase == .ended || event.phase == .cancelled {
            isMagnifying = false
            userMagnificationEnded?()
        }
    }

    override func scrollWheel(with event: NSEvent) {
        if event.modifierFlags.contains(.command) {
            super.scrollWheel(with: event)
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

        if !isScrollZooming {
            isScrollZooming = true
            userScrollZoomBegan?()
        }

        let normalizedDelta = event.hasPreciseScrollingDeltas
            ? verticalDelta
            : verticalDelta * 120
        let speedAdjustment = 2.0
        let stepAmount = abs(normalizedDelta) / 120 * speedAdjustment
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

        scrollZoomEndTask?.cancel()
        scrollZoomEndTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(80))
            guard !Task.isCancelled, let self else {
                return
            }
            isScrollZooming = false
            userScrollZoomEnded?()
        }
    }

}

private final class CenteringClipView: NSClipView {
    private static let overscrollResistance: CGFloat = 0.05

    var isCenteringEnabled = true

    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        guard isCenteringEnabled else {
            return proposedBounds
        }

        return centeredBounds(for: proposedBounds)
    }

    func centeredBounds(for proposedBounds: NSRect) -> NSRect {
        var bounds = super.constrainBoundsRect(proposedBounds)

        guard let documentView else {
            return bounds
        }

        if documentView.frame.width < bounds.width {
            bounds.origin.x = (documentView.frame.width - bounds.width) / 2
        }
        if documentView.frame.height < bounds.height {
            bounds.origin.y = (documentView.frame.height - bounds.height) / 2
        }

        return bounds
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
