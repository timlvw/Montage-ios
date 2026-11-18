import Foundation

// The gauge's settings, layout, files and dyno car settings, as its
// "settings", "config", "pids", "themes", "files" and "dynocar" commands
// return them. The same functions serve the gauge's web page (gauge_admin.cpp
// in the firmware), so the app and the web page always agree.

struct GaugeSettings: Codable, Equatable {
    var tempF = false
    var speedMph = false
    var pressPsi = false
    var logAuto = true
    var logActive = false
    var logFile = ""
    var recOn = true
    var recActive = false
    var recFile = ""
    var engine = false
    var transport = 1          // 0 Bluetooth adapter, 1 K-line
    var klproto = 0            // 0 BMW blocks + OBD fallback, 1 OBD only, 2 BMW only
    var klmode = ""
    var klpins = 0             // saved: 0 UART connector, 1 header pins
    var klpinsNow = 0          // in use this boot (-1 = not in K-line mode)
    var freeKB = 0
    var totalKB = 0

    var restartNeeded: Bool { transport == 1 && klpinsNow >= 0 && klpins != klpinsNow }
}

struct ZoneConfig: Codable, Equatable {
    var on: Bool
    var from: Double
    var to: Double
    var col: String
}

struct SlotConfig: Codable, Equatable {
    var en: Bool
    var pid: Int
    var min: Double
    var max: Double
    var ticks: Int
    var major: Int
    var dec: Int
    var label: String
    var emblem: Int
    var emtext: String
    var needle: String
    var bg: String
    var text: String
    var arc: String
    var emcol: String
    var z: [ZoneConfig]
}

struct GaugeConfig: Codable, Equatable {
    var tempF: Bool
    var speedMph: Bool
    var pressPsi: Bool
    var slots: [SlotConfig]
    var combo: [Int]
}

struct PidInfo: Codable, Equatable, Identifiable {
    var pid: Int
    var key: String
    var name: String
    var unit: String
    var min: Double
    var max: Double
    var sup: Bool
    var id: Int { pid }
}

struct ThemeInfo: Codable, Equatable, Identifiable {
    var t: Int
    var n: String
    var needle: String
    var bg: String
    var text: String
    var arc: String
    var id: Int { t }
}

struct DynoCarSettings: Codable, Equatable {
    var mass: Double
    var cda: Double
    var crr: Double
    var loss: Double

    init(mass: Double, cda: Double, crr: Double, loss: Double) { self.mass = mass; self.cda = cda; self.crr = crr; self.loss = loss }
    init(_ d: DynoSettings) { self.init(mass: d.massKg, cda: d.cdA, crr: d.crr, loss: d.lossPct) }
    var settings: DynoSettings { DynoSettings(massKg: mass, cdA: cda, crr: crr, lossPct: loss) }
    var command: String {
        "dynocar " + AdminQuery.encode([("mass", String(format: "%.0f", mass)), ("cda", String(format: "%.3f", cda)),
                                        ("crr", String(format: "%.4f", crr)), ("loss", String(format: "%.1f", loss))])
    }
}

struct GaugeFile: Codable, Equatable, Identifiable {
    var n: String
    var s: Int
    var busy: String           // "", "log" (the CSV being written), "rec" (the drive recording in progress)
    var id: String { n }

