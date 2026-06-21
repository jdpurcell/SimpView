import Combine
import Foundation

enum ImageSortField: String, Sendable {
    case name
    case modificationDate
}

enum SortDirection: String, Sendable {
    case ascending
    case descending
}

@MainActor
final class AppPreferences: NSObject, ObservableObject {
    static let shared = AppPreferences()

    @Published private(set) var zoomStepPercent: Int
    @Published private(set) var imageSortField: ImageSortField
    @Published private(set) var imageSortDirection: SortDirection

    var zoomStep: CGFloat {
        1 + CGFloat(zoomStepPercent) / 100
    }

    private enum Key {
        static let zoomStep = "zoomStep"
        static let imageSortField = "imageSortField"
        static let imageSortDirection = "imageSortDirection"
    }

    private static let defaultZoomStepPercent = 25

    private let defaults: UserDefaults

    private override convenience init() {
        self.init(defaults: .standard)
    }

    init(defaults: UserDefaults) {
        self.defaults = defaults
        zoomStepPercent = Self.readZoomStepPercent(from: defaults)
        imageSortField = Self.readImageSortField(from: defaults)
        imageSortDirection = Self.readImageSortDirection(from: defaults)
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
    }

    func setZoomStepPercent(_ value: Int) {
        guard value > 0 else {
            return
        }

        defaults.set(value, forKey: Key.zoomStep)
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
}
