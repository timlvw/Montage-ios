import Foundation

// The gauge's Bluetooth protocol, version 1. Mirrors phone_proto.h in the
// firmware (cluster175/src): change one, change the other.
//
// Plain Foundation only, so it builds and is unit-tested anywhere.

enum GaugeUUID {
    static let service = "6E4D4701-8B2C-4B8E-9B0A-3C1F5A2D7E01"
    static let live    = "6E4D4702-8B2C-4B8E-9B0A-3C1F5A2D7E01"
    static let command = "6E4D4703-8B2C-4B8E-9B0A-3C1F5A2D7E01"
    static let text    = "6E4D4704-8B2C-4B8E-9B0A-3C1F5A2D7E01"
}

let gaugeProtocolVersion: UInt8 = 1

/// How the gauge is talking to the car.
enum LinkLevel: UInt8 {
    case none = 0, waking = 1, obd = 2, bmw = 3

    var title: String {
        switch self {
        case .none: return "No car data"
        case .waking: return "Waking the engine computer"
        case .obd: return "OBD mode"
        case .bmw: return "BMW mode"
        }
    }
}

/// ENGINE frame fields, in wire order. Values are SI.
enum Field: Int, CaseIterable {
    case rpm = 0, speed, gear, map, mapPre, coolant, intake, throttle, pedal, battery, load, o2Up, o2Down
    case ign1, ign2, ign3, ign4, ret1, ret2, ret3, ret4
    case knock, slip, wheelFL, wheelFR, fuel, injDuty, injMs, airflow, lambda, trim, fuelLevel   // fuelLevel: L, was alternator load

    /// The factor the int16 on the wire carries.
    var factor: Double {
        switch self {
        case .rpm, .gear, .o2Up, .o2Down, .knock: return 1
        case .battery, .ign1, .ign2, .ign3, .ign4, .ret1, .ret2, .ret3, .ret4, .fuel, .injMs, .lambda, .trim: return 100
        default: return 10
        }
    }

    /// Column name in logs, and a stable key.
    var key: String {
        switch self {
        case .rpm: return "rpm"
        case .speed: return "speed_kph"
        case .gear: return "gear"
        case .map: return "map_kpa"
        case .mapPre: return "map_pre_kpa"
        case .coolant: return "coolant_c"
        case .intake: return "intake_c"
        case .throttle: return "throttle_pct"
        case .pedal: return "pedal_pct"
        case .battery: return "battery_v"
        case .load: return "load_pct"
        case .o2Up: return "o2_up_mv"
        case .o2Down: return "o2_down_mv"
        case .ign1: return "ign1_deg"
        case .ign2: return "ign2_deg"
        case .ign3: return "ign3_deg"
        case .ign4: return "ign4_deg"
        case .ret1: return "retard1_deg"
        case .ret2: return "retard2_deg"
        case .ret3: return "retard3_deg"
        case .ret4: return "retard4_deg"
        case .knock: return "knock_mv"
        case .slip: return "front_slip_pct"
        case .wheelFL: return "wheel_fl_kph"
        case .wheelFR: return "wheel_fr_kph"
        case .fuel: return "fuel_lph"
        case .injDuty: return "inj_duty_pct"
        case .injMs: return "inj_ms"
        case .airflow: return "airflow_kgh"
        case .lambda: return "lambda_corr_pct"
        case .trim: return "fuel_trim_pct"
        case .fuelLevel: return "fuel_level_l"
        }
    }
}

struct EngineFrame: Equatable {
    var seq: UInt16 = 0
    var link: LinkLevel = .none
    var milValid = false, milOn = false
    var dynoRecording = false, dynoDone = false
    var alarmWarn = false, alarmCritical = false
    var tempF = false, speedMph = false, pressPsi = false
    var dtcCount: Int? = nil            // nil = not read yet
    var blocksPerSec: Double = 0
    var values: [Field: Double] = [:]

    subscript(_ f: Field) -> Double? { values[f] }
}

struct GaugeSlotValue: Equatable, Identifiable {
    var slot: Int
    var pid: Int
    var valid: Bool
    var warn: Bool
    var critical: Bool
    var value: Double          // display units, as on the gauge
    var ageMs: Int?            // nil = never read
    var id: Int { slot }
}

struct StatusFrame: Equatable {
    var alarmLevel = 0
    var link: LinkLevel = .none
    var pollsPerSec = 0
    var fuelTripL: Double = 0
    var linkText = ""
    var alarmText = ""
    var codes: [String] = []
}

enum Frame: Equatable {
    case engine(EngineFrame)
    case gauges([GaugeSlotValue])
    case status(StatusFrame)
}

enum FrameError: Error, Equatable {
    case empty, unknownType(UInt8), tooShort, badVersion(UInt8)
}

/// Little-endian reader over a byte array.
struct ByteReader {
    let b: [UInt8]
    var i = 0
    init(_ d: [UInt8]) { b = d }
    var remaining: Int { b.count - i }
    mutating func u8() -> UInt8 { let v = b[i]; i += 1; return v }
    mutating func u16() -> UInt16 { let v = UInt16(b[i]) | UInt16(b[i + 1]) << 8; i += 2; return v }
    mutating func i16() -> Int16 { Int16(bitPattern: u16()) }
    mutating func u32() -> UInt32 {
        var v: UInt32 = 0
        for k in 0..<4 { v |= UInt32(b[i + k]) << (8 * k) }
        i += 4
        return v
    }
    mutating func f32() -> Float { Float(bitPattern: u32()) }
    mutating func text(_ width: Int) -> String {
        let slice = b[i..<(i + width)]
        i += width
        let bytes = slice.prefix { $0 != 0 }
        return String(decoding: bytes, as: UTF8.self)
    }
}