    enum Kind: Int, Comparable { case log, drive, dyno, other
        static func < (a: Kind, b: Kind) -> Bool { a.rawValue < b.rawValue }
    }
    var kind: Kind {
        if n.hasPrefix("log_") { return .log }
        if n.hasPrefix("drive_") { return .drive }
        if n.hasPrefix("dyno_") { return .dyno }
        return .other
    }
    /// "2026-11-17 16:22" from "drive_20261117-162205.txt"; "No. 12" from "drive_0012.txt".
    var title: String {
        let stem = (n as NSString).deletingPathExtension
        guard let us = stem.firstIndex(of: "_") else { return stem }
        let rest = String(stem[stem.index(after: us)...])
        let d = Array(rest)
        if d.count >= 13, d[8] == "-", rest.prefix(8).allSatisfy(\.isNumber) {
            let s = String(d)
            func sub(_ a: Int, _ b: Int) -> String { String(s[s.index(s.startIndex, offsetBy: a)..<s.index(s.startIndex, offsetBy: b)]) }
            let extra = d.count > 15 ? " (" + String(d[15...]).trimmingCharacters(in: CharacterSet(charactersIn: "-")) + ")" : ""
            return "\(sub(0, 4))-\(sub(4, 6))-\(sub(6, 8)) \(sub(9, 11)):\(sub(11, 13))" + extra
        }
        if let k = Int(rest) { return "No. \(k)" }
        return rest
    }
    /// Newest first: dated names sort by date, numbered ones by number.
    var sortKey: String { n }
}

struct GaugeFiles: Codable, Equatable {
    var freeKB: Int
    var totalKB: Int
    var files: [GaugeFile]
}

enum AdminQuery {
    private static let allowed: CharacterSet = {
        var c = CharacterSet.alphanumerics
        c.insert(charactersIn: "-._~")
        return c
    }()

    static func escape(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s }

    static func encode(_ pairs: [(String, String)]) -> String {
        pairs.map { "\(escape($0.0))=\(escape($0.1))" }.joined(separator: "&")
    }

    /// The gauge takes commands up to 199 characters: split the pairs into as
    /// few commands as fit, each repeating the `fixed` pairs (the slot index).
    static func commands(_ verb: String, fixed: [(String, String)], pairs: [(String, String)], limit: Int = 190) -> [String] {
        let head = verb + " " + encode(fixed)
        var out: [String] = []
        var cur = head
        var has = false
        for p in pairs {
            let piece = "&" + encode([p])
            if has && cur.count + piece.count > limit {
                out.append(cur)
                cur = head
                has = false
            }
            cur += piece
            has = true
        }
        if has || out.isEmpty { out.append(cur) }
        return out
    }
}

enum AdminReply {
    /// nil when the gauge said "ok", else its reason ("error: ..." or anything else).
    static func error(_ reply: String?) -> String? {
        guard let r = reply?.trimmingCharacters(in: .whitespacesAndNewlines) else { return "No reply from the gauge." }
        if r == "ok" { return nil }
        if r.hasPrefix("error: ") { return String(r.dropFirst(7)) }
        return r
    }

    static func decode<T: Decodable>(_ type: T.Type, _ reply: String?) -> T? {
        guard let r = reply, let d = r.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(type, from: d)
    }
}

/// One "fget <name> <offset>" reply: "<total size>\n<bytes>".
enum FileChunk {
    static func parse(_ body: String) -> (total: Int, data: Data)? {
        guard let nl = body.firstIndex(of: "\n"), let total = Int(body[..<nl]) else { return nil }
        let data = Data(body[body.index(after: nl)...].utf8)
        return (total, data)
    }
}

/// Engine running / stopped, from rpm, the same rule as the gauge
/// (engine_state.h): running after 2 s above 400 rpm, stopped after 30 s
/// without (no rpm counts as stopped, e.g. key off or link lost).
struct EngineRunDetector {
    enum Event: Equatable { case started, stopped }
    var startAfter: TimeInterval = 2
    var stopAfter: TimeInterval = 30
    private(set) var running = false
    private var aboveSince: Date?
    private var belowSince: Date?

    mutating func update(rpm: Double?, at now: Date) -> Event? {
        if let r = rpm, r > 400 {
            belowSince = nil
            if aboveSince == nil { aboveSince = now }
            if !running, let a = aboveSince, now.timeIntervalSince(a) >= startAfter {
                running = true
                return .started
            }
        } else {
            aboveSince = nil
            if belowSince == nil { belowSince = now }
            if running, let b = belowSince, now.timeIntervalSince(b) >= stopAfter {
                running = false
                return .stopped
            }
        }
        return nil
    }

    mutating func reset() { running = false; aboveSince = nil; belowSince = nil }
}
