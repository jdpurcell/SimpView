import Combine
import Foundation

enum ImageSortField: String, Hashable, Sendable {
    case name
    case modificationDate
}

enum SortDirection: String, Hashable, Sendable {
    case ascending
    case descending
}

enum ImageDynamicRange: String, Hashable, Sendable {
    case standard
    case constrainedHigh
    case high

    var decodeMode: ImageDecodeMode {
        self == .standard ? .standard : .hdr
    }
}

enum ImageDecodeMode: Hashable, Sendable {
    case standard
    case hdr
}

enum SessionQuitBehavior: String, Hashable, Sendable {
    case followSystemSetting
    case askWhenQuitting
}

@MainActor
final class AppPreferences: NSObject, ObservableObject {
    static let shared = AppPreferences()

    @Published private(set) var zoomStepPercent: Int
    @Published private(set) var imageSortField: ImageSortField
    @Published private(set) var imageSortDirection: SortDirection
    @Published private(set) var imageDynamicRange: ImageDynamicRange
    @Published private(set) var navigationIntervalMilliseconds: Int
    @Published private(set) var navigationJumpDistance: Int
    @Published private(set) var preloadAdjacentImages: Bool
    @Published private(set) var sessionQuitBehavior: SessionQuitBehavior
    @Published private(set) var quitOnLastWindowClosed: Bool
    @Published private(set) var hideTitleBar: Bool

    var zoomStep: CGFloat {
        1 + CGFloat(zoomStepPercent) / 100
    }

    private enum Key {
        static let zoomStep = "zoomStep"
        static let imageSortField = "imageSortField"
        static let imageSortDirection = "imageSortDirection"
        static let imageDynamicRange = "imageDynamicRange"
        static let navigationInterval = "navigationInterval"
        static let navigationJumpDistance = "navigationJumpDistance"
        static let preloadAdjacentImages = "preloadAdjacentImages"
        static let sessionQuitBehavior = "sessionQuitBehavior"
        static let quitOnLastWindowClosed = "quitOnLastWindowClosed"
        static let hideTitleBar = "hideTitleBar"
    }

    nonisolated static let defaultZoomStepPercent = 25
    nonisolated static let zoomStepPercentRange = 1...100
    nonisolated static let defaultImageDynamicRange:
        ImageDynamicRange = .constrainedHigh
    nonisolated static let defaultNavigationIntervalMilliseconds = 80
    nonisolated static let navigationIntervalMillisecondsRange = 0...500
    nonisolated static let navigationIntervalMillisecondsStep = 10
    nonisolated static let defaultNavigationJumpDistance = 50
    nonisolated static let navigationJumpDistanceRange = 25...250
    nonisolated static let navigationJumpDistanceStep = 25

    private let defaults: UserDefaults

    private override convenience init() {
        self.init(defaults: .standard)
    }

