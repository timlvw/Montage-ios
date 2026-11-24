import Foundation
import CoreLocation

/// Where the speed-limit lookup stands, for Settings and the Dash.
enum LimitStatus: Equatable {
    case off
    case noPermission                   // location refused for MiniGauge
    case waiting(String)                // GPS, or the roads here downloading
    case known(kmh: Double, road: String)
    case unknown(road: String?)         // on a road with no limit recorded, or none matched
    case offline                        // couldn't download the roads here

    func text(mph: Bool) -> String {
        switch self {
        case .off: return "Off"
        case .noPermission: return "Location is off for MiniGauge: allow it in iPhone Settings → MiniGauge → Location."
        case .waiting(let s): return s
        case .known(let k, let road): return "\(Self.format(k, mph: mph)) on \(road)"
        case .unknown(let road?): return "No limit recorded for \(road)"
        case .unknown(nil): return "Not on a known road"
        case .offline: return "Couldn't download the roads here (no signal, or the map server is busy)"
        }
    }

    static func format(_ kmh: Double, mph: Bool) -> String {
        mph ? "\(Int((kmh / 1.609344).rounded())) mph" : "\(Int(kmh.rounded())) km/h"
    }
}

/// Looks up the current road's speed limit (GPS + OpenStreetMap) and sends it
/// to the gauge ("limit ..."), so its speed gauges' zones follow it. Runs only
/// while the feature is on and the gauge (or the OBD adapter) is connected.
/// Roads are downloaded a tile at a time and kept on the phone for 30 days,
/// so a regular route needs no downloads at all.
final class SpeedLimitService: NSObject, CLLocationManagerDelegate {
    weak var store: GaugeStore?

    private var lm: CLLocationManager?
    private var running = false
    private var tiles: [Tile: [Road]] = [:]
    private var loading: Set<Tile> = []
    private var retryAfter: [Tile: Date] = [:]
    private var matcher = RoadMatcher()
    private var limit: Double?
    private var lastCommand = ""
    private var keepAlive: Timer?
    private var serverIdx = 0
    private var backoffUntil = Date.distantPast
    private static let keepDays: TimeInterval = 30 * 86_400

    // MARK: - on / off

    /// Start or stop to match the setting and the connection.
    func refresh() {
        guard let store = store else { return }
        let want = store.limitSettings.on && (store.conn == .connected || store.conn == .demo)
        if want && !running { start() }
        if !want && running { stop() }
        if !store.limitSettings.on { store.limitNow = .off }
    }

    /// Margins or alarms changed: tell the gauge at once.
    func settingsChanged() {
        lastCommand = ""
        if running { send() } else { refresh() }
        if store?.limitSettings.on == false { store?.sendLimit("limit off") }
    }

    /// The gauge (re)connected: it has forgotten the limit.
    func resend() {
        guard running, !lastCommand.isEmpty else { return }
        store?.sendLimit(lastCommand)
    }

    private func start() {
        running = true
        let m = lm ?? CLLocationManager()
        lm = m
        m.delegate = self
        m.desiredAccuracy = kCLLocationAccuracyBest
        m.distanceFilter = 10
        m.activityType = .automotiveNavigation
        m.pausesLocationUpdatesAutomatically = false
        switch m.authorizationStatus {
        case .notDetermined:
            store?.limitNow = .waiting("Asking for location…")
            m.requestWhenInUseAuthorization()
        case .denied, .restricted:
            store?.limitNow = .noPermission
        default:
            begin()
        }
    }

