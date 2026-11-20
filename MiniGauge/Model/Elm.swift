import Foundation

// Talking straight to a Bluetooth LE ELM327 OBD adapter, without the gauge:
// reply parsing, standard OBD (SAE J1979) decoding, and the session that
// wakes the engine computer and polls it. Plain Foundation, so it is
// unit-tested anywhere; ObdAdapterLink does the Bluetooth.
//
// Same approach as the gauge firmware's adapter mode (ble_display_impl.cpp):
// ISO 9141-2 first (what this R53's engine computer speaks), then the two
// KWP2000 inits, then automatic as a last resort.

enum ElmError: Error, Equatable {
    case noData            // asked fine, nothing answered that request
    case unableToConnect   // no engine computer on the bus (key off?)
    case busInit           // "BUS INIT: ...ERROR"
    case busError          // BUS ERROR / FB ERROR / DATA ERROR / BUFFER FULL
    case stopped           // the adapter gave up on the request
    case unknownCommand    // "?"
    case timeout           // no prompt in time
    case garbled(String)

    var text: String {
        switch self {
        case .noData: return "No data"
        case .unableToConnect: return "Unable to connect to the engine computer"
        case .busInit: return "The engine computer didn't answer the wake-up"
        case .busError: return "Bus error"
        case .stopped: return "Stopped"
        case .unknownCommand: return "The adapter didn't understand"
        case .timeout: return "The adapter didn't answer"
        case .garbled(let s): return "Odd reply: \(s)"
        }
    }

    /// Errors that mean the car stopped answering (key off, wrong protocol).
    var isBusDown: Bool { [.unableToConnect, .busInit, .stopped, .timeout].contains(self) }
}

enum ElmReply {
    /// The useful lines of one reply (everything before the ">" prompt):
    /// no blanks, no echo of the command, no "SEARCHING..." or "BUS INIT: ...OK".
    static func lines(_ raw: String, sent: String? = nil) -> [String] {
        var out: [String] = []
        for part in raw.split(whereSeparator: { $0 == "\r" || $0 == "\n" }) {
            var l = part.trimmingCharacters(in: .whitespaces)
            l = l.replacingOccurrences(of: ">", with: "").trimmingCharacters(in: .whitespaces)
            if l.isEmpty { continue }
            let u = l.uppercased()
            if let s = sent, u.replacingOccurrences(of: " ", with: "") == s.uppercased().replacingOccurrences(of: " ", with: "") { continue }
            if u.hasPrefix("SEARCHING") { continue }
            if u.hasPrefix("BUS INIT") && !u.contains("ERROR") { continue }   // "BUS INIT: ...OK", or the OK on its own line
            out.append(l)
        }
        return out
    }

    /// The error a reply amounts to, if it is one.
    static func error(_ lines: [String]) -> ElmError? {
        if lines.isEmpty { return .noData }
        for l in lines {
            let u = l.uppercased()
            if u.contains("NO DATA") { return .noData }
            if u.contains("UNABLE TO CONNECT") { return .unableToConnect }
            if u.hasPrefix("BUS INIT") && u.contains("ERROR") { return .busInit }
            if u.contains("BUS ERROR") || u.contains("FB ERROR") || u.contains("DATA ERROR") || u.contains("BUFFER FULL")
                || u.contains("CAN ERROR") || u.contains("LV RESET") { return .busError }
            if u.contains("STOPPED") { return .stopped }
            if u == "?" { return .unknownCommand }
            if u == "ERROR" { return .busError }
        }
        return nil
    }

    /// Hex bytes of one data line ("41 0C 1A F8" or "410C1AF8"); nil if it isn't hex.
    static func bytes(_ line: String) -> [UInt8]? {
        let h = line.replacingOccurrences(of: " ", with: "")
        guard !h.isEmpty, h.count % 2 == 0 else { return nil }
        var out: [UInt8] = []
        var i = h.startIndex
        while i < h.endIndex {
            let j = h.index(i, offsetBy: 2)
            guard let b = UInt8(h[i..<j], radix: 16) else { return nil }
            out.append(b)
            i = j
        }
        return out
    }
}

/// Standard OBD (SAE J1979) mode 01 decoding. Values in natural units:
/// rpm, km/h, kPa, °C, %, V.
enum ObdDecode {
    /// The data bytes answering "01 pid" (first engine computer to answer).
    static func payload(_ pid: UInt8, _ lines: [String]) -> [UInt8]? {
        for l in lines {
            guard let b = bytes(l), b.count >= 3, b[0] == 0x41, b[1] == pid else { continue }
            return Array(b[2...])
        }
        return nil
    }

    private static func bytes(_ l: String) -> [UInt8]? { ElmReply.bytes(l) }

