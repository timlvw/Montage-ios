import Foundation
#if canImport(ActivityKit)
import ActivityKit

/// The Live Activity: shown on the Lock Screen, in the Dynamic Island, and
/// (iOS 26) on CarPlay. Shared by the app (which starts and updates it) and
/// the widget extension (which draws it).
struct GaugeActivityAttributes: ActivityAttributes {
    struct Tile: Codable, Hashable {
        var label: String       // "BOOST"
        var value: String       // "9.7"
        var unit: String        // "psi"
        var level: Int          // 0 normal, 1 warn, 2 critical
    }

    struct ContentState: Codable, Hashable {
        var tiles: [Tile]       // up to 4, in the order chosen in Settings
        var gear: String        // "3", "N", "" when unknown
        var link: String        // "BMW mode", "OBD mode", "Not connected"
        var alarm: String       // "" when none
        var alarmLevel: Int
        var updated: Date
    }

    var title: String
}
#endif

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
