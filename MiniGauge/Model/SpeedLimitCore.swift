import Foundation

// The road's speed limit, for the speed gauge's zones: OpenStreetMap's
// `maxspeed` tags, fetched a tile at a time from an Overpass server, and
// matched to where the car is and which way it's heading. Plain Foundation,
// unit-tested; SpeedLimitService does the GPS and the downloads.

/// What the owner chose (More → Settings → Speed limit). Margins in km/h.
struct LimitSettings: Codable, Equatable {
    var on = false
    var amberOverKmh = 8.04672        // 5 mph
    var redOverKmh = 16.09344         // 10 mph
    var amberAlarm = 0                // 0 colour only, 1 warning, 2 critical
    var redAlarm = 1
}

/// The gauge command for a limit ("limit off" when switched off).
enum LimitCommand {
    static func text(_ s: LimitSettings, limitKmh: Double?) -> String {
        guard s.on else { return "limit off" }
        let v = limitKmh.map { String(format: "%.1f", $0) } ?? "-1"
        return "limit v=\(v)&a=\(String(format: "%.2f", s.amberOverKmh))&r=\(String(format: "%.2f", max(s.redOverKmh, s.amberOverKmh)))&aa=\(s.amberAlarm)&ra=\(s.redAlarm)"
    }
}

enum MaxSpeed {
    /// An OSM maxspeed value in km/h: "45 mph" -> 72.4, "50" -> 50 (km/h is
    /// OSM's default unit); nil for "none", "signals", "walk", zone codes
    /// like "US:urban", or anything else that isn't a number.
    static func kmh(_ raw: String?) -> Double? {
        guard var s = raw?.trimmingCharacters(in: .whitespaces).lowercased(), !s.isEmpty else { return nil }
        if let semi = s.firstIndex(of: ";") { s = String(s[..<semi]) }      // "35 mph;45 mph": take the first
        var mph = false
        if s.hasSuffix("mph") { mph = true; s = String(s.dropLast(3)) }
        else if s.hasSuffix("km/h") { s = String(s.dropLast(4)) }
        else if s.hasSuffix("kmh") { s = String(s.dropLast(3)) }
        s = s.trimmingCharacters(in: .whitespaces)
        guard let v = Double(s), v > 0, v < 300 else { return nil }
        return mph ? v * 1.609344 : v
    }
}

/// One drivable road from OpenStreetMap.
struct Road: Codable, Equatable {
    let id: Int64
    let name: String?
    let highway: String
    let oneway: Int                   // 0 both ways, 1 along the way, -1 against it
    let fwd: Double?                  // limit along the way's direction, km/h
    let bwd: Double?                  // limit against it
    let pts: [[Double]]               // [lat, lon] in order

    var label: String { name ?? highway.replacingOccurrences(of: "_", with: " ") }
}

/// 0.02° squares (about 2.2 × 1.6 km here): downloaded and kept one at a time.
struct Tile: Hashable, Codable {
    static let size = 0.02
    let x: Int, y: Int
    init(x: Int, y: Int) { self.x = x; self.y = y }
    init(lat: Double, lon: Double) { x = Int(floor(lon / Self.size)); y = Int(floor(lat / Self.size)) }
    var south: Double { Double(y) * Self.size }
    var west: Double { Double(x) * Self.size }
    var north: Double { south + Self.size }
    var east: Double { west + Self.size }
    var key: String { "\(x)_\(y)" }

    /// This tile, plus the neighbours within `margin` degrees of the point.
    static func around(lat: Double, lon: Double, margin: Double = 0.004) -> [Tile] {
        var out: Set<Tile> = []
        for dy in [-margin, 0, margin] { for dx in [-margin, 0, margin] { out.insert(Tile(lat: lat + dy, lon: lon + dx)) } }
        return Array(out)
    }
}

enum Overpass {
    /// Volunteer servers: the main one first, then one without a rate limit.
    static let servers = ["https://overpass-api.de/api/interpreter", "https://overpass.private.coffee/api/interpreter"]
    static let kinds = "motorway|trunk|primary|secondary|tertiary|unclassified|residential|living_street|motorway_link|trunk_link|primary_link|secondary_link|tertiary_link"