    static func value(_ pid: UInt8, _ lines: [String]) -> Double? {
        guard let d = payload(pid, lines), let a = d.first.map(Double.init) else { return nil }
        let b = d.count > 1 ? Double(d[1]) : 0
        switch pid {
        case 0x04, 0x11, 0x2F: return a * 100 / 255
        case 0x05, 0x0F: return a - 40
        case 0x06, 0x07: return (a - 128) * 100 / 128
        case 0x0B, 0x0D: return a
        case 0x0C: return (a * 256 + b) / 4
        case 0x0E: return a / 2 - 64
        case 0x14, 0x15: return a / 200
        case 0x42: return d.count > 1 ? (a * 256 + b) / 1000 : nil
        default: return nil
        }
    }

    /// The PIDs a "01 base" support bitmap says are there (base 0x00, 0x20, 0x40).
    static func supported(_ base: UInt8, _ lines: [String]) -> Set<UInt8>? {
        guard let d = payload(base, lines), d.count >= 4 else { return nil }
        var s = Set<UInt8>()
        for (i, byte) in d.prefix(4).enumerated() {
            for bit in 0..<8 where byte & (0x80 >> bit) != 0 {
                s.insert(base + UInt8(i * 8 + bit) + 1)
            }
        }
        return s
    }

    /// Mode 01 PID 01: check-engine lamp and how many codes are stored.
    static func status(_ lines: [String]) -> (mil: Bool, count: Int)? {
        guard let d = payload(0x01, lines), let a = d.first else { return nil }
        return (a & 0x80 != 0, Int(a & 0x7F))
    }

    /// Mode 03 reply: stored trouble codes ("P0133"). Every line starts 43;
    /// ISO 9141 puts three codes in each, padded with 0000.
    static func codes(_ lines: [String]) -> [String] {
        var out: [String] = []
        for l in lines {
            guard let b = ElmReply.bytes(l), b.first == 0x43 else { continue }
            var d = Array(b.dropFirst())
            if d.count % 2 == 1 { d = Array(d.dropFirst()) }     // CAN-style count byte
            var i = 0
            while i + 1 < d.count {
                let hi = d[i], lo = d[i + 1]
                i += 2
                if hi == 0 && lo == 0 { continue }
                let letter = ["P", "C", "B", "U"][Int(hi >> 6)]
                let code = letter + String(format: "%01X%01X%02X", (hi >> 4) & 0x3, hi & 0x0F, lo)
                if !out.contains(code) { out.append(code) }
            }
        }
        return out
    }

    /// "ATRV": the adapter's own reading of the battery ("12.6V").
    static func volts(_ lines: [String]) -> Double? {
        for l in lines {
            let t = l.uppercased().replacingOccurrences(of: "V", with: "").trimmingCharacters(in: .whitespaces)
            if let v = Double(t), v > 3, v < 30 { return v }
        }
        return nil
    }
}

/// Which Bluetooth devices look like an ELM327 adapter: clones advertise all
/// sorts, so it goes by name and service hints, as the gauge firmware does
/// (ble_obd.cpp).
enum AdapterAdvert {
    static let nameHints = ["OBD", "ELM", "VLINK", "V-LINK", "VEEPEAK", "VGATE", "ICAR", "KONNWEI", "VIECAR", "LELINK",
                            "CARISTA", "ANCEL", "OBDLINK", "SCANNER", "BLE_TO_UART", "IOS-", "SINO", "VPECKER", "THINKDIAG"]
    /// 16-bit services ELM327 clones expose, plus Vgate's 128-bit one.
    static let serviceHints = ["FFF0", "FFE0", "18F0", "FFE5", "FFF1", "FF00", "E7810A71-73AE-499D-8C15-FAA9AEF0C3F2"]

    static func score(name: String?, services: [String], rssi: Int) -> Int {
        let n = (name ?? "").uppercased()
        if n.contains("MINIGAUGE") { return 0 }
        var s = 0
        if !n.isEmpty && nameHints.contains(where: { n.contains($0) }) { s += 100 }
        if services.contains(where: { u in serviceHints.contains { u.uppercased() == $0 } }) { s += 50 }
        if s > 0 && rssi > -75 { s += 10 }
        return s
    }

    /// Worth connecting to: an adapter-like name, or an adapter service and close by.
    static func plausible(name: String?, services: [String], rssi: Int) -> Bool {
        let s = score(name: name, services: services, rssi: rssi)
        return s >= 100 || (s >= 50 && rssi > -75)
    }
}

