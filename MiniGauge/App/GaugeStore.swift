import Foundation
import SwiftUI
import UIKit

/// Where the live data comes from.
enum DataSource: String, CaseIterable {
    case gauge, adapter
}

enum ConnState: Equatable {
    case idle, scanning, connecting, connected, bluetoothOff, unauthorized, unsupported, demo

    var text: String {
        switch self {
        case .idle: return "Not connected"
        case .scanning: return "Looking for your MiniGauge…"
        case .connecting: return "Connecting…"
        case .connected: return "Connected"
        case .bluetoothOff: return "Bluetooth is off"
        case .unauthorized: return "Bluetooth not allowed (Settings → MiniGauge)"
        case .unsupported: return "This device has no Bluetooth LE"
        case .demo: return "Demo data"
        }
    }
}

/// Everything the screens show, fed by the Bluetooth link (or demo data).
final class GaugeStore: ObservableObject {
    static let shared = GaugeStore()

    // live data
    @Published private(set) var engine = EngineFrame()
    @Published private(set) var gauges: [GaugeSlotValue] = []
    @Published private(set) var status = StatusFrame()
    @Published private(set) var info: GaugeInfo?
    @Published private(set) var lastFrame: Date?
    @Published private(set) var boostHistory: [Double] = []     // kPa, ~4 a second, last 60 s
    @Published private(set) var rpmHistory: [Double] = []

    // link
    @Published private(set) var conn: ConnState = .idle
    @Published var deviceName = ""

    // replies to commands
    @Published private(set) var rawText = ""
    @Published private(set) var logText = ""
    @Published private(set) var carText = ""
    @Published private(set) var carBusy = false
    @Published private(set) var dynoCSV = ""
    @Published private(set) var lastNotice = ""

    // settings (UserDefaults)
    @Published var unitMode: Int { didSet { save("unitMode", unitMode) } }               // 0 gauge, 1 metric, 2 imperial
    @Published var liveActivityOn: Bool { didSet { save("liveActivityOn", liveActivityOn); if !liveActivityOn { activity.end() } } }
    @Published var activityMetrics: [Metric] { didSet { save("activityMetrics", activityMetrics.map(\.rawValue)) } }
    @Published var keepAwake: Bool { didSet { save("keepAwake", keepAwake); applyIdleTimer() } }
    @Published var autoLog: Bool { didSet { save("autoLog", autoLog) } }      // record a trip log while the engine runs
    @Published var demoMode: Bool { didSet { save("demoMode", demoMode); restartSource() } }
    @Published var source: DataSource { didSet { save("source", source.rawValue); if source != oldValue { restartSource() } } }
    @Published var dyno: DynoSettings { didSet { if let d = try? JSONEncoder().encode(dyno) { UserDefaults.standard.set(d, forKey: "dyno") } } }
    @Published private(set) var logging = false

    private(set) var boost = BoostTracker()
    private let link = GaugeLink()
    private let adapter = ObdAdapterLink()
    private var savedUnits = ""
    private let activity = ActivityController()
    private let logger = TripLogger()
    private var demo = DemoSource()
    private var demoTimer: Timer?
    private var carPoll: Timer?
    private var lastHist = Date.distantPast
    private var started = false
    private var engineRun = EngineRunDetector()
    private var autoOwned = false              // this trip log was started by the engine, so it stops with it
    private var waiters: [String: [(id: Int, done: (String?) -> Void)]] = [:]
    private var waiterSeq = 0