    static func query(_ t: Tile) -> String {
        let b = String(format: "%.4f,%.4f,%.4f,%.4f", t.south, t.west, t.north, t.east)
        return "[out:json][timeout:25];way[\"highway\"~\"^(\(kinds))$\"](\(b));out tags geom;"
    }

    private struct Reply: Decodable { let elements: [Element] }
    private struct Element: Decodable {
        let type: String
        let id: Int64
        let tags: [String: String]?
        let geometry: [Point]?
    }
    private struct Point: Decodable { let lat: Double; let lon: Double }

    static func roads(_ data: Data) -> [Road]? {
        guard let r = try? JSONDecoder().decode(Reply.self, from: data) else { return nil }
        return r.elements.compactMap { e in
            guard e.type == "way", let g = e.geometry, g.count >= 2, let tags = e.tags, let hw = tags["highway"] else { return nil }
            let any = MaxSpeed.kmh(tags["maxspeed"])
            var oneway = 0
            switch tags["oneway"] {
            case "yes", "true", "1": oneway = 1
            case "-1", "reverse": oneway = -1
            default: if hw == "motorway" || tags["junction"] == "roundabout" { oneway = 1 }
            }
            return Road(id: e.id, name: tags["name"] ?? tags["ref"], highway: hw, oneway: oneway,
                        fwd: MaxSpeed.kmh(tags["maxspeed:forward"]) ?? any,
                        bwd: MaxSpeed.kmh(tags["maxspeed:backward"]) ?? any,
                        pts: g.map { [$0.lat, $0.lon] })
        }
    }
}

enum Geo {
    /// Metres east / north of an origin (flat-earth, fine over a few hundred metres).
    static func local(_ lat: Double, _ lon: Double, from lat0: Double, _ lon0: Double) -> (x: Double, y: Double) {
        let k = 111_320.0
        return ((lon - lon0) * k * cos(lat0 * .pi / 180), (lat - lat0) * k)
    }

    /// Distance from the origin to segment a-b (local metres), and where along it (0...1).
    static func toSegment(_ a: (x: Double, y: Double), _ b: (x: Double, y: Double)) -> (d: Double, t: Double) {
        let dx = b.x - a.x, dy = b.y - a.y
        let len2 = dx * dx + dy * dy
        let t = len2 > 0 ? min(max(-(a.x * dx + a.y * dy) / len2, 0), 1) : 0
        let px = a.x + t * dx, py = a.y + t * dy
        return ((px * px + py * py).squareRoot(), t)
    }

    /// Compass bearing of a-b, degrees (0 north, 90 east).
    static func bearing(_ a: (x: Double, y: Double), _ b: (x: Double, y: Double)) -> Double {
        let d = atan2(b.x - a.x, b.y - a.y) * 180 / .pi
        return d < 0 ? d + 360 : d
    }

    /// Smallest angle between two bearings, 0...180.
    static func angle(_ a: Double, _ b: Double) -> Double {
        let d = abs((a - b).truncatingRemainder(dividingBy: 360))
        return d > 180 ? 360 - d : d
    }
}

/// Which road the car is on, steadied so GPS jitter at a junction doesn't
/// flip between roads: a different road has to win twice in a row.
struct RoadMatcher {
    struct Match: Equatable {
        let road: Road
        let forward: Bool             // travelling along the way's direction
        let distance: Double
        var limitKmh: Double? { forward ? road.fwd : road.bwd }
    }

    private(set) var current: Match?
    private var challenger: Int64?
    private var challengerHits = 0
    private var misses = 0

