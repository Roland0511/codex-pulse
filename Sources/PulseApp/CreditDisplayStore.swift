import Combine
import CoreFoundation
import Foundation
import PulseCore

/// 点数显示偏好的唯一所有者；不保存余额，也不改变额度读取或账户状态。
@MainActor final class CreditDisplayStore: ObservableObject {
    static let shared = CreditDisplayStore()
    @Published private(set) var compactDecimalPlaces: Int
    @Published private(set) var expandedDecimalPlaces: Int
    private let defaults: UserDefaults
    private static let compactKey = "creditCompactDecimalPlaces"
    private static let expandedKey = "creditExpandedDecimalPlaces"

    init(defaults: UserDefaults? = nil) {
        let storage = defaults ?? LocalDefaults.store
        self.defaults = storage
        compactDecimalPlaces = Self.read(storage, key: Self.compactKey, fallback: 1)
        expandedDecimalPlaces = Self.read(storage, key: Self.expandedKey, fallback: 2)
    }

    private static func read(_ defaults: UserDefaults, key: String, fallback: Int) -> Int {
        guard let number = defaults.object(forKey: key) as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              let value = number as? Int,
              CreditText.decimalPlacesRange.contains(value) else { return fallback }
        return value
    }

    func setCompactDecimalPlaces(_ places: Int) {
        guard CreditText.decimalPlacesRange.contains(places), places != compactDecimalPlaces else { return }
        compactDecimalPlaces = places
        defaults.set(places, forKey: Self.compactKey)
    }

    func setExpandedDecimalPlaces(_ places: Int) {
        guard CreditText.decimalPlacesRange.contains(places), places != expandedDecimalPlaces else { return }
        expandedDecimalPlaces = places
        defaults.set(places, forKey: Self.expandedKey)
    }
}
