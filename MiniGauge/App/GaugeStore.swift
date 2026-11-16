import Foundation
import SwiftUI
import UIKit

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
    @Published var autoLog: Bool { didSet { save("autoLog", autoLog) } }
    @Published var demoMode: Bool { didSet { save("demoMode", demoMode); restartSource() } }
    @Published var dyno: DynoSettings { didSet { if let d = try? JSONEncoder().encode(dyno) { UserDefaults.standard.set(d, forKey: "dyno") } } }
    @Published private(set) var logging = false

    private(set) var boost = BoostTracker()
    private let link = GaugeLink()
    private let activity = ActivityController()
    private let logger = TripLogger()
    private var demo = DemoSource()
    private var demoTimer: Timer?
    private var carPoll: Timer?
    private var lastHist = Date.distantPast
    private var started = false

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
        link.store = self
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
            link.start()
        }
    }

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
        send("info")
        if autoLog && !logging { toggleLogging() }
    }

    func linkDropped() {
        carBusy = false
        carPoll?.invalidate()
        engine.link = .none
        if logging { logger.flush() }
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
            lastFrame = Date()
            boost.update(e)
            let now = Date()
            if now.timeIntervalSince(lastHist) >= 0.25 {
                lastHist = now
                if let b = boost.boost(e) { boostHistory.append(b); if boostHistory.count > 240 { boostHistory.removeFirst() } }
                if let r = e[.rpm] { rpmHistory.append(r); if rpmHistory.count > 240 { rpmHistory.removeFirst() } }
            }
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
        default:
            if cmd.hasPrefix("car ") {
                if body == "started" { startCarPoll() } else { lastNotice = "Gauge: \(body)" }
            } else if !body.isEmpty {
                lastNotice = "Gauge: \(body)"
            }
        }
    }

    // MARK: - commands

    @discardableResult
    func send(_ cmd: String) -> Bool {
        if demoMode {
            if cmd == "raw" { rawText = DemoSource.rawText }
            if cmd.hasPrefix("car ") { carText = "Demo mode: connect to your MiniGauge to run this."; carBusy = false }
            return true
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

    func readCodes() { send("codes") }

    func clearNotice() { lastNotice = "" }

    // MARK: - logging

    func toggleLogging() {
        if logger.isRunning { logger.stop(); logging = false }
        else { logger.start(); logging = true }
    }

    // MARK: - Live Activity

    func activityState() -> GaugeActivityAttributes.ContentState {
        let s = snapshot
        let tiles = activityMetrics.prefix(4).map { m -> GaugeActivityAttributes.Tile in
            let r = s.reading(m)
            return GaugeActivityAttributes.Tile(label: m.short, value: r.value, unit: r.unit, level: s.level(m))
        }
        let linkText: String
        switch conn {
        case .connected: linkText = engine.link == .none ? "Gauge connected" : engine.link.title
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