/// One ELM327 session: resets the adapter, wakes the engine computer
/// (trying protocols in turn), then polls the standard values for ever,
/// fitting a code read / clear in between when asked. Driven by the link:
/// it sends what `send` asks for and hands back each reply (or a timeout).
final class ElmSession {
    enum State: Equatable {
        case idle
        case resetting                 // ATZ and settings
        case waking(String)            // first request on a protocol: the K-line wake-up
        case running(String)           // polling
        case noCar                     // nothing answered; trying again shortly

        var text: String {
            switch self {
            case .idle: return "Not started"
            case .resetting: return "Setting up the adapter…"
            case .waking(let p): return "Waking the engine computer (\(ElmSession.protocolName(p)))…"
            case .running(let p): return "Connected (\(ElmSession.protocolName(p)))"
            case .noCar: return "The engine computer isn't answering. Key on?"
            }
        }
    }

    // outputs (set by the link)
    var send: (_ command: String, _ timeout: TimeInterval) -> Void = { _, _ in }
    var gotValue: (_ pid: UInt8, _ value: Double) -> Void = { _, _ in }
    var gotStatus: (_ mil: Bool, _ count: Int) -> Void = { _, _ in }
    var stateChanged: (State) -> Void = { _ in }
    var retryLater: (TimeInterval) -> Void = { _ in }        // call resume() after this long
    var adapterDead: () -> Void = {}                          // reconnect the Bluetooth link
    var protocolWorked: (String) -> Void = { _ in }
    var now: () -> Date = { Date() }

    private(set) var state: State = .idle { didSet { if state != oldValue { stateChanged(state) } } }
    private(set) var supported: Set<UInt8> = []
    private(set) var dropped: Set<UInt8> = []

    /// Polled every round, then one of the slow ones.
    static let fastPids: [UInt8] = [0x0C, 0x0D, 0x0B, 0x11]
    static let slowPids: [UInt8] = [0x05, 0x0F, 0x04, 0x42, 0x06, 0x07, 0x14, 0x15, 0x2F]

    private enum Job {
        case at(String, TimeInterval)
        case probe                     // 0100: wakes the bus and lists PIDs 01-20
        case support(UInt8)            // 0120 / 0140
        case status                    // 0101
        case pid(UInt8)
        case volts                     // ATRV
        case user(String, (Result<[String], ElmError>) -> Void)

        var command: String {
            switch self {
            case .at(let c, _): return c
            case .probe: return "0100"
            case .support(let b): return String(format: "01%02X", b)
            case .status: return "0101"
            case .pid(let p): return String(format: "01%02X", p)
            case .volts: return "ATRV"
            case .user(let c, _): return c
            }
        }
        var timeout: TimeInterval {
            switch self {
            case .at(_, let t): return t
            case .probe: return 12          // a 5-baud K-line wake-up takes a few seconds
            case .user: return 8
            default: return 3
            }
        }
    }

    private var ladder: [String]
    private var rung = 0
    private var proto: String
    private var queue: [Job] = []
    private var current: Job?
    private var atTimeouts = 0
    private var busFails = 0
    private var noData: [UInt8: Int] = [:]
    private var fastIdx = 0
    private var slowIdx = 0
    private var lastStatus = Date.distantPast
    private var lastVolts = Date.distantPast

    init(protocolFirst: String? = nil) {
        var l = ["3", "5", "4", "0"]
        if let p = protocolFirst, let i = l.firstIndex(of: p) { l.remove(at: i); l.insert(p, at: 0) }
        ladder = l
        proto = l[0]
    }

    static func protocolName(_ p: String) -> String {
        switch p {
        case "3": return "ISO 9141-2"
        case "4": return "KWP2000, slow init"
        case "5": return "KWP2000, fast init"
        case "0": return "automatic"
        default: return "protocol \(p)"
        }
    }

    var isBusy: Bool { current != nil }

    /// The Bluetooth link is ready: start from scratch.
    func start() {
        reset()
        state = .resetting
        queue = [.at("ATZ", 4), .at("ATE0", 2), .at("ATL0", 2), .at("ATS0", 2), .at("ATH0", 2), .at("ATAT1", 2),
                 .at("ATSP\(proto)", 2), .probe]
        next()
    }

    /// After noCar: try the bus again (the adapter itself is fine).
    func resume() {
        guard state == .noCar, current == nil else { return }
        rung = 0
        proto = ladder[0]
        wake(proto)
    }

    func stop() {
        reset()
        state = .idle
    }

    private func reset() {
        let pending = queue
        queue = []
        if case .user(_, let done)? = current { done(.failure(.timeout)) }
        for j in pending { if case .user(_, let done) = j { done(.failure(.timeout)) } }
        current = nil
        atTimeouts = 0
        busFails = 0
        noData = [:]
        dropped = []
        supported = []
        rung = 0
        proto = ladder[0]
    }

