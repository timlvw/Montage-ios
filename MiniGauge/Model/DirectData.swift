import Foundation

/// Direct-to-adapter mode: turns standard OBD readings into the same frames
/// the gauge streams (engine, gauge slots, status, info), so every screen,
/// the trip log and the Live Activity work unchanged. The "gauges" shown are
/// made up here, with the gauge firmware's built-in default zones
/// (gauge_config.cpp ZONE_SEEDS, same base units). Plain Foundation.
struct DirectData {
    struct Zone: Equatable { var from: Double; var to: Double; var color: String; var alarm: Int }
    enum UClass { case none, temp, speed, pressure }
    struct Def {
        let pid: UInt8, key: String, name: String, unit: String, uclass: UClass, d: Int
        let min: Double, max: Double
        let zones: [Zone]
    }

    private static let blue = "#3A8DFF", green = "#35C759", amber = "#FFB020", red = "#FF2D55"
    private static func z(_ f: Double, _ t: Double, _ c: String, _ a: Int = 0) -> Zone { Zone(from: f, to: t, color: c, alarm: a) }

    /// The values a standard OBD engine computer can give, shown as gauges.
    static let defs: [Def] = [
        Def(pid: 0x0C, key: "rpm", name: "RPM", unit: "rpm", uclass: .none, d: 0, min: 0, max: 8000,
            zones: [z(0, 2000, blue), z(2000, 6000, green), z(6000, 6500, amber), z(6500, 8000, red, 2)]),
        Def(pid: 0x0D, key: "speedkph", name: "Speed", unit: "km/h", uclass: .speed, d: 0, min: 0, max: 220,
            zones: [z(0, 105, green), z(105, 130, amber), z(130, 220, red)]),
        Def(pid: 0x05, key: "coolant", name: "Coolant Temp", unit: "C", uclass: .temp, d: 0, min: 40, max: 130,
            zones: [z(40, 70, blue), z(70, 105, green), z(105, 110, amber, 1), z(110, 130, red, 2)]),
        Def(pid: 0x0F, key: "iat", name: "Intake Air Temp", unit: "C", uclass: .temp, d: 0, min: -10, max: 70,
            zones: [z(-10, 10, blue), z(10, 45, green), z(45, 60, amber), z(60, 70, red, 1)]),
        Def(pid: 0x0B, key: "map", name: "MAP", unit: "kPa", uclass: .pressure, d: 0, min: 0, max: 250,
            zones: [z(0, 100, blue), z(100, 200, green), z(200, 215, amber, 1), z(215, 250, red, 2)]),
        Def(pid: 0x11, key: "throttle", name: "Throttle Pos", unit: "%", uclass: .none, d: 0, min: 0, max: 100,
            zones: [z(0, 50, green), z(50, 90, amber), z(90, 100, red)]),
        Def(pid: 0x04, key: "load", name: "Engine Load", unit: "%", uclass: .none, d: 0, min: 0, max: 100,
            zones: [z(0, 60, green), z(60, 85, amber), z(85, 100, red)]),
        Def(pid: 0x42, key: "modulev", name: "Module Voltage", unit: "V", uclass: .none, d: 1, min: 0, max: 18,
            zones: [z(0, 11.8, red), z(11.8, 12.8, amber), z(12.8, 15.2, green), z(15.2, 18, red, 1)]),
    ]

    /// Where each OBD value goes in the engine frame (SI there, as from the gauge).
    static func field(_ pid: UInt8) -> Field? {
        switch pid {
        case 0x0C: return .rpm
        case 0x0D: return .speed
        case 0x0B: return .map
        case 0x05: return .coolant
        case 0x0F: return .intake
        case 0x11: return .throttle
        case 0x04: return .load
        case 0x42: return .battery
        case 0x14: return .o2Up
        case 0x15: return .o2Down
        case 0x06: return .lambda       // short-term trim = the engine computer's lambda correction
        case 0x07: return .trim         // long-term trim = its adaptation
        case 0x2F: return .fuelLevel
        default: return nil
        }
    }

    static func toField(_ pid: UInt8, _ v: Double) -> Double {
        switch pid {
        case 0x14, 0x15: return v * 1000            // V -> mV
        case 0x2F: return v / 100 * 50              // % of the R53's 50 L tank
        default: return v
        }
    }

    // display units, as the gauge would show them
    var tempF = true, mph = true, psi = false
    var linkText = ""
    var running = false            // the engine computer is answering
    var mil: Bool?
    var dtcCount: Int?
    var codes: [String] = []
    private(set) var latest: [UInt8: (v: Double, at: Date)] = [:]
    private var stamps: [Date] = []
    private var seq: UInt16 = 0
    static let staleAfter: TimeInterval = 10

    mutating func add(_ pid: UInt8, _ v: Double, at t: Date) {
        latest[pid] = (v, t)
        stamps.append(t)
        stamps.removeAll { t.timeIntervalSince($0) > 5 }
    }

