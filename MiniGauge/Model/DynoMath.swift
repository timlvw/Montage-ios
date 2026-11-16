import Foundation

/// Power from a recorded full-throttle pull, the same method as the gauge's
/// /dyno page: in one gear speed is proportional to rpm, acceleration comes
/// from a 5-point line fit, and power = (m a + drag + rolling) v.
/// An estimate for before/after comparisons on the same road, not a chassis dyno.
struct DynoSampleRow: Equatable {
    var t: Double        // s
    var rpm: Double
    var vs: Double       // km/h, vehicle speed
    var wh: Double       // km/h, front wheels (0 = none)
    var map: Double      // kPa
    var ax: Double       // g, gauge's own accelerometer
    var gear: Int
}

struct DynoSettings: Equatable, Codable {
    var massKg: Double = 1300
    var cdA: Double = 0.68
    var crr: Double = 0.012
    var lossPct: Double = 15
}

struct DynoPoint: Equatable, Identifiable {
    var rpm: Double
    var wheelHp: Double
    var crankHp: Double
    var imuHp: Double
    var torqueLbft: Double
    var id: Double { rpm }
}

struct DynoResult: Equatable {
    var gear: Int
    var speedSource: String
    var points: [DynoPoint]
    var peakHp: Double
    var peakHpRpm: Double
    var peakTq: Double
    var peakTqRpm: Double
    var hasImu: Bool
}

struct DynoTime: Equatable, Identifiable {
    var name: String
    var seconds: Double?
    var id: String { name }
}

enum DynoMath {
    static func parseCSV(_ text: String) -> [DynoSampleRow] {
        var rows: [DynoSampleRow] = []
        for (i, line) in text.split(separator: "\n").enumerated() where i > 0 {
            let a = line.split(separator: ",").map { Double($0.trimmingCharacters(in: .whitespaces)) ?? 0 }
            guard a.count >= 7 else { continue }
            rows.append(DynoSampleRow(t: a[0] / 1000, rpm: a[1], vs: a[2] / 10, wh: a[3] / 10, map: a[4] / 10,
                                      ax: a[5] / 100, gear: Int(a[6])))
        }
        return rows
    }

    /// Least squares y = b x + a. Returns (b, a).
    static func linfit(_ xs: [Double], _ ys: [Double]) -> (Double, Double) {
        let n = Double(xs.count)
        var sx = 0.0, sy = 0.0, sxx = 0.0, sxy = 0.0
        for i in 0..<xs.count { sx += xs[i]; sy += ys[i]; sxx += xs[i] * xs[i]; sxy += xs[i] * ys[i] }
        let d = n * sxx - sx * sx
        if abs(d) < 1e-9 { return (0, n > 0 ? sy / n : 0) }
        let b = (n * sxy - sx * sy) / d
        return (b, (sy - b * sx) / n)
    }

    enum Failure: Error, Equatable { case tooFew, noGear, notAccelerating }

    static func compute(_ s: [DynoSampleRow], _ cfg: DynoSettings) -> Result<DynoResult, Failure> {
        guard s.count >= 8 else { return .failure(.tooFew) }
        var count: [Int: Int] = [:]
        for r in s where r.gear > 0 && r.rpm > 1500 { count[r.gear, default: 0] += 1 }
        guard let gear = count.max(by: { $0.value < $1.value || ($0.value == $1.value && $0.key > $1.key) })?.key else {
            return .failure(.noGear)
        }
        let p = s.filter { $0.gear == gear && $0.rpm > 1200 }
        guard p.count >= 8 else { return .failure(.noGear) }
        let useWheels = p.contains { $0.wh > 0 }
        let c = linfit(p.map(\.rpm), p.map { useWheels ? $0.wh : $0.vs }).0
        let rho = 1.2, g = 9.81, loss = cfg.lossPct / 100
        var out: [DynoPoint] = []
        if p.count >= 5 {
            for i in 2..<(p.count - 2) {
                let w = p[(i - 2)...(i + 2)]
                let a = linfit(w.map(\.t), w.map { $0.rpm * c / 3.6 }).0
                let v = p[i].rpm * c / 3.6
                if a <= 0.05 { continue }
                let road = 0.5 * rho * cfg.cdA * v * v + cfg.crr * cfg.massKg * g
                let pw = (cfg.massKg * a + road) * v
                let pimu = (cfg.massKg * p[i].ax * g + road) * v
                let crankW = pw / (1 - loss)
                out.append(DynoPoint(rpm: p[i].rpm, wheelHp: pw / 745.7, crankHp: crankW / 745.7, imuHp: pimu / 745.7,
                                     torqueLbft: crankW / (p[i].rpm * 2 * .pi / 60) * 0.737562))
            }
        }
        guard out.count >= 4 else { return .failure(.notAccelerating) }
        // light smoothing, 3 points
        func smooth(_ k: KeyPath<DynoPoint, Double>) -> [Double] {
            out.indices.map { i in
                let w = out[max(0, i - 1)...min(out.count - 1, i + 1)]
                return w.reduce(0) { $0 + $1[keyPath: k] } / Double(w.count)
            }
        }
        let whp = smooth(\.wheelHp), chp = smooth(\.crankHp), tq = smooth(\.torqueLbft), imu = smooth(\.imuHp)
        var pts: [DynoPoint] = []
        for i in out.indices {
            pts.append(DynoPoint(rpm: out[i].rpm, wheelHp: whp[i], crankHp: chp[i], imuHp: imu[i], torqueLbft: tq[i]))
        }
        let ih = chp.indices.max { chp[$0] < chp[$1] }!
        let it = tq.indices.max { tq[$0] < tq[$1] }!
        return .success(DynoResult(gear: gear, speedSource: useWheels ? "front wheel speeds" : "vehicle speed", points: pts,
                                   peakHp: chp[ih], peakHpRpm: pts[ih].rpm, peakTq: tq[it], peakTqRpm: pts[it].rpm,
                                   hasImu: p.contains { $0.ax != 0 }))
    }

    /// 0-60 style times. 0-x only when the run starts from a stop.
    static func times(_ s: [DynoSampleRow]) -> (fromStop: Bool, rows: [DynoTime]) {
        let sp = s.map { (t: $0.t, v: $0.wh > 0 ? $0.wh : $0.vs) }
        func cross(_ v: Double) -> Double? {
            guard sp.count > 1 else { return nil }
            for i in 1..<sp.count where sp[i - 1].v < v && sp[i].v >= v {
                return sp[i - 1].t + (v - sp[i - 1].v) / (sp[i].v - sp[i - 1].v) * (sp[i].t - sp[i - 1].t)
            }
            return nil
        }
        let fromStop = (sp.first?.v ?? 99) < 3
        let defs: [(String, Double, Double)] = [("0-60 mph", 0, 96.56), ("0-100 km/h", 0, 100), ("30-70 mph", 48.28, 112.65),
                                                 ("50-100 km/h", 50, 100), ("60-100 mph", 96.56, 160.93)]
        var rows: [DynoTime] = []
        for (name, lo, hi) in defs where lo > 0 || fromStop {
            var a: Double?
            if lo == 0 {
                if let k = sp.firstIndex(where: { $0.v > 0.5 }) { a = sp[max(0, k - 1)].t }
            } else {
                a = cross(lo)
            }
            let b = cross(hi)
            if let a = a, let b = b, b > a { rows.append(DynoTime(name: name, seconds: b - a)) }
            else { rows.append(DynoTime(name: name, seconds: nil)) }
        }
        return (fromStop, rows)
    }
}