    private func begin() {
        guard running, let m = lm else { return }
        m.allowsBackgroundLocationUpdates = true          // keeps going with the phone locked (blue pill shows)
        m.showsBackgroundLocationIndicator = true
        m.startUpdatingLocation()
        if case .known? = store?.limitNow {} else { store?.limitNow = .waiting("Waiting for GPS…") }
        keepAlive?.invalidate()
        keepAlive = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in self?.resend() }
    }

    private func stop() {
        running = false
        lm?.stopUpdatingLocation()
        keepAlive?.invalidate()
        keepAlive = nil
        matcher.reset()
        limit = nil
        lastCommand = ""
        store?.sendLimit("limit off")
        store?.limitNow = store?.limitSettings.on == true ? .waiting("Waiting for the gauge…") : .off
    }

    // MARK: - location

    func locationManagerDidChangeAuthorization(_ m: CLLocationManager) {
        guard running else { return }
        switch m.authorizationStatus {
        case .denied, .restricted: store?.limitNow = .noPermission
        case .authorizedWhenInUse, .authorizedAlways: begin()
        default: break
        }
    }

    func locationManager(_ m: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard running, let loc = locations.last, loc.horizontalAccuracy >= 0, loc.horizontalAccuracy < 100 else { return }
        let lat = loc.coordinate.latitude, lon = loc.coordinate.longitude
        let need = Tile.around(lat: lat, lon: lon)
        for t in need where tiles[t] == nil { load(t) }
        let have = need.compactMap { tiles[$0] }
        if have.isEmpty {
            if !loading.isEmpty { store?.limitNow = .waiting("Downloading the roads here…") }
            else if need.allSatisfy({ retryAfter[$0] != nil }) { store?.limitNow = .offline; publish(nil) }
            return
        }
        let match = matcher.update(lat: lat, lon: lon, course: loc.course, speed: max(loc.speed, 0),
                                   accuracy: loc.horizontalAccuracy, roads: have.flatMap { $0 })
        publish(match)
        trimTiles(keeping: Set(need))
    }

    private func publish(_ m: RoadMatcher.Match?) {
        limit = m?.limitKmh
        if let m = m {
            store?.limitNow = m.limitKmh.map { .known(kmh: $0, road: m.road.label) } ?? .unknown(road: m.road.label)
        } else if case .offline? = store?.limitNow {
        } else {
            store?.limitNow = .unknown(road: nil)
        }
        send()
    }

    private func send() {
        guard let store = store else { return }
        let cmd = LimitCommand.text(store.limitSettings, limitKmh: limit)
        guard cmd != lastCommand else { return }
        lastCommand = cmd
        store.sendLimit(cmd)
    }

    // MARK: - roads

    private func cacheURL(_ t: Tile) -> URL? {
        guard let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        let dir = base.appendingPathComponent("roads", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(t.key + ".json")
    }

    private func load(_ t: Tile) {
        guard !loading.contains(t) else { return }
        if let ra = retryAfter[t], ra > Date() { return }
        if let url = cacheURL(t),
           let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let date = attrs[.modificationDate] as? Date, Date().timeIntervalSince(date) < Self.keepDays,
           let data = try? Data(contentsOf: url), let roads = try? JSONDecoder().decode([Road].self, from: data) {
            tiles[t] = roads
            return
        }
        guard Date() >= backoffUntil else { return }
        loading.insert(t)
        fetch(t, attempt: 0)
    }

    /// One tile from the Overpass servers: the one that worked last first,
    /// then the other; a busy or failed server is skipped for 30 s.
    private func fetch(_ t: Tile, attempt: Int) {
        let servers = Overpass.servers
        guard attempt < servers.count else {
            loading.remove(t)
            retryAfter[t] = Date().addingTimeInterval(60)
            backoffUntil = Date().addingTimeInterval(30)
            return
        }
        let i = (serverIdx + attempt) % servers.count
        guard let url = URL(string: servers[i]) else { return }
        var req = URLRequest(url: url, timeoutInterval: 30)
        req.httpMethod = "POST"
        req.setValue("MiniGauge/1.0 (personal car gauge app, iOS)", forHTTPHeaderField: "User-Agent")
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let q = Overpass.query(t).addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
        req.httpBody = ("data=" + q).data(using: .utf8)
        URLSession.shared.dataTask(with: req) { [weak self] data, resp, _ in
            DispatchQueue.main.async {
                guard let self = self else { return }
                let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                if code == 200, let d = data, let roads = Overpass.roads(d) {
                    self.serverIdx = i
                    self.loading.remove(t)
                    self.retryAfter[t] = nil
                    self.tiles[t] = roads
                    if let u = self.cacheURL(t), let enc = try? JSONEncoder().encode(roads) { try? enc.write(to: u) }
                } else {
                    self.fetch(t, attempt: attempt + 1)
                }
            }
        }.resume()
    }

    /// Keeps memory small on a long drive: only the tiles around the car stay loaded.
    private func trimTiles(keeping near: Set<Tile>) {
        guard tiles.count > 24 else { return }
        for k in tiles.keys where !near.contains(k) { tiles[k] = nil }
    }
}