    mutating func clear() {
        latest = [:]
        stamps = []
        mil = nil
        dtcCount = nil
    }

    func repliesPerSec(at t: Date) -> Double {
        Double(stamps.filter { t.timeIntervalSince($0) <= 5 }.count) / 5
    }

    private func fresh(_ pid: UInt8, _ t: Date) -> Double? {
        guard let l = latest[pid], t.timeIntervalSince(l.at) <= Self.staleAfter else { return nil }
        return l.v
    }

    mutating func engineFrame(at t: Date) -> EngineFrame {
        seq &+= 1
        var e = EngineFrame()
        e.seq = seq
        e.link = running ? .obd : .waking
        e.tempF = tempF; e.speedMph = mph; e.pressPsi = psi
        e.milValid = mil != nil
        e.milOn = mil ?? false
        e.dtcCount = dtcCount
        e.blocksPerSec = repliesPerSec(at: t)
        for (pid, _) in latest {
            if let f = Self.field(pid), let v = fresh(pid, t) { e.values[f] = Self.toField(pid, v) }
        }
        return e
    }

    func display(_ d: Def, _ v: Double) -> Double {
        switch d.uclass {
        case .temp: return tempF ? v * 9 / 5 + 32 : v
        case .speed: return mph ? v * 0.621371 : v
        case .pressure: return psi ? v * 0.145038 : v
        case .none: return v
        }
    }

    private func unit(_ d: Def) -> String {
        switch d.uclass {
        case .temp: return tempF ? "F" : "C"
        case .speed: return mph ? "mph" : "km/h"
        case .pressure: return psi ? "psi" : "kPa"
        case .none: return d.unit
        }
    }

    /// Gauges for the values this engine computer has answered.
    private var shown: [Def] { Self.defs.filter { latest[$0.pid] != nil } }

    func info() -> GaugeInfo {
        let slots = shown.enumerated().map { i, d in
            GaugeInfo.Slot(i: i, pid: Int(d.pid), key: d.key, name: d.name, unit: unit(d), d: d.uclass == .pressure && psi ? 1 : d.d,
                           min: display(d, d.min), max: display(d, d.max),
                           zones: d.zones.enumerated().map { k, z in
                               GaugeInfo.Zone(from: display(d, z.from), to: display(d, z.to), crit: z.alarm == 2, color: z.color, z: k, al: z.alarm)
                           })
        }
        return GaugeInfo(v: 1, board: "OBD adapter", build: "direct", units: .init(tempF: tempF, mph: mph, psi: psi),
                         proto: linkText, pref: 0, slots: slots)
    }

    func slots(at t: Date) -> [GaugeSlotValue] {
        shown.enumerated().map { i, d in
            guard let v = fresh(d.pid, t) else {
                return GaugeSlotValue(slot: i, pid: Int(d.pid), valid: false, warn: false, critical: false, value: 0, ageMs: nil)
            }
            let k = Self.zoneIndex(d.zones, min: d.min, v)
            let al = k.map { d.zones[$0].alarm } ?? 0
            let age = Int(t.timeIntervalSince(latest[d.pid]!.at) * 1000)
            return GaugeSlotValue(slot: i, pid: Int(d.pid), valid: true, warn: al == 1, critical: al == 2,
                                  value: display(d, v), ageMs: max(0, age), zone: k)
        }
    }

    func status(at t: Date) -> StatusFrame {
        var s = StatusFrame()
        s.link = running ? .obd : .waking
        s.linkText = linkText
        s.pollsPerSec = Int(repliesPerSec(at: t).rounded())
        s.codes = codes
        // the worst zone alarm, as the gauge's alarm banner would show it
        for d in shown {
            guard let v = fresh(d.pid, t), let k = Self.zoneIndex(d.zones, min: d.min, v) else { continue }
            let al = d.zones[k].alarm
            if al > s.alarmLevel {
                s.alarmLevel = al
                s.alarmText = "\(d.name) \(String(format: "%.\(d.d)f", display(d, v))) \(unit(d))"
            }
        }
        return s
    }

    // MARK: - zones (the gauge's rules: gauge_zoneContains / gauge_zoneIndexFor)

    static func contains(_ zs: [Zone], _ k: Int, min: Double, _ v: Double) -> Bool {
        let z = zs[k]
        guard z.to > z.from else { return false }
        if v >= z.from && v <= z.to { return true }
        if v > z.to {
            // past the top: only the highest band keeps the value
            return !zs.indices.contains { $0 != k && zs[$0].to > zs[$0].from && zs[$0].to > z.to }
        }
        return z.from <= min        // below the dial: a band starting at its minimum
    }

    static func zoneIndex(_ zs: [Zone], min: Double, _ v: Double) -> Int? {
        var best: Int?
        for k in zs.indices where contains(zs, k, min: min, v) {
            guard let b = best else { best = k; continue }
            if zs[k].alarm > zs[b].alarm || (zs[k].alarm == zs[b].alarm && zs[k].from > zs[b].from) { best = k }
        }
        return best
    }
}
