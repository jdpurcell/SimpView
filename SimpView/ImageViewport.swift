import AppKit
import SwiftUI

enum ViewportZoomMode: String, Codable {
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
    var adjacentNavigationRequested: ((Int) -> Void)?

    private weak var viewport: ZoomableImageView?
    private var pendingSessionState: ViewportSessionState?
    private var imageChangeState: (viewport: ViewportSessionState, size: NSSize)?

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
        viewport.adjacentNavigationRequested = { [weak self] offset in
            self?.adjacentNavigationRequested?(offset)
        }
        if let pendingSessionState {
            viewport.restoreSessionState(pendingSessionState)
            self.pendingSessionState = nil
        } else {
            viewport.setZoomMode(zoomMode)
        }
    }

    func detach(_ viewport: ZoomableImageView) {
        if self.viewport === viewport {
            self.viewport = nil
        }
    }

    func captureBeforeImageChange() {
        // Capture before the loading placeholder can dismantle the viewport.
        // Keep this snapshot through interrupted loads and decode errors.
        if let viewport, let image = viewport.image {
            imageChangeState = (viewport.captureSessionState(), image.size)
        }
    }

    func prepareForNewImage(size: NSSize?, preservingZoom: Bool) {
        pendingSessionState = nil
        if preservingZoom, let saved = imageChangeState {
            zoomMode = saved.viewport.zoomMode
            if let size, size.width > 0, size.height > 0 {
                // Preserve an image-space displacement from center, not a
                // fraction of the old image's dimensions. The normal restore
                // path recalculates Fit/Fill and constrains the final position.
                pendingSessionState = ViewportSessionState(
                    zoomMode: zoomMode,
                    magnification: saved.viewport.magnification,
                    centerX: 0.5 + (saved.viewport.centerX - 0.5) * saved.size.width / size.width,
                    centerY: 0.5 + (saved.viewport.centerY - 0.5) * saved.size.height / size.height
                )
            }
            // Apply to the new image when SwiftUI attaches/updates its view,
            // not to the old image that may still be on screen right now.
            zoomModeChanged?()
        } else {
            imageChangeState = nil
            setZoomMode(.fit)
        }
    }

    func captureSessionState() -> ViewportSessionState {
        viewport?.captureSessionState()
            ?? pendingSessionState
            ?? ViewportSessionState(
                zoomMode: zoomMode,
                magnification: 1,
                centerX: 0.5,
                centerY: 0.5
            )
    }

    func restoreSessionState(_ state: ViewportSessionState) {
        zoomMode = state.zoomMode
        if let viewport {
            pendingSessionState = nil
            viewport.restoreSessionState(state)
        } else {
            pendingSessionState = state
        }
        zoomModeChanged?()
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

    func setZoomLevel(_ percentage: Double) {
        viewport?.zoom(to: CGFloat(percentage / 100))
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
    let dynamicRange: ImageDynamicRange

    func makeNSView(context: Context) -> ZoomableImageView {
        let viewport = ZoomableImageView()
        viewport.dynamicRange = dynamicRange
        viewport.image = image
        controller.attach(viewport)
        return viewport
    }

    func updateNSView(_ viewport: ZoomableImageView, context: Context) {
        viewport.dynamicRange = dynamicRange
        if viewport.image !== image {
            viewport.image = image
        }
        controller.attach(viewport)
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
    static var zoomStep: CGFloat {
        AppPreferences.shared.zoomStep
    }

    private struct ZoomAnchor {
        let documentPoint: NSPoint
        let windowPoint: NSPoint
    }

    var zoomChanged: ((Double?) -> Void)?
    var zoomModeChanged: ((ViewportZoomMode) -> Void)?
    var adjacentNavigationRequested: ((Int) -> Void)?
    weak var controller: ImageViewportController?

    var dynamicRange = AppPreferences.defaultImageDynamicRange {
        didSet {
            guard oldValue != dynamicRange else {
                return
            }
            imageView.preferredImageDynamicRange = dynamicRange.appKitValue
        }
    }

    var image: NSImage? {
        didSet {
            guard oldValue !== image else {
                return
            }
            cancelRecenterAnimation()
            zoomAnchor = nil
            lastPanProposedOrigin = nil
            resistedPanOrigin = nil
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
    private var lastPanProposedOrigin: NSPoint?
    private var resistedPanOrigin: NSPoint?
    private var zoomAnchor: ZoomAnchor?
    private var pendingSessionState: ViewportSessionState?
    private var recenterTask: Task<Void, Never>?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        imageView.imageAlignment = .alignCenter
        imageView.imageScaling = .scaleNone
        imageView.preferredImageDynamicRange = dynamicRange.appKitValue

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
            cancelRecenterAnimation(restoreConstraints: false)
            setManualZoomMode()
            clipView.areConstraintsEnabled = false
            zoomAnchor = nil
        }
        scrollView.userMagnified = {
            [weak self] magnification, documentPoint, windowPoint in
            guard let self else {
                return
            }
            let clampedMagnification = clampedMagnification(magnification)
            guard clampedMagnification != scrollView.magnification else {
                return
            }
            setMagnification(
                clampedMagnification,
                anchoredAt: documentPoint,
                windowPoint: windowPoint
            )
            reportZoom()
        }
        scrollView.userMagnificationEnded = { [weak self, weak scrollView] in
            self?.zoomAnchor = nil
            self?.animateRecentering(scrollView: scrollView)
        }
        scrollView.userScrollZoomBegan = { [weak self] in
            guard let self else {
                return
            }
            cancelRecenterAnimation(restoreConstraints: false)
            setManualZoomMode()
            clipView.areConstraintsEnabled = false
            zoomAnchor = nil
        }
        scrollView.userScrollZoomed = {
            [weak self] factor, documentPoint, windowPoint in
            guard let self else {
                return
            }
            let clampedMagnification = clampedMagnification(
                scrollView.magnification * factor
            )
            guard clampedMagnification != scrollView.magnification else {
                return
            }
            setMagnification(
                clampedMagnification,
                anchoredAt: documentPoint,
                windowPoint: windowPoint
            )
            reportZoom()
        }
        scrollView.userScrollZoomEnded = { [weak self, weak scrollView] in
            self?.zoomAnchor = nil
            self?.animateRecentering(scrollView: scrollView)
        }
        scrollView.userPanBegan = { [weak self] in
            guard let self else {
                return
            }
            cancelRecenterAnimation(restoreConstraints: false)
            clipView.areConstraintsEnabled = false
            lastPanProposedOrigin = clipView.bounds.origin
            resistedPanOrigin = clipView.bounds.origin
        }
        scrollView.userPanned = { [weak self] proposedOrigin in
            guard
                let self,
                let lastPanProposedOrigin,
                let resistedPanOrigin
            else {
                return
            }
            let delta = NSPoint(
                x: proposedOrigin.x - lastPanProposedOrigin.x,
                y: proposedOrigin.y - lastPanProposedOrigin.y
            )
            self.lastPanProposedOrigin = proposedOrigin
            let bounds = clipView.resistedBounds(
                from: resistedPanOrigin,
                by: delta
            )
            self.resistedPanOrigin = bounds.origin
            clipView.setBoundsOrigin(bounds.origin)
            scrollView.reflectScrolledClipView(clipView)
        }
        scrollView.userPanEnded = { [weak self, weak scrollView] in
            self?.lastPanProposedOrigin = nil
            self?.resistedPanOrigin = nil
            self?.animateRecentering(scrollView: scrollView)
        }
        scrollView.userAutomaticZoomRequested = { [weak self] mode in
            self?.setZoomMode(mode, centeringImage: true)
        }
        scrollView.userAdjacentNavigationRequested = { [weak self] offset in
            self?.adjacentNavigationRequested?(offset)
        }
        addSubview(scrollView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
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

        if
            let pendingSessionState,
            applySessionState(pendingSessionState)
        {
            self.pendingSessionState = nil
            return
        }

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
        zoom(to: 1)
    }

    func zoom(by factor: CGFloat) {
        zoom(to: scrollView.magnification * factor)
    }

    func zoom(to magnification: CGFloat) {
        cancelRecenterAnimation()
        setManualZoomMode()
        setMagnification(magnification)
    }

    func captureSessionState() -> ViewportSessionState {
        guard
            let image,
            image.size.width > 0,
            image.size.height > 0
        else {
            return pendingSessionState
                ?? ViewportSessionState(
                    zoomMode: zoomMode,
                    magnification: Double(scrollView.magnification),
                    centerX: 0.5,
                    centerY: 0.5
                )
        }

        let center = viewportCenterInDocument()
        return ViewportSessionState(
            zoomMode: zoomMode,
            magnification: Double(scrollView.magnification),
            centerX: Double(center.x / image.size.width),
            centerY: Double(center.y / image.size.height)
        )
    }

    func restoreSessionState(_ state: ViewportSessionState) {
        cancelRecenterAnimation()
        zoomMode = state.zoomMode
        shouldCenterAutomaticZoom = false
        pendingSessionState = state
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    private func setManualZoomMode() {
        guard zoomMode != .manual else {
            return
        }
        zoomMode = .manual
        zoomModeChanged?(.manual)
    }

    @discardableResult
    private func applySessionState(
        _ state: ViewportSessionState
    ) -> Bool {
        guard
            let image,
            image.size.width > 0,
            image.size.height > 0,
            scrollView.contentSize.width > 0,
            scrollView.contentSize.height > 0
        else {
            return false
        }

        let center = NSPoint(
            x: CGFloat(state.centerX) * image.size.width,
            y: CGFloat(state.centerY) * image.size.height
        )
        guard center.isFinite else {
            return false
        }

        zoomMode = state.zoomMode
        clipView.areConstraintsEnabled = true

        switch state.zoomMode {
        case .manual:
            scrollView.setMagnification(
                clampedMagnification(CGFloat(state.magnification)),
                centeredAt: center
            )
            centerViewport(at: center)
        case .fit, .fill:
            shouldCenterAutomaticZoom = false
            guard applyAutomaticZoom(centeredAt: center) else {
                return false
            }
        }

        reportZoom()
        return true
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

    private func setMagnification(
        _ magnification: CGFloat,
        anchoredAt documentPoint: NSPoint,
        windowPoint: NSPoint
    ) {
        guard documentPoint.isFinite, windowPoint.isFinite else {
            return
        }

        if zoomAnchor?.windowPoint != windowPoint {
            zoomAnchor = ZoomAnchor(
                documentPoint: documentPoint,
                windowPoint: windowPoint
            )
        }

        guard let zoomAnchor else {
            return
        }

        scrollView.setMagnification(
            magnification,
            centeredAt: zoomAnchor.documentPoint
        )

        let pointUnderAnchor = imageView.convert(
            zoomAnchor.windowPoint,
            from: nil
        )
        let correction = NSPoint(
            x: zoomAnchor.documentPoint.x - pointUnderAnchor.x,
            y: zoomAnchor.documentPoint.y - pointUnderAnchor.y
        )
        guard correction.isFinite else {
            return
        }

        clipView.setBoundsOrigin(
            NSPoint(
                x: clipView.bounds.origin.x + correction.x,
                y: clipView.bounds.origin.y + correction.y
            )
        )
        scrollView.reflectScrolledClipView(clipView)
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
        let constrainedBounds = clipView.constrainedBounds(for: proposedBounds)
        clipView.setBoundsOrigin(constrainedBounds.origin)
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
        cancelRecenterAnimation(restoreConstraints: false)

        let start = clipView.bounds.origin
        let end = clipView.constrainedBounds(for: clipView.bounds).origin

        guard
            start.isFinite,
            end.isFinite,
            start != end
        else {
            clipView.areConstraintsEnabled = true
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
                    clipView.areConstraintsEnabled = true
                    return
                }

                try? await Task.sleep(for: .milliseconds(8))
            }
        }
    }

    private func cancelRecenterAnimation(restoreConstraints: Bool = true) {
        guard recenterTask != nil else {
            return
        }

        recenterTask?.cancel()
        recenterTask = nil

        clipView.areConstraintsEnabled = false
        clipView.areConstraintsEnabled = restoreConstraints
        scrollView.reflectScrolledClipView(clipView)
    }
}

private extension ImageDynamicRange {
    var appKitValue: NSImage.DynamicRange {
        switch self {
        case .standard:
            .standard
        case .constrainedHigh:
            .constrainedHigh
        case .high:
            .high
        }
    }
}

private final class MagnifyingScrollView: NSScrollView {
    private enum ScrollMode {
        case native
        case zoom
        case navigation
        case ignored
    }

    var userMagnificationBegan: (() -> Void)?
    var userMagnified: ((CGFloat, NSPoint, NSPoint) -> Void)?
    var userMagnificationEnded: (() -> Void)?
    var userScrollZoomBegan: (() -> Void)?
    var userScrollZoomed: ((CGFloat, NSPoint, NSPoint) -> Void)?
    var userScrollZoomEnded: (() -> Void)?
    var userPanBegan: (() -> Void)?
    var userPanned: ((NSPoint) -> Void)?
    var userPanEnded: (() -> Void)?
    var userAutomaticZoomRequested: ((ViewportZoomMode) -> Void)?
    var userAdjacentNavigationRequested: ((Int) -> Void)?

    private var isMagnifying = false
    private var magnificationAtGestureStart: CGFloat?
    private var magnificationAnchor: NSPoint?
    private var magnificationAnchorInWindow: NSPoint?
    private var magnificationGestureRecognizer:
        NSMagnificationGestureRecognizer?
    fileprivate var isScrollSequenceActive = false
    private var dragStartLocation: NSPoint?
    private var dragStartOrigin: NSPoint?
    private var isScrollZooming = false
    private var scrollZoomEndTask: Task<Void, Never>?
    private var panScrollOrigin: NSPoint?
    private var panScrollEndTask: Task<Void, Never>?
    private var scrollMode: ScrollMode?

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(pannableBounds, cursor: .openHand)
    }

    override func mouseDown(with event: NSEvent) {
        guard
            event.buttonNumber == 0,
            !isInWindowDragRegion(event)
        else {
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

    private var pannableBounds: NSRect {
        guard let window else {
            return bounds
        }

        return bounds.intersection(
            convert(window.contentLayoutRect, from: nil)
        )
    }

    private func isInWindowDragRegion(_ event: NSEvent) -> Bool {
        guard
            let window,
            window.styleMask.contains(.fullSizeContentView)
        else {
            return false
        }

        return !window.contentLayoutRect.contains(event.locationInWindow)
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
            magnificationAnchorInWindow = contentView.convert(
                locationInClipView,
                to: nil
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
            magnificationAnchorInWindow = nil
            userMagnificationEnded?()

        default:
            break
        }
    }

    private func applyRecognizedMagnification(_ gestureMagnification: CGFloat) {
        guard
            let magnificationAtGestureStart,
            let magnificationAnchor,
            let magnificationAnchorInWindow
        else {
            return
        }

        userMagnified?(
            magnificationAtGestureStart * (1 + gestureMagnification),
            magnificationAnchor,
            magnificationAnchorInWindow
        )
    }

    override func scrollWheel(with event: NSEvent) {
        let isCommandScroll = event.modifierFlags.contains(.command)
        let isMomentum = !event.momentumPhase.isEmpty

        if event.phase.contains(.began) && !isMomentum {
            scrollMode = isCommandScroll ? .native : nil
        } else if !isMomentum && isCommandScroll {
            scrollMode = .native
        } else if
            !isMomentum,
            scrollMode == .native,
            !isCommandScroll
        {
            scrollMode = nil
        }

        if
            !isMomentum,
            !isCommandScroll,
            scrollMode == nil
        {
            determineScrollMode(from: event)
            guard scrollMode != nil else {
                return
            }
        }

        if scrollMode == .navigation || scrollMode == .ignored {
            if event.phase.contains(.ended)
                || event.phase.contains(.cancelled)
                || event.momentumPhase.contains(.ended)
            {
                scrollMode = nil
            }
            return
        }

        let shouldScrollNatively =
            isMomentum
                ? scrollMode == .native
                : isCommandScroll

        if shouldScrollNatively {
            handlePanScroll(event)
            return
        }

        if isScrollSequenceActive {
            let beginsNewGesture =
                event.phase.contains(.began)
                    && event.momentumPhase.isEmpty
            guard beginsNewGesture else {
                return
            }
            finishPanScroll()
        }

        if event.momentumPhase.contains(.ended) {
            finishScrollZoom()
            return
        }

        if event.phase.contains(.ended)
            || event.phase.contains(.cancelled)
        {
            finishScrollZoom()
            return
        }

        guard let documentView else {
            return
        }

        let verticalDelta = event.scrollingDeltaY
        guard verticalDelta != 0 else {
            return
        }

        scrollZoomEndTask?.cancel()

        if !isScrollZooming {
            isScrollZooming = true
            userScrollZoomBegan?()
        }

        let stepAmount = event.hasPreciseScrollingDeltas
            ? abs(verticalDelta) / 60
            : 1
        let stepFactor = pow(ZoomableImageView.zoomStep, stepAmount)
        let factor = verticalDelta > 0 ? stepFactor : 1 / stepFactor

        let locationInClipView = contentView.convert(
            event.locationInWindow,
            from: nil
        )
        let locationInDocument = documentView.convert(
            locationInClipView,
            from: contentView
        )
        userScrollZoomed?(
            factor,
            locationInDocument,
            event.locationInWindow
        )

        if event.phase.isEmpty && event.momentumPhase.isEmpty {
            scheduleScrollZoomEnd()
        }
    }

    private func determineScrollMode(from event: NSEvent) {
        guard
            event.hasPreciseScrollingDeltas,
            !event.phase.isEmpty
        else {
            scrollMode = .zoom
            return
        }

        guard
            event.scrollingDeltaX != 0
                || event.scrollingDeltaY != 0
        else {
            return
        }

        guard
            abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY)
        else {
            scrollMode = .zoom
            return
        }

        guard NSEvent.isSwipeTrackingFromScrollEventsEnabled else {
            scrollMode = .ignored
            return
        }

        scrollMode = .navigation
        trackHorizontalSwipe(event)
    }

    private func trackHorizontalSwipe(_ event: NSEvent) {
        var didNavigate = false
        var amountAtGestureEnd: CGFloat?

        event.trackSwipeEvent(
            options: [.lockDirection, .clampGestureAmount],
            dampenAmountThresholdMin: -1,
            max: 1
        ) { [weak self] amount, phase, isComplete, _ in
            if phase.contains(.ended) {
                amountAtGestureEnd = amount
            }

            guard !didNavigate else {
                return
            }

            // Ordinarily the first post-release callback reveals whether
            // AppKit is settling toward ±1 (commit) or back toward 0
            // (cancel), so navigation can begin before its invisible
            // settling animation finishes. The completion branch is a
            // fallback for a sequence that reaches its endpoint without an
            // observable intermediate callback.
            let settledAmount: CGFloat?
            if phase.isEmpty, let amountAtGestureEnd {
                if abs(amount) > abs(amountAtGestureEnd) {
                    settledAmount = amount
                } else {
                    settledAmount = nil
                }
            } else if isComplete {
                if amount >= 1 {
                    settledAmount = 1
                } else if amount <= -1 {
                    settledAmount = -1
                } else {
                    settledAmount = nil
                }
            } else {
                settledAmount = nil
            }

            guard let settledAmount else {
                return
            }

            // AppKit's swipe amount describes content movement. Page-style
            // navigation uses the opposite sign: swiping right goes forward.
            let navigationOffset = settledAmount > 0 ? -1 : 1
            didNavigate = true
            Task { @MainActor [weak self] in
                guard let self else {
                    return
                }

                scrollMode = nil
                userAdjacentNavigationRequested?(navigationOffset)
            }
        }
    }

    private func handlePanScroll(_ event: NSEvent) {
        panScrollEndTask?.cancel()
        panScrollEndTask = nil

        if !isScrollSequenceActive {
            isScrollSequenceActive = true
            panScrollOrigin = contentView.bounds.origin
            userPanBegan?()
        }

        if
            let currentOrigin = panScrollOrigin,
            magnification.isFinite,
            magnification > 0
        {
            let proposedOrigin = NSPoint(
                x: currentOrigin.x
                    - event.scrollingDeltaX / magnification,
                y: currentOrigin.y
                    + event.scrollingDeltaY / magnification
            )
            panScrollOrigin = proposedOrigin
            userPanned?(proposedOrigin)
        }

        if event.momentumPhase.contains(.ended)
            || event.phase.contains(.cancelled)
        {
            finishPanScroll()
        } else if event.phase.contains(.ended) {
            schedulePanScrollEnd()
        }
    }

    private func schedulePanScrollEnd() {
        panScrollEndTask?.cancel()
        panScrollEndTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(80))
            guard !Task.isCancelled, let self else {
                return
            }
            finishPanScroll()
        }
    }

    private func finishPanScroll() {
        panScrollEndTask?.cancel()
        panScrollEndTask = nil

        guard isScrollSequenceActive else {
            return
        }

        isScrollSequenceActive = false
        panScrollOrigin = nil
        scrollMode = nil
        userPanEnded?()
    }

    private func scheduleScrollZoomEnd() {
        guard isScrollZooming else {
            return
        }

        scrollZoomEndTask?.cancel()
        scrollZoomEndTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(333))
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

    var areConstraintsEnabled = true

    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        let finiteBounds = finiteBounds(for: proposedBounds)

        return areConstraintsEnabled
            ? constrainedBounds(for: finiteBounds)
            : finiteBounds
    }

    func constrainedBounds(for proposedBounds: NSRect) -> NSRect {
        var bounds = finiteBounds(for: proposedBounds)

        guard let documentView else {
            return bounds
        }

        bounds.origin.x = constrainedPosition(
            bounds.origin.x,
            documentMinimum: documentView.frame.minX,
            documentMaximum: documentView.frame.maxX,
            viewportLength: bounds.width
        )
        bounds.origin.y = constrainedPosition(
            bounds.origin.y,
            documentMinimum: documentView.frame.minY,
            documentMaximum: documentView.frame.maxY,
            viewportLength: bounds.height
        )

        return bounds
    }

    private func constrainedPosition(
        _ proposed: CGFloat,
        documentMinimum: CGFloat,
        documentMaximum: CGFloat,
        viewportLength: CGFloat
    ) -> CGFloat {
        let documentLength = documentMaximum - documentMinimum
        let overflow = documentLength - viewportLength

        if overflow >= 0 {
            return min(
                max(proposed, documentMinimum),
                documentMinimum + overflow
            )
        }

        return documentMinimum + overflow / 2
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

    func resistedBounds(
        from currentOrigin: NSPoint,
        by delta: NSPoint
    ) -> NSRect {
        let currentBounds = NSRect(
            origin: currentOrigin,
            size: bounds.size
        )
        let proposedBounds = NSRect(
            x: currentBounds.origin.x + delta.x,
            y: currentBounds.origin.y + delta.y,
            width: currentBounds.width,
            height: currentBounds.height
        )
        let constrainedCurrentBounds = constrainedBounds(for: currentBounds)
        let constrainedProposedBounds = constrainedBounds(for: proposedBounds)
        var resistedBounds = proposedBounds

        resistedBounds.origin.x = resistedPosition(
            current: currentBounds.origin.x,
            proposed: proposedBounds.origin.x,
            constrainedCurrent: constrainedCurrentBounds.origin.x,
            constrainedProposed: constrainedProposedBounds.origin.x
        )
        resistedBounds.origin.y = resistedPosition(
            current: currentBounds.origin.y,
            proposed: proposedBounds.origin.y,
            constrainedCurrent: constrainedCurrentBounds.origin.y,
            constrainedProposed: constrainedProposedBounds.origin.y
        )

        return resistedBounds
    }

    private func resistedPosition(
        current: CGFloat,
        proposed: CGFloat,
        constrainedCurrent: CGFloat,
        constrainedProposed: CGFloat
    ) -> CGFloat {
        let currentOvershoot = current - constrainedCurrent
        let proposedOvershoot = proposed - constrainedProposed
        let delta = proposed - current
        let isReturning =
            currentOvershoot != 0
                && delta * currentOvershoot < 0

        if isReturning {
            if proposedOvershoot == 0
                || proposedOvershoot.sign == currentOvershoot.sign
            {
                return proposed
            }
            return constrainedProposed
                + proposedOvershoot * Self.overscrollResistance
        }

        if currentOvershoot == 0 {
            return constrainedProposed
                + proposedOvershoot * Self.overscrollResistance
        }

        return current + delta * Self.overscrollResistance
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
