import Combine
import Foundation

@MainActor
final class AppPreferences: NSObject, ObservableObject {
    static let shared = AppPreferences()

    @Published private(set) var zoomStepPercent: Int

    var zoomStep: CGFloat {
        1 + CGFloat(zoomStepPercent) / 100
    }

    private enum Key {
        static let zoomStep = "zoomStep"
    }

    private static let defaultZoomStepPercent = 25

    private let defaults: UserDefaults

    private override convenience init() {
        self.init(defaults: .standard)
    }

    init(defaults: UserDefaults) {
        self.defaults = defaults
        zoomStepPercent = Self.readZoomStepPercent(from: defaults)
        super.init()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(defaultsDidChange),
            name: UserDefaults.didChangeNotification,
            object: defaults
        )
    }

    func refresh() {
        zoomStepPercent = Self.readZoomStepPercent(from: defaults)
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
}
