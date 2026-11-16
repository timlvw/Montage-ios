import Foundation

/// Made-up data shaped like a drive (idle, pulls through the gears, cruise),
/// for trying the app without the car. Plain Foundation.
struct DemoSource {
    private(set) var t: Double = 0
    private var seq: UInt16 = 0
    private var fuelTrip: Double = 0

    let ratios: [Double] = [3.308, 2.130, 1.483, 1.139, 0.949, 0.816]
    let rpmPerKph = (1000.0 / 60.0) / 1.93 * 3.94          // per gear ratio

    mutating func step(_ dt: Double) -> (EngineFrame, [GaugeSlotValue], StatusFrame) {
        t += dt
        seq &+= 1
        // 40 s cycle: 8 s idle, 12 s pull through 1-3, 20 s cruise in 5th
        let c = t.truncatingRemainder(dividingBy: 40)
        var rpm = 820.0, kph = 0.0, gear = 0, thr = 7.5, map = 34.0
        if c >= 8 && c < 20 {
            let k = (c - 8) / 4
            gear = min(3, Int(k) + 1)
            let f = k - floor(k)
            rpm = 2500 + f * 4300
            kph = rpm / (rpmPerKph * ratios[gear - 1])
            thr = 100
            map = 150 + f * 25
        } else if c >= 20 {
            gear = 5
            kph = 105 + 3 * sin(c)
            rpm = kph * rpmPerKph * ratios[4]
            thr = 22
            map = 62
        }
        let pull = thr > 90
        var e = EngineFrame()
        e.seq = seq
        e.link = .bmw
        e.tempF = true; e.speedMph = true; e.pressPsi = true
        e.blocksPerSec = 10.3
        e.dtcCount = 0
        e.milValid = true
        let ign = pull ? 17.25 : gear == 0 ? 12 : 28
        let knockCyl3 = pull && c > 16 && c < 19
        let fuel = pull ? 32.0 : gear == 0 ? 0.9 : 6.2
        fuelTrip += fuel * dt / 3600
        e.values = [
            .rpm: rpm.rounded(), .speed: kph, .gear: Double(gear), .map: map, .mapPre: pull ? 72 : 99,
            .coolant: 90 + 2 * sin(t / 30), .intake: pull ? 38 : 24, .throttle: thr, .pedal: pull ? 100 : thr * 0.8,
            .battery: 14.1, .load: pull ? 96 : 25, .o2Up: pull ? 870 : 450 + 350 * sin(t * 3), .o2Down: 640,
            .ign1: ign, .ign2: ign, .ign3: knockCyl3 ? ign - 3 : ign, .ign4: ign,
            .ret1: 0, .ret2: 0.4, .ret3: knockCyl3 ? 3 : 0, .ret4: 0,
            .knock: pull ? 1240 : 400, .slip: pull && gear == 1 ? 8.5 : 0.4,
            .wheelFL: kph * 1.01, .wheelFR: kph * 1.01, .fuel: fuel, .injDuty: pull ? 71 : 9, .injMs: pull ? 10.0 : 2.6,
            .airflow: pull ? 410 : 22, .lambda: -1.5, .trim: 3.0, .alternator: 42,
        ]
        let gauges = [
            GaugeSlotValue(slot: 0, pid: 0x0C, valid: true, warn: rpm > 6500, critical: false, value: rpm.rounded(), ageMs: 80),
            GaugeSlotValue(slot: 1, pid: 0x05, valid: true, warn: false, critical: false, value: (90 + 2 * sin(t / 30)) * 9 / 5 + 32, ageMs: 200),
            GaugeSlotValue(slot: 2, pid: 0x0D, valid: true, warn: false, critical: false, value: kph * 0.621371, ageMs: 100),
            GaugeSlotValue(slot: 3, pid: 0xE1, valid: true, warn: false, critical: false, value: (map - 99) * 0.145038, ageMs: 100),
        ]
        var s = StatusFrame()
        s.link = .bmw
        s.linkText = "Connected (BMW) - demo"
        s.pollsPerSec = 10
        s.fuelTripL = fuelTrip
        return (e, gauges, s)
    }

    static let info = GaugeInfo(
        v: 1, board: "Demo", build: "demo", units: .init(tempF: true, mph: true, psi: true),
        proto: "BMW (KWP2000)", pref: 0,
        slots: [
            .init(i: 0, pid: 0x0C, key: "rpm", name: "RPM", unit: "rpm", d: 0, min: 0, max: 7500,
                  zones: [.init(from: 6500, to: 7500, crit: true, color: "#FF2D55")]),
            .init(i: 1, pid: 0x05, key: "coolant", name: "Coolant", unit: "°F", d: 0, min: 100, max: 260,
                  zones: [.init(from: 230, to: 260, crit: true, color: "#FF2D55")]),
            .init(i: 2, pid: 0x0D, key: "speed", name: "Speed", unit: "mph", d: 0, min: 0, max: 140, zones: []),
            .init(i: 3, pid: 0xE1, key: "scboost", name: "Supercharger Boost", unit: "psi", d: 1, min: -14, max: 15,
                  zones: [.init(from: 13, to: 15, crit: false, color: "#FFB020")]),
        ])

    static let rawText = """
    Mode: BMW (KWP2000, tester F7) - demo
    Blocks/s: 10.3   gear scale 1.000

    LID 13 ENGINE4: temps, both MAPs, throttle, pedal, O2, battery
      24 bytes: 69 52 69 88 69 8F 00 32 00 17 10 79 10 09 10 00 00 00 00 96 00 53 66 66
      coolant 30.8 C, intake 13.5 C, MAP 98.9 kPa, before s/c 99.0 kPa (ratio 1.00)
    """
}
