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
    @Published private(set) var navigationIntervalMilliseconds: Int
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
        static let navigationInterval = "navigationInterval"
        static let preloadAdjacentImages = "preloadAdjacentImages"
        static let sessionQuitBehavior = "sessionQuitBehavior"
        static let quitOnLastWindowClosed = "quitOnLastWindowClosed"
        static let hideTitleBar = "hideTitleBar"
    }

    private static let defaultZoomStepPercent = 25
    private static let defaultNavigationIntervalMilliseconds = 80

    private let defaults: UserDefaults

    private override convenience init() {
        self.init(defaults: .standard)
    }

    init(defaults: UserDefaults) {
        self.defaults = defaults
        zoomStepPercent = Self.readZoomStepPercent(from: defaults)
        imageSortField = Self.readImageSortField(from: defaults)
        imageSortDirection = Self.readImageSortDirection(from: defaults)
        navigationIntervalMilliseconds =
            Self.readNavigationIntervalMilliseconds(from: defaults)
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

        let newNavigationInterval =
            Self.readNavigationIntervalMilliseconds(from: defaults)
        if navigationIntervalMilliseconds != newNavigationInterval {
            navigationIntervalMilliseconds = newNavigationInterval
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
        guard value > 0 else {
            return
        }

        defaults.set(value, forKey: Key.zoomStep)
        refresh()
    }

    func setNavigationIntervalMilliseconds(_ value: Int) {
        guard value > 0 else {
            return
        }

        defaults.set(value, forKey: Key.navigationInterval)
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

        return value.intValue
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

    private static func readNavigationIntervalMilliseconds(
        from defaults: UserDefaults
    ) -> Int {
        guard
            let value = defaults.object(
                forKey: Key.navigationInterval
            ) as? NSNumber,
            value.intValue > 0
        else {
            return defaultNavigationIntervalMilliseconds
        }

        return value.intValue
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