    /// A one-off request ("03" codes, "04" clear) between polls.
    func request(_ command: String, done: @escaping (Result<[String], ElmError>) -> Void) {
        guard case .running = state else { done(.failure(.unableToConnect)); return }
        queue.insert(.user(command, done), at: 0)
        next()
    }

    /// A whole reply arrived (the text before the ">" prompt).
    func received(_ raw: String) {
        guard let job = current else { return }
        current = nil
        let lines = ElmReply.lines(raw, sent: job.command)
        handle(job, lines: lines, error: ElmReply.error(lines))
        next()
    }

    /// No prompt in time for the outstanding command.
    func timedOut() {
        guard let job = current else { return }
        current = nil
        handle(job, lines: [], error: .timeout)
        next()
    }

    // MARK: -

    private func wake(_ p: String) {
        proto = p
        state = .waking(p)
        queue.removeAll { if case .user = $0 { return false } else { return true } }
        queue.append(contentsOf: [.at("ATPC", 2), .at("ATSP\(p)", 2), .probe])
        next()
    }

    private func next() {
        guard current == nil else { return }
        var job: Job?
        if !queue.isEmpty { job = queue.removeFirst() }
        else if case .running = state { job = pollJob() }
        guard let j = job else { return }
        if case .probe = j, state == .resetting { state = .waking(proto) }
        current = j
        send(j.command, j.timeout)
    }

    private func available(_ p: UInt8) -> Bool {
        (supported.isEmpty || supported.contains(p)) && !dropped.contains(p)
    }

    private func pollJob() -> Job {
        let t = now()
        if t.timeIntervalSince(lastStatus) > 10 { lastStatus = t; return .status }
        if !available(0x42), t.timeIntervalSince(lastVolts) > 5 { lastVolts = t; return .volts }
        let fast = Self.fastPids.filter(available)
        let slow = Self.slowPids.filter(available)
        if fastIdx < fast.count {
            let p = fast[fastIdx]
            fastIdx += 1
            return .pid(p)
        }
        fastIdx = 0
        if !slow.isEmpty {
            let p = slow[slowIdx % slow.count]
            slowIdx += 1
            return .pid(p)
        }
        if let p = fast.first { fastIdx = 1; return .pid(p) }
        return .status
    }

    private func handle(_ job: Job, lines: [String], error: ElmError?) {
        switch job {
        case .at(let c, _):
            if error == .timeout {
                atTimeouts += 1
                if atTimeouts >= 3 && c != "ATZ" { atTimeouts = 0; queue = []; state = .idle; adapterDead() }
            } else {
                atTimeouts = 0
            }

        case .probe:
            if let s = ObdDecode.supported(0x00, lines) {
                supported = s
                busFails = 0
                state = .running(proto)
                protocolWorked(proto)
                // try this one first next time the car has to be woken
                if let i = ladder.firstIndex(of: proto), i > 0 { ladder.remove(at: i); ladder.insert(proto, at: 0); rung = 0 }
                if s.contains(0x20) { queue.append(.support(0x20)) }
                queue.append(.status)
                lastStatus = now()
            } else {
                rung += 1
                if rung < ladder.count {
                    wake(ladder[rung])
                } else {
                    rung = 0
                    proto = ladder[0]
                    state = .noCar
                    retryLater(8)
                }
            }

        case .support(let base):
            if let s = ObdDecode.supported(base, lines) {
                supported.formUnion(s)
                if base == 0x20 && s.contains(0x40) { queue.insert(.support(0x40), at: 0) }
            }

        case .status:
            if let st = ObdDecode.status(lines) { gotStatus(st.mil, st.count) }
            busFailure(error)

        case .pid(let p):
            if let v = ObdDecode.value(p, lines) {
                gotValue(p, v)
                noData[p] = 0
                busFails = 0
            } else if error == .noData || error == nil {
                noData[p, default: 0] += 1
                if noData[p, default: 0] >= 3 { dropped.insert(p) }    // this engine computer doesn't have it
            } else {
                busFailure(error)
            }

        case .volts:
            if let v = ObdDecode.volts(lines) { gotValue(0x42, v) }
            busFailure(error == .timeout ? error : nil)

        case .user(_, let done):
            if let e = error { done(.failure(e)) } else { done(.success(lines)) }
            busFailure(error == .noData ? nil : error)
        }
    }

    /// Several bus errors in a row: the car went away (key off). Wake it again shortly.
    private func busFailure(_ error: ElmError?) {
        guard let e = error, e.isBusDown else { return }
        busFails += 1
        if busFails >= 4, case .running = state {
            busFails = 0
            state = .noCar
            retryLater(4)
        }
    }
}