    init(defaults: UserDefaults) {
        self.defaults = defaults
        zoomStepPercent = Self.readZoomStepPercent(from: defaults)
        imageSortField = Self.readImageSortField(from: defaults)
        imageSortDirection = Self.readImageSortDirection(from: defaults)
        imageDynamicRange = Self.readImageDynamicRange(from: defaults)
        navigationIntervalMilliseconds =
            Self.readNavigationIntervalMilliseconds(from: defaults)
        navigationJumpDistance = Self.readNavigationJumpDistance(from: defaults)
        preloadAdjacentImages = Self.readBool(
            Key.preloadAdjacentImages,
            defaultValue: true,
            from: defaults
        )
        sessionQuitBehavior = Self.readSessionQuitBehavior(
            from: defaults
        )
        quitOnLastWindowClosed = Self.readBool(
            Key.quitOnLastWindowClosed,
            defaultValue: false,
            from: defaults
        )
        hideTitleBar = Self.readBool(
            Key.hideTitleBar,
            defaultValue: false,
            from: defaults
        )
        super.init()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(defaultsDidChange),
            name: UserDefaults.didChangeNotification,
            object: defaults
        )
    }

    func refresh() {
        let newZoomStepPercent = Self.readZoomStepPercent(from: defaults)
        if zoomStepPercent != newZoomStepPercent {
            zoomStepPercent = newZoomStepPercent
        }

        let newImageSortField = Self.readImageSortField(from: defaults)
        if imageSortField != newImageSortField {
            imageSortField = newImageSortField
        }

        let newImageSortDirection = Self.readImageSortDirection(from: defaults)
        if imageSortDirection != newImageSortDirection {
            imageSortDirection = newImageSortDirection
        }

        let newImageDynamicRange = Self.readImageDynamicRange(from: defaults)
        if imageDynamicRange != newImageDynamicRange {
            imageDynamicRange = newImageDynamicRange
        }

        let newNavigationInterval =
            Self.readNavigationIntervalMilliseconds(from: defaults)
        if navigationIntervalMilliseconds != newNavigationInterval {
            navigationIntervalMilliseconds = newNavigationInterval
        }

        let newNavigationJumpDistance =
            Self.readNavigationJumpDistance(from: defaults)
        if navigationJumpDistance != newNavigationJumpDistance {
            navigationJumpDistance = newNavigationJumpDistance
        }

        let newPreloadAdjacentImages = Self.readBool(
            Key.preloadAdjacentImages,
            defaultValue: true,
            from: defaults
        )
        if preloadAdjacentImages != newPreloadAdjacentImages {
            preloadAdjacentImages = newPreloadAdjacentImages
        }

        let newSessionQuitBehavior = Self.readSessionQuitBehavior(
            from: defaults
        )
        if sessionQuitBehavior != newSessionQuitBehavior {
            sessionQuitBehavior = newSessionQuitBehavior
        }

        let newQuitOnLastWindowClosed = Self.readBool(
            Key.quitOnLastWindowClosed,
            defaultValue: false,
            from: defaults
        )
        if quitOnLastWindowClosed != newQuitOnLastWindowClosed {
            quitOnLastWindowClosed = newQuitOnLastWindowClosed
        }

        let newHideTitleBar = Self.readBool(
            Key.hideTitleBar,
            defaultValue: false,
            from: defaults
        )
        if hideTitleBar != newHideTitleBar {
            hideTitleBar = newHideTitleBar
        }
    }

    func setZoomStepPercent(_ value: Int) {
        defaults.set(
            Self.normalizedZoomStepPercent(value),
            forKey: Key.zoomStep
        )
        refresh()
    }

    func setNavigationIntervalMilliseconds(_ value: Int) {
        defaults.set(
            Self.normalizedNavigationIntervalMilliseconds(value),
            forKey: Key.navigationInterval
        )
        refresh()
    }

    func setNavigationJumpDistance(_ value: Int) {
        defaults.set(
            Self.normalizedNavigationJumpDistance(value),
            forKey: Key.navigationJumpDistance
        )
        refresh()
    }

    func setPreloadAdjacentImages(_ value: Bool) {
        defaults.set(value, forKey: Key.preloadAdjacentImages)
        refresh()
    }

    func setImageSortField(_ value: ImageSortField) {
        defaults.set(value.rawValue, forKey: Key.imageSortField)
        refresh()
    }

    func setImageSortDirection(_ value: SortDirection) {
        defaults.set(value.rawValue, forKey: Key.imageSortDirection)
        refresh()
    }

    func setImageDynamicRange(_ value: ImageDynamicRange) {
        defaults.set(value.rawValue, forKey: Key.imageDynamicRange)
        refresh()
    }

    func setSessionQuitBehavior(_ value: SessionQuitBehavior) {
        defaults.set(value.rawValue, forKey: Key.sessionQuitBehavior)
        refresh()
    }

    func setQuitOnLastWindowClosed(_ value: Bool) {
        defaults.set(value, forKey: Key.quitOnLastWindowClosed)
        refresh()
    }

    func setHideTitleBar(_ value: Bool) {
        defaults.set(value, forKey: Key.hideTitleBar)
        refresh()
    }

    @objc private func defaultsDidChange() {
        refresh()
    }

    private static func readZoomStepPercent(from defaults: UserDefaults) -> Int {
        guard
            let value = defaults.object(forKey: Key.zoomStep) as? NSNumber,
            value.intValue > 0
        else {
            return defaultZoomStepPercent
        }

        return normalizedZoomStepPercent(value.intValue)
    }

    private static func normalizedZoomStepPercent(_ value: Int) -> Int {
        min(
            max(value, zoomStepPercentRange.lowerBound),
            zoomStepPercentRange.upperBound
        )
    }

    private static func readImageSortField(
        from defaults: UserDefaults
    ) -> ImageSortField {
        guard
            let value = defaults.string(forKey: Key.imageSortField),
            let field = ImageSortField(rawValue: value)
        else {
            return .name
        }

        return field
    }

    private static func readImageSortDirection(
        from defaults: UserDefaults
    ) -> SortDirection {
        guard
            let value = defaults.string(forKey: Key.imageSortDirection),
            let direction = SortDirection(rawValue: value)
        else {
            return .ascending
        }

        return direction
    }

    private static func readImageDynamicRange(
        from defaults: UserDefaults
    ) -> ImageDynamicRange {
        guard
            let value = defaults.string(forKey: Key.imageDynamicRange),
            let dynamicRange = ImageDynamicRange(rawValue: value)
        else {
            return defaultImageDynamicRange
        }

        return dynamicRange
    }

    private static func readNavigationIntervalMilliseconds(
        from defaults: UserDefaults
    ) -> Int {
        guard
            let value = defaults.object(
                forKey: Key.navigationInterval
            ) as? NSNumber,
            value.intValue >= 0
        else {
            return defaultNavigationIntervalMilliseconds
        }

        return normalizedNavigationIntervalMilliseconds(value.intValue)
    }

    private static func normalizedNavigationIntervalMilliseconds(
        _ value: Int
    ) -> Int {
        min(
            max(value, navigationIntervalMillisecondsRange.lowerBound),
            navigationIntervalMillisecondsRange.upperBound
        )
    }

    private static func readNavigationJumpDistance(
        from defaults: UserDefaults
    ) -> Int {
        guard
            let value = defaults.object(
                forKey: Key.navigationJumpDistance
            ) as? NSNumber
        else {
            return defaultNavigationJumpDistance
        }

        return normalizedNavigationJumpDistance(value.intValue)
    }

    private static func normalizedNavigationJumpDistance(_ value: Int) -> Int {
        min(
            max(value, navigationJumpDistanceRange.lowerBound),
            navigationJumpDistanceRange.upperBound
        )
    }

    private static func readSessionQuitBehavior(
        from defaults: UserDefaults
    ) -> SessionQuitBehavior {
        guard
            let value = defaults.string(forKey: Key.sessionQuitBehavior),
            let behavior = SessionQuitBehavior(rawValue: value)
        else {
            return .followSystemSetting
        }

        return behavior
    }

    private static func readBool(
        _ key: String,
        defaultValue: Bool,
        from defaults: UserDefaults
    ) -> Bool {
        guard defaults.object(forKey: key) != nil else {
            return defaultValue
        }
        return defaults.bool(forKey: key)
    }
}