    /// One GPS fix. `course` in degrees (nil or negative: unknown), `speed`
    /// m/s, `accuracy` metres. Returns the road the car is on, or nil.
    mutating func update(lat: Double, lon: Double, course: Double?, speed: Double, accuracy: Double, roads: [Road]) -> Match? {
        let heading = (course ?? -1) >= 0 && speed > 3 ? course : nil      // too slow: GPS course is noise
        let reach = min(max(25, accuracy * 1.5), 60)
        var best: (m: Match, score: Double)?
        var currentScore: Double?
        for r in roads {
            var bestHere: (m: Match, score: Double)?
            for i in 0..<(r.pts.count - 1) {
                let a = Geo.local(r.pts[i][0], r.pts[i][1], from: lat, lon)
                let b = Geo.local(r.pts[i + 1][0], r.pts[i + 1][1], from: lat, lon)
                let (d, _) = Geo.toSegment(a, b)
                guard d <= reach else { continue }
                let brg = Geo.bearing(a, b)
                var forward = true
                var penalty = 0.0
                if let h = heading {
                    let along = Geo.angle(h, brg), against = Geo.angle(h, brg + 180)
                    forward = along <= against
                    if r.oneway == 1 { forward = true } else if r.oneway == -1 { forward = false }
                    let off = forward ? along : against
                    if off > 50 { continue }                                 // a crossing road, or the wrong way on a one-way
                    penalty = off / 90 * 25
                } else if r.oneway == -1 {
                    forward = false
                }
                let s = d + penalty
                if bestHere == nil || s < bestHere!.score { bestHere = (Match(road: r, forward: forward, distance: d), s) }
            }
            guard let h = bestHere else { continue }
            if h.m.road.id == current?.road.id { currentScore = h.score }
            if best == nil || h.score < best!.score { best = h }
        }
        guard let b = best else {
            misses += 1
            if misses >= 2 { current = nil; challenger = nil }              // off every known road
            return current
        }
        misses = 0
        if let cs = currentScore, let cur = current {
            if b.m.road.id == cur.road.id || cs <= b.score + 8 {           // still on it (or close enough to it)
                challenger = nil
                current = Match(road: cur.road, forward: b.m.road.id == cur.road.id ? b.m.forward : cur.forward, distance: cs)
                return current
            }
        }
        if current == nil || currentScore == nil {                         // first fix, or the old road is out of reach
            current = b.m
            challenger = nil
            return current
        }
        // Another road scores clearly better: it has to do so twice running.
        if challenger == b.m.road.id { challengerHits += 1 } else { challenger = b.m.road.id; challengerHits = 1 }
        if challengerHits >= 2 {
            current = b.m
            challenger = nil
        }
        return current
    }

    mutating func reset() { current = nil; challenger = nil; challengerHits = 0; misses = 0 }
}

/// The speed gauge's zones while a limit is known (display units), as the
/// gauge firmware builds them (speed_limit.cpp): green up to limit + amber,
/// amber to limit + red, red above.
enum LimitZones {
    static func zones(limitKmh: Double, _ s: LimitSettings, toDisplay: (Double) -> Double, rangeMin: Double, rangeMax: Double) -> [GaugeInfo.Zone] {
        let L = toDisplay(limitKmh), A = L + toDisplay(s.amberOverKmh), R = L + toDisplay(max(s.redOverKmh, s.amberOverKmh))
        let top = max(rangeMax, R + 1)
        var z = [GaugeInfo.Zone(from: rangeMin, to: A, crit: false, color: "#35C759", z: 0, al: 0)]
        if R > A {
            z.append(GaugeInfo.Zone(from: A, to: R, crit: s.amberAlarm == 2, color: "#FFB020", z: 1, al: s.amberAlarm))
            z.append(GaugeInfo.Zone(from: R, to: top, crit: s.redAlarm == 2, color: "#FF2D55", z: 2, al: s.redAlarm))
        } else {
            z.append(GaugeInfo.Zone(from: A, to: top, crit: s.redAlarm == 2, color: "#FF2D55", z: 1, al: s.redAlarm))
        }
        return z
    }

    /// Which of those zones a value is in (the gauge's band rules).
    static func index(_ zs: [GaugeInfo.Zone], rangeMin: Double, _ v: Double) -> Int? {
        let d = zs.map { DirectData.Zone(from: $0.from, to: $0.to, color: $0.color, alarm: $0.al ?? 0) }
        return DirectData.zoneIndex(d, min: rangeMin, v)
    }
}