enum FrameDecoder {
    static let engineLength = 78

    static func decode(_ data: [UInt8]) throws -> Frame {
        guard let type = data.first else { throw FrameError.empty }
        switch type {
        case 1: return .engine(try engine(data))
        case 2: return .gauges(try gauges(data))
        case 3: return .status(try status(data))
        default: throw FrameError.unknownType(type)
        }
    }

    static func engine(_ d: [UInt8]) throws -> EngineFrame {
        guard d.count >= engineLength else { throw FrameError.tooShort }
        var r = ByteReader(d)
        _ = r.u8()
        let version = r.u8()
        guard version == gaugeProtocolVersion else { throw FrameError.badVersion(version) }
        var e = EngineFrame()
        e.seq = r.u16()
        e.link = LinkLevel(rawValue: r.u8()) ?? .none
        let flags = r.u8()
        e.milValid = flags & 0x01 != 0
        e.milOn = flags & 0x02 != 0
        e.dynoRecording = flags & 0x04 != 0
        e.dynoDone = flags & 0x08 != 0
        e.alarmWarn = flags & 0x10 != 0
        e.alarmCritical = flags & 0x20 != 0
        let units = r.u8()
        e.tempF = units & 0x01 != 0
        e.speedMph = units & 0x02 != 0
        e.pressPsi = units & 0x04 != 0
        let dc = r.u8()
        e.dtcCount = dc == 255 ? nil : Int(dc)
        e.blocksPerSec = Double(r.u16()) / 10
        let present = r.u32()
        for f in Field.allCases {
            let raw = r.i16()
            if present & (1 << UInt32(f.rawValue)) != 0 {
                e.values[f] = Double(raw) / f.factor
            }
        }
        return e
    }

    static func gauges(_ d: [UInt8]) throws -> [GaugeSlotValue] {
        guard d.count >= 2 else { throw FrameError.tooShort }
        var r = ByteReader(d)
        _ = r.u8()
        let n = Int(r.u8())
        guard r.remaining >= n * 9 else { throw FrameError.tooShort }
        var out: [GaugeSlotValue] = []
        for _ in 0..<n {
            let slot = Int(r.u8()), pid = Int(r.u8()), flags = r.u8()
            let v = Double(r.f32())
            let age = r.u16()
            out.append(GaugeSlotValue(slot: slot, pid: pid, valid: flags & 1 != 0, warn: flags & 2 != 0,
                                      critical: flags & 4 != 0, value: v, ageMs: age == 65535 ? nil : Int(age)))
        }
        return out
    }

    static func status(_ d: [UInt8]) throws -> StatusFrame {
        guard d.count >= 89 else { throw FrameError.tooShort }
        var r = ByteReader(d)
        _ = r.u8()
        var s = StatusFrame()
        s.alarmLevel = Int(r.u8())
        s.link = LinkLevel(rawValue: r.u8()) ?? .none
        s.pollsPerSec = Int(r.u8())
        s.fuelTripL = Double(r.f32())
        s.linkText = r.text(40)
        s.alarmText = r.text(40)
        let n = Int(r.u8())
        guard r.remaining >= n * 5 else { throw FrameError.tooShort }
        for _ in 0..<n { s.codes.append(r.text(5)) }
        return s
    }
}

/// Puts TEXT notifications back together: [id][part][flags bit0 = last][text].
struct TextReassembler {
    private var id: UInt8? = nil
    private var nextPart: UInt8 = 0
    private var buffer: [UInt8] = []

    /// Feed one chunk. Returns the whole reply when its last chunk arrives.
    mutating func feed(_ chunk: [UInt8]) -> (id: UInt8, text: String)? {
        guard chunk.count >= 3 else { return nil }
        let cid = chunk[0], part = chunk[1], last = chunk[2] & 1 != 0
        if part == 0 {
            id = cid
            buffer = []
            nextPart = 0
        }
        guard cid == id, part == nextPart else {
            // a lost chunk: drop this reply
            id = nil
            buffer = []
            return nil
        }
        buffer.append(contentsOf: chunk[3...])
        nextPart &+= 1
        if last {
            let text = String(decoding: buffer, as: UTF8.self)
            id = nil
            buffer = []
            return (cid, text)
        }
        return nil
    }
}

// MARK: - INFO reply (the gauge set-up)

struct GaugeInfo: Codable, Equatable {
    struct Units: Codable, Equatable { var tempF: Bool; var mph: Bool; var psi: Bool }
    struct Zone: Codable, Equatable { var from: Double; var to: Double; var crit: Bool; var color: String }
    struct Slot: Codable, Equatable, Identifiable {
        var i: Int
        var pid: Int
        var key: String
        var name: String
        var unit: String
        var d: Int
        var min: Double
        var max: Double
        var zones: [Zone]
        var id: Int { i }
    }
    var v: Int
    var board: String
    var build: String
    var units: Units
    var proto: String
    var pref: Int
    var slots: [Slot]

    static func parse(_ text: String) -> GaugeInfo? {
        guard let d = text.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(GaugeInfo.self, from: d)
    }
}