    private init() {
        let d = UserDefaults.standard
        unitMode = d.object(forKey: "unitMode") as? Int ?? 0
        liveActivityOn = d.object(forKey: "liveActivityOn") as? Bool ?? true
        let m = (d.stringArray(forKey: "activityMetrics") ?? []).compactMap(Metric.init(rawValue:))
        activityMetrics = m.isEmpty ? [.boost, .coolant, .intake, .battery] : m
        keepAwake = d.object(forKey: "keepAwake") as? Bool ?? true
        autoLog = d.object(forKey: "autoLog") as? Bool ?? false
        demoMode = d.object(forKey: "demoMode") as? Bool ?? ProcessInfo.processInfo.arguments.contains("-demo")
        if let data = d.data(forKey: "dyno"), let v = try? JSONDecoder().decode(DynoSettings.self, from: data) { dyno = v }
        else { dyno = DynoSettings() }
        source = DataSource(rawValue: d.string(forKey: "source") ?? "") ?? .gauge
        // for the cloud build's screenshots: -source adapter
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "-source"), i + 1 < args.count, let s = DataSource(rawValue: args[i + 1]) { source = s }
        link.store = self
        adapter.store = self
    }

    private func save(_ key: String, _ v: Any) { UserDefaults.standard.set(v, forKey: key) }

    // MARK: - lifecycle

    func start() {
        guard !started else { return }
        started = true
        restartSource()
    }

    private func restartSource() {
        guard started else { return }
        demoTimer?.invalidate()
        demoTimer = nil
        if demoMode {
            link.stop()
            adapter.stop()
            setConn(.demo)
            info = DemoSource.info
            rawText = DemoSource.rawText
            demoTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                guard let self = self else { return }
                let (e, g, s) = self.demo.step(0.1)
                self.ingest(.engine(e))
                if Int(self.demo.t * 10) % 3 == 0 { self.ingest(.gauges(g)) }
                if Int(self.demo.t * 10) % 10 == 0 { self.ingest(.status(s)) }
            }
        } else {
            engine = EngineFrame()
            info = nil
            gauges = []
            status = StatusFrame()
            if source == .adapter {
                link.stop()
                adapter.start()
            } else {
                adapter.stop()
                link.start()
            }
        }
    }

    /// Talking straight to an OBD adapter instead of the gauge.
    var isAdapter: Bool { source == .adapter && !demoMode }

    /// The connection state, in words, for whichever device is in use.
    var connText: String {
        guard isAdapter else { return conn.text }
        switch conn {
        case .scanning: return "Looking for your OBD adapter…"
        case .connecting: return "Connecting to the OBD adapter…"
        default: return conn.text
        }
    }

    func forgetAdapter() { adapter.forget() }
    func setDirectInfo(_ i: GaugeInfo) { info = i }
    func lastNoticeFromLink(_ s: String) { lastNotice = s }

    func appBecameActive() {
        applyIdleTimer()
        if liveActivityOn && isLive { activity.startIfPossible(activityState()) }
    }

    func forgetGauge() { link.forget() }

    // MARK: - from the link

    func setConn(_ c: ConnState) {
        if conn == c { return }
        conn = c
        applyIdleTimer()
    }

    func linkReady() {
        send(Self.timeCommand())          // the gauge has no clock battery: set it on every connect
        send("info")
        Task { await syncDynoCar() }
    }

    func linkDropped() {
        carBusy = false
        carPoll?.invalidate()
        engine.link = .none
        engineRun.reset()
        if autoOwned && logging { toggleLogging() }      // no data any more: close the trip
        autoOwned = false
        if logging { logger.flush() }
        for (_, ws) in waiters { for w in ws { w.done(nil) } }
        waiters = [:]
        activity.update(activityState())
    }

    var isLive: Bool { conn == .connected || conn == .demo }

    var units: UnitPrefs {
        switch unitMode {
        case 1: return .metric
        case 2: return .imperial
        default: return UnitPrefs(tempF: engine.tempF, mph: engine.speedMph, psi: engine.pressPsi)
        }
    }

    var snapshot: Snapshot {
        Snapshot(engine: engine, gauges: gauges, units: units, boost: boost, fuelTripL: status.fuelTripL)
    }

    func ingest(_ f: Frame) {
        switch f {
        case .engine(let e):
            engine = e
            if !isAdapter && !demoMode && e.link != .none {
                // the gauge's display units, so direct mode shows the same ones
                let u = "\(e.tempF)\(e.speedMph)\(e.pressPsi)"
                if u != savedUnits {
                    savedUnits = u
                    let d = UserDefaults.standard
                    d.set(e.tempF, forKey: "lastUnits.tempF"); d.set(e.speedMph, forKey: "lastUnits.mph"); d.set(e.pressPsi, forKey: "lastUnits.psi")
                }
            }
            lastFrame = Date()
            boost.update(e)
            let now = Date()
            if now.timeIntervalSince(lastHist) >= 0.25 {
                lastHist = now
                if let b = boost.boost(e) { boostHistory.append(b); if boostHistory.count > 240 { boostHistory.removeFirst() } }
                if let r = e[.rpm] { rpmHistory.append(r); if rpmHistory.count > 240 { rpmHistory.removeFirst() } }
            }
            followEngine(e[.rpm], at: now)
            if logging { logger.add(e, boostKpa: boost.boost(e)) }
            if liveActivityOn {
                let st = activityState()
                if activity.isRunning { activity.update(st) } else { activity.startIfPossible(st) }
            }
        case .gauges(let g):
            gauges = g
        case .status(let s):
            status = s
        }
    }

    func reply(_ text: String) {
        let parts = text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        let cmd = parts.first.map(String.init) ?? ""
        let body = parts.count > 1 ? String(parts[1]) : ""
        if let ws = waiters.removeValue(forKey: cmd) {
            for w in ws { w.done(body) }
            return                                  // asked for by request(): the caller shows the result
        }
        // a late reply to a request that already gave up: nothing to show
        if Self.requestPrefixes.contains(where: { cmd.hasPrefix($0) }) { return }
        switch cmd {
        case "info":
            if let i = GaugeInfo.parse(body) { info = i }
        case "raw":
            rawText = body
        case "log":
            logText = body
        case "cartext":
            let lines = body.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
            carBusy = lines.first == "busy"
            carText = lines.count > 1 ? String(lines[1]) : ""
            if !carBusy { carPoll?.invalidate() }
        case "dynocsv":
            dynoCSV = body
        case _ where cmd.hasPrefix("time "):
            break                             // clock set; nothing to show
        default:
            if cmd.hasPrefix("car ") {
                if body == "started" { startCarPoll() } else { lastNotice = "Gauge: \(body)" }
            } else if !body.isEmpty {
                lastNotice = "Gauge: \(body)"
            }
        }
    }

    // MARK: - commands

    private static let requestPrefixes = ["fget ", "fdel ", "set ", "slot ", "combo ", "theme ", "dynocar", "settings", "config",
                                          "pids", "themes", "files", "log start", "log stop", "codes clear", "restart"]

    /// "time Y M D h m s" in local time, as the gauge's web page sends it.
    static func timeCommand(_ date: Date = Date()) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return "time \(c.year ?? 2026) \(c.month ?? 1) \(c.day ?? 1) \(c.hour ?? 0) \(c.minute ?? 0) \(c.second ?? 0)"
    }

    @discardableResult
    func send(_ cmd: String) -> Bool {
        if demoMode {
            if cmd == "raw" { rawText = DemoSource.rawText }
            if cmd.hasPrefix("car ") { carText = "Demo mode: connect to your MiniGauge to run this."; carBusy = false }
            return true
        }
        if isAdapter {
            lastNotice = "Connected to the OBD adapter, not the gauge: that needs the gauge."
            return false
        }
        let ok = link.send(cmd)
        if !ok { lastNotice = "Not connected to the gauge." }
        return ok
    }

    func runCarJob(_ n: Int) {
        carText = ""
        carBusy = true
        if !send("car \(n)") { carBusy = false }
    }

    private func startCarPoll() {
        carPoll?.invalidate()
        carPoll = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.send("cartext")
        }
        send("cartext")
    }

    func readCodes() {
        guard isAdapter else { send("codes"); return }
        adapter.readCodes { [weak self] r in
            switch r {
            case .success(let c): self?.adapter.setCodes(c)
            case .failure(let e): self?.lastNotice = "Adapter: \(e.text)"
            }
        }
    }

    @MainActor
    func clearCodes() async -> String? {
        guard isAdapter else { return await act("codes clear") }
        return await withCheckedContinuation { (cont: CheckedContinuation<String?, Never>) in
            adapter.clearCodes { e in cont.resume(returning: e.map { "Adapter: \($0.text)" }) }
        }
    }

    func clearNotice() { lastNotice = "" }

    // MARK: - logging

    func toggleLogging() {
        autoOwned = false
        if logger.isRunning { logger.stop(); logging = false }
        else { logger.start(); logging = true }
    }

    /// Automatic trip logs: one per engine run, like the gauge's own log.
    private func followEngine(_ rpm: Double?, at now: Date) {
        if demoMode { return }
        switch engineRun.update(rpm: rpm, at: now) {
        case .started?:
            if autoLog && !logging { logger.start(); logging = true; autoOwned = true }
        case .stopped?:
            if autoOwned && logging { logger.stop(); logging = false }
            autoOwned = false
        case nil: break
        }
    }

    // MARK: - requests (settings, layout, files: gauge_admin on the gauge)

    /// Send a command and wait for its reply body (nil: not connected, or no
    /// reply in time). The gauge answers each command with the command itself
    /// on the first line, which is how the reply finds its way back here.
    @MainActor
    func request(_ cmd: String, timeout: TimeInterval = 6) async -> String? {
        if demoMode { return DemoSource.adminReply(cmd) }
        return await withCheckedContinuation { (cont: CheckedContinuation<String?, Never>) in
            waiterSeq += 1
            let id = waiterSeq
            var finished = false
            let done: (String?) -> Void = { r in
                if finished { return }
                finished = true
                cont.resume(returning: r)
            }
            waiters[cmd, default: []].append((id, done))
            if !link.send(cmd) {
                waiters[cmd]?.removeAll { $0.id == id }
                done(nil)
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
                guard let self = self, let i = self.waiters[cmd]?.firstIndex(where: { $0.id == id }) else { return }
                let w = self.waiters[cmd]!.remove(at: i)
                if self.waiters[cmd]?.isEmpty == true { self.waiters[cmd] = nil }
                w.done(nil)
            }
        }
    }

    /// An action ("set ...", "slot ..."): nil when it worked, else why not.
    @MainActor
    func act(_ cmd: String) async -> String? { AdminReply.error(await request(cmd)) }

    @MainActor
    func fetch<T: Decodable>(_ type: T.Type, _ cmd: String) async -> T? { AdminReply.decode(type, await request(cmd)) }

    /// Copy a file from the gauge into Documents/Gauge (shown in the Files app).
    @MainActor
    func download(_ f: GaugeFile, progress: @escaping (Double) -> Void) async -> Result<URL, DownloadError> {
        var data = Data()
        var total = f.s
        while true {
            var chunk: (total: Int, data: Data)?
            for _ in 0..<3 {                                 // a lost Bluetooth chunk drops a reply: ask again
                if let body = await request("fget \(f.n) \(data.count)", timeout: 8) {
                    if let c = FileChunk.parse(body) { chunk = c; break }
                    return .failure(.gauge(AdminReply.error(body) ?? body))
                }
            }
            guard let c = chunk else { return .failure(.noReply) }
            total = c.total
            if c.data.isEmpty { break }
            data.append(c.data)
            progress(total > 0 ? min(Double(data.count) / Double(total), 1) : 1)
            if data.count >= total { break }
        }
        let url = Self.downloadFolder.appendingPathComponent(f.n)
        do { try data.write(to: url, options: .atomic) } catch { return .failure(.save(error.localizedDescription)) }
        return .success(url)
    }

    enum DownloadError: Error, Equatable {
        case noReply, gauge(String), save(String)
        var text: String {
            switch self {
            case .noReply: return "The gauge stopped answering."
            case .gauge(let s): return s
            case .save(let s): return "Couldn't save it: \(s)"
            }
        }
    }

    static var downloadFolder: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("Gauge", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Dyno car settings live on the gauge (the web page uses them too); the
    /// app keeps a copy for when it isn't connected.
    @MainActor
    func syncDynoCar() async {
        if let c = await fetch(DynoCarSettings.self, "dynocar"), c.settings != dyno { dyno = c.settings }
    }

    @MainActor
    func pushDynoCar() async -> String? { await act(DynoCarSettings(dyno).command) }

    // MARK: - Live Activity

    func activityState() -> GaugeActivityAttributes.ContentState {
        let s = snapshot
        let tiles = activityMetrics.prefix(4).map { m -> GaugeActivityAttributes.Tile in
            let r = s.reading(m)
            return GaugeActivityAttributes.Tile(label: m.short, value: r.value, unit: r.unit, level: s.level(m))
        }
        let linkText: String
        switch conn {
        case .connected: linkText = isAdapter ? "OBD adapter" : engine.link == .none ? "Gauge connected" : engine.link.title
        case .demo: linkText = "Demo"
        default: linkText = "Not connected"
        }
        let g = s.reading(.gear).value
        return GaugeActivityAttributes.ContentState(
            tiles: Array(tiles), gear: g == "--" ? "" : g, link: linkText,
            alarm: status.alarmLevel > 0 ? status.alarmText : "", alarmLevel: status.alarmLevel, updated: Date())
    }

    func startActivityNow() -> Bool { activity.startIfPossible(activityState()) }
    func endActivity() { activity.end() }
    var activityRunning: Bool { activity.isRunning }

    private func applyIdleTimer() {
        UIApplication.shared.isIdleTimerDisabled = keepAwake && isLive
    }
}
