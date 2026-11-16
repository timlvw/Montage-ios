import Foundation

/// One value the app can show anywhere (dashboard tile, Live Activity,
/// CarPlay). Plain Foundation.
enum Metric: String, CaseIterable, Codable, Identifiable {
    case boost, rpm, speed, gear, coolant, intake, battery, throttle, pedal, load
    case fuel, economy, slip, injDuty, ignSpread, scRatio, alternator, lambda, o2Up

    var id: String { rawValue }

    var label: String {
        switch self {
        case .boost: return "Boost"
        case .rpm: return "RPM"
        case .speed: return "Speed"
        case .gear: return "Gear"
        case .coolant: return "Coolant"
        case .intake: return "Intake"
        case .battery: return "Battery"
        case .throttle: return "Throttle"
        case .pedal: return "Pedal"
        case .load: return "Load"
        case .fuel: return "Fuel"
        case .economy: return "Economy"
        case .slip: return "Front slip"
        case .injDuty: return "Inj. duty"
        case .ignSpread: return "Ign. spread"
        case .scRatio: return "S/C ratio"
        case .alternator: return "Alternator"
        case .lambda: return "Lambda corr."
        case .o2Up: return "O2 up"
        }
    }

    /// Short label for tight places (Dynamic Island, CarPlay).
    var short: String {
        switch self {
        case .coolant: return "CLT"
        case .intake: return "IAT"
        case .battery: return "BATT"
        case .throttle: return "TPS"
        case .boost: return "BOOST"
        case .economy: return "ECON"
        case .injDuty: return "DUTY"
        case .ignSpread: return "KNOCK"
        case .scRatio: return "S/C"
        case .alternator: return "ALT"
        case .lambda: return "LAMBDA"
        default: return label.uppercased()
        }
    }

    /// The gauge PID whose warn/critical zones colour this value.
    var zonePid: Int? {
        switch self {
        case .rpm: return 0x0C
        case .speed: return 0x0D
        case .coolant: return 0x05
        case .intake: return 0x0F
        case .battery: return 0x42
        case .throttle: return 0x11
        case .load: return 0x04
        case .boost: return 0xE1
        case .injDuty: return 0xE7
        case .slip: return 0xE9
        case .ignSpread: return 0xE6
        default: return nil
        }
    }
}

/// Everything needed to turn a frame into readings.
struct Snapshot {
    var engine: EngineFrame
    var gauges: [GaugeSlotValue]
    var units: UnitPrefs
    var boost: BoostTracker
    var fuelTripL: Double = 0

    func reading(_ m: Metric) -> Reading {
        let e = engine
        switch m {
        case .boost: return Fmt.pressureRel(boost.boost(e), units)
        case .rpm: return Reading(value: Fmt.num(e[.rpm], 0), unit: "rpm")
        case .speed: return Fmt.speed(e[.speed], units)
        case .gear:
            guard let g = e[.gear] else { return Reading(value: "--", unit: "") }
            return Reading(value: g >= 1 ? Fmt.num(g, 0) : "N", unit: "")
        case .coolant: return Fmt.temp(e[.coolant], units)
        case .intake: return Fmt.temp(e[.intake], units)
        case .battery: return Reading(value: Fmt.num(e[.battery], 1), unit: "V")
        case .throttle: return Reading(value: Fmt.num(e[.throttle], 0), unit: "%")
        case .pedal: return Reading(value: Fmt.num(e[.pedal], 0), unit: "%")
        case .load: return Reading(value: Fmt.num(e[.load], 0), unit: "%")
        case .fuel: return Fmt.fuelFlow(e[.fuel], units)
        case .economy:
            return Fmt.economy(kph: e[.speed], lph: e[.fuel], units) ?? Fmt.volume(e[.fuel] == nil ? nil : fuelTripL, units)
        case .slip: return Reading(value: Fmt.num(e[.slip], 0), unit: "%")
        case .injDuty: return Reading(value: Fmt.num(e[.injDuty], 0), unit: "%")
        case .ignSpread: return Reading(value: Fmt.num(e.ignitionSpread, 1), unit: "°")
        case .scRatio: return Reading(value: Fmt.num(e.scRatio, 2), unit: "")
        case .alternator: return Reading(value: Fmt.num(e[.alternator], 0), unit: "%")
        case .lambda: return Reading(value: Fmt.num(e[.lambda], 1), unit: "%")
        case .o2Up: return Reading(value: Fmt.num(e[.o2Up].map { $0 / 1000 }, 2), unit: "V")
        }
    }

    /// 0 normal, 1 warn, 2 critical: from the gauge's own zones when one of
    /// its slots shows this value, else a few fixed limits.
    func level(_ m: Metric) -> Int {
        if let pid = m.zonePid, let g = gauges.first(where: { $0.pid == pid && $0.valid }) {
            return g.critical ? 2 : g.warn ? 1 : 0
        }
        let e = engine
        switch m {
        case .coolant: if let c = e[.coolant] { return c >= 112 ? 2 : c >= 106 ? 1 : 0 }
        case .battery: if let v = e[.battery] { return v < 11.8 ? 2 : v < 12.8 && (e[.rpm] ?? 0) > 500 ? 1 : 0 }
        case .ignSpread: if let s = e.ignitionSpread { return s > 3 ? 2 : s > 1.5 ? 1 : 0 }
        case .injDuty: if let d = e[.injDuty] { return d > 90 ? 2 : d > 80 ? 1 : 0 }
        case .slip: if let s = e[.slip] { return s > 15 ? 2 : s > 6 ? 1 : 0 }
        default: break
        }
        return 0
    }
}
