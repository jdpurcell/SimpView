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

@MainActor
final class AppPreferences: NSObject, ObservableObject {
    static let shared = AppPreferences()

    @Published private(set) var zoomStepPercent: Int
    @Published private(set) var imageSortField: ImageSortField
    @Published private(set) var imageSortDirection: SortDirection
    @Published private(set) var navigationIntervalMilliseconds: Int
    @Published private(set) var promptToRememberSession: Bool
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
        static let promptToRememberSession = "promptToRememberSession"
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
        promptToRememberSession = Self.readBool(
            Key.promptToRememberSession,
            defaultValue: true,
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

        let newPromptToRememberSession = Self.readBool(
            Key.promptToRememberSession,
            defaultValue: true,
            from: defaults
        )
        if promptToRememberSession != newPromptToRememberSession {
            promptToRememberSession = newPromptToRememberSession
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

    func setImageSortField(_ value: ImageSortField) {
        defaults.set(value.rawValue, forKey: Key.imageSortField)
        refresh()
    }

    func setImageSortDirection(_ value: SortDirection) {
        defaults.set(value.rawValue, forKey: Key.imageSortDirection)
        refresh()
    }

    func setPromptToRememberSession(_ value: Bool) {
        defaults.set(value, forKey: Key.promptToRememberSession)
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
