import Foundation

/// Display units. By default the app follows the choice made on the gauge
/// (it arrives in every ENGINE frame); Settings can override it.
struct UnitPrefs: Equatable, Codable {
    var tempF = false
    var mph = false
    var psi = false

    static let metric = UnitPrefs(tempF: false, mph: false, psi: false)
    static let imperial = UnitPrefs(tempF: true, mph: true, psi: true)
}

/// A number ready to show: value text and unit text.
struct Reading: Equatable {
    var value: String
    var unit: String
    static let none = Reading(value: "--", unit: "")
}

enum Fmt {
    static func num(_ x: Double?, _ decimals: Int) -> String {
        guard let x = x, x.isFinite else { return "--" }
        return String(format: "%.\(decimals)f", x)
    }

    static func temp(_ c: Double?, _ u: UnitPrefs) -> Reading {
        guard let c = c else { return Reading(value: "--", unit: u.tempF ? "°F" : "°C") }
        return u.tempF ? Reading(value: num(c * 9 / 5 + 32, 0), unit: "°F") : Reading(value: num(c, 0), unit: "°C")
    }

    static func speed(_ kph: Double?, _ u: UnitPrefs) -> Reading {
        guard let k = kph else { return Reading(value: "--", unit: u.mph ? "mph" : "km/h") }
        return u.mph ? Reading(value: num(k * 0.621371, 0), unit: "mph") : Reading(value: num(k, 0), unit: "km/h")
    }

    /// Pressure relative to something (boost): psi with one decimal, or kPa.
    static func pressureRel(_ kpa: Double?, _ u: UnitPrefs) -> Reading {
        guard let k = kpa else { return Reading(value: "--", unit: u.psi ? "psi" : "kPa") }
        return u.psi ? Reading(value: num(k * 0.145038, 1), unit: "psi") : Reading(value: num(k, 0), unit: "kPa")
    }

    static func fuelFlow(_ lph: Double?, _ u: UnitPrefs) -> Reading {
        guard let l = lph else { return Reading(value: "--", unit: u.psi ? "gal/h" : "L/h") }
        return u.psi ? Reading(value: num(l * 0.264172, 2), unit: "gal/h") : Reading(value: num(l, 1), unit: "L/h")
    }

    static func volume(_ l: Double?, _ u: UnitPrefs) -> Reading {
        guard let l = l else { return Reading(value: "--", unit: u.psi ? "gal" : "L") }
        return u.psi ? Reading(value: num(l * 0.264172, 2), unit: "gal") : Reading(value: num(l, 2), unit: "L")
    }

    /// Economy from speed and fuel flow: mpg (US) or L/100 km. nil when
    /// standing still or not burning fuel.
    static func economy(kph: Double?, lph: Double?, _ u: UnitPrefs) -> Reading? {
        guard let k = kph, let l = lph, k > 3, l > 0.05 else { return nil }
        if u.mph { return Reading(value: num((k * 0.621371) / (l * 0.264172), 1), unit: "mpg") }
        return Reading(value: num(l / k * 100, 1), unit: "L/100km")
    }
}

/// Boost is manifold pressure minus the barometric pressure. The barometer
/// is learned from the pressure before the supercharger whenever the engine
/// is stopped (both read the air outside then); 101.3 kPa until then.
struct BoostTracker {
    private(set) var baroKpa: Double = 101.3

    mutating func update(_ e: EngineFrame) {
        if let rpm = e[.rpm], rpm < 400, let pre = e[.mapPre], pre > 60, pre < 110 { baroKpa = pre }
        // no pre-supercharger sensor (standard OBD): engine off, the manifold reads the barometer
        else if e[.mapPre] == nil, let rpm = e[.rpm], rpm < 100, let m = e[.map], m > 60, m < 110 { baroKpa = m }
    }

    func boost(_ e: EngineFrame) -> Double? {
        guard let m = e[.map] else { return nil }
        return m - baroKpa
    }

    func preBoost(_ e: EngineFrame) -> Double? {
        guard let m = e[.mapPre] else { return nil }
        return m - baroKpa
    }
}

extension EngineFrame {
    /// Ignition angles of the four cylinders, if all are there.
    var ignition: [Double]? {
        let v = [self[.ign1], self[.ign2], self[.ign3], self[.ign4]]
        let c = v.compactMap { $0 }
        return c.count == 4 ? c : nil
    }

    var retard: [Double] {
        [self[.ret1] ?? 0, self[.ret2] ?? 0, self[.ret3] ?? 0, self[.ret4] ?? 0]
    }

    var ignitionSpread: Double? {
        guard let i = ignition, let mx = i.max(), let mn = i.min() else { return nil }
        return mx - mn
    }

    var scRatio: Double? {
        guard let m = self[.map], let p = self[.mapPre], p > 10 else { return nil }
        return m / p
    }
}

/// CSV rows for the trip log: one line per ENGINE frame.
enum TripCSV {
    static var header: String {
        "time_s," + Field.allCases.map(\.key).joined(separator: ",") + ",boost_kpa,link"
    }

    static func row(t: Double, frame e: EngineFrame, boostKpa: Double?) -> String {
        var cols: [String] = [String(format: "%.2f", t)]
        for f in Field.allCases {
            if let v = e[f] {
                cols.append(f.factor >= 100 ? String(format: "%.2f", v) : f.factor >= 10 ? String(format: "%.1f", v) : String(format: "%.0f", v))
            } else {
                cols.append("")
            }
        }
        cols.append(boostKpa.map { String(format: "%.1f", $0) } ?? "")
        cols.append(String(e.link.rawValue))
        return cols.joined(separator: ",")
    }
}
