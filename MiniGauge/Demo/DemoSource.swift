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
            .airflow: pull ? 410 : 22, .lambda: -1.5, .trim: 3.0, .fuelLevel: 34,
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

// Demo replies for the settings, layout and file screens (no gauge needed).
extension DemoSource {
    static func adminReply(_ cmd: String) -> String? {
        switch cmd {
        case "settings":
            return #"{"tempF":true,"speedMph":true,"pressPsi":true,"logAuto":true,"logActive":true,"logFile":"log_20261118-071502.csv","recOn":true,"recActive":true,"recFile":"drive_20261118-071455.txt","engine":true,"transport":1,"klproto":0,"klmode":"BMW (KWP2000)","klpins":0,"klpinsNow":0,"freeKB":5210,"totalKB":10048}"#
        case "config":
            return #"{"apMode":true,"ssid":"","tempF":true,"speedMph":true,"pressPsi":true,"slots":["# +
                #"{"en":true,"pid":12,"min":0.0,"max":8000.0,"ticks":9,"major":2,"dec":-1,"label":"","emblem":0,"emtext":"","needle":"FF2D55","bg":"000000","text":"FFFFFF","arc":"00E5FF","emcol":"FFFFFF","z":[{"on":true,"from":6800.0,"to":8000.0,"col":"FF2D55"},{"on":false,"from":0.0,"to":0.0,"col":"FFB020"}]},"# +
                #"{"en":true,"pid":225,"min":-15.0,"max":15.0,"ticks":7,"major":1,"dec":1,"label":"Boost","emblem":0,"emtext":"","needle":"FF2D55","bg":"000000","text":"FFFFFF","arc":"00E5FF","emcol":"FFFFFF","z":[{"on":true,"from":13.0,"to":15.0,"col":"FF2D55"},{"on":false,"from":0.0,"to":0.0,"col":"FFB020"}]},"# +
                #"{"en":true,"pid":5,"min":104.0,"max":266.0,"ticks":9,"major":2,"dec":-1,"label":"","emblem":0,"emtext":"","needle":"FF2D55","bg":"000000","text":"FFFFFF","arc":"00E5FF","emcol":"FFFFFF","z":[{"on":true,"from":230.0,"to":266.0,"col":"FF2D55"},{"on":false,"from":0.0,"to":0.0,"col":"FFB020"}]},"# +
                #"{"en":true,"pid":15,"min":32.0,"max":212.0,"ticks":9,"major":2,"dec":-1,"label":"","emblem":0,"emtext":"","needle":"FF2D55","bg":"000000","text":"FFFFFF","arc":"00E5FF","emcol":"FFFFFF","z":[{"on":false,"from":0.0,"to":0.0,"col":"FF2D55"},{"on":false,"from":0.0,"to":0.0,"col":"FFB020"}]}"# +
                #"],"combo":[0,1,2,3]}"#
        case "pids":
            return #"[{"pid":12,"key":"rpm","name":"Engine RPM","unit":"rpm","min":0,"max":8000,"sup":true},{"pid":13,"key":"speedkph","name":"Speed","unit":"mph","min":0,"max":160,"sup":true},{"pid":5,"key":"coolant","name":"Coolant Temp","unit":"F","min":40,"max":130,"sup":true},{"pid":15,"key":"iat","name":"Intake Air Temp","unit":"F","min":-20,"max":80,"sup":true},{"pid":225,"key":"boost","name":"S/C Boost","unit":"psi","min":-100,"max":100,"sup":true},{"pid":237,"key":"fueltank","name":"Fuel in Tank","unit":"gal","min":0,"max":50,"sup":true}]"#
        case "themes":
            return #"[{"t":0,"n":"Night","needle":"FF2D55","bg":"000000","text":"FFFFFF","arc":"00E5FF"}]"#
        case "files":
            return #"{"freeKB":5210,"totalKB":10048,"files":[{"n":"drive_20261118-071455.txt","s":1934211,"busy":"rec"},{"n":"log_20261118-071502.csv","s":402113,"busy":"log"},{"n":"drive_20261117-162205.txt","s":787712,"busy":""},{"n":"log_20261117-164524.csv","s":397926,"busy":""},{"n":"dyno_20261117-165012.csv","s":9411,"busy":""},{"n":"dyno_20261117-164801.csv","s":10212,"busy":""}]}"#
        case "dynocar":
            return #"{"mass":1300,"cda":0.680,"crr":0.0120,"loss":15.0}"#
        default:
            if cmd.hasPrefix("fget ") {
                let csv = "t_ms,rpm,vs10,wh10,map10,ax100,gear\n" + (0..<120).map { i in
                    let rpm = 2000 + i * 38
                    return "\(i * 70),\(rpm),\(Int(Double(rpm) / 47.9 * 10)),\(Int(Double(rpm) / 47.9 * 10 + 3)),\(1300 + i * 4),\(32 - i / 8),3"
                }.joined(separator: "\n") + "\n"
                return "\(csv.utf8.count)\n" + csv
            }
            return "ok"
        }
    }
}
