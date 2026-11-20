import XCTest
@testable import MiniGauge

// The gauge's settings / layout / file replies, exactly as the firmware's
// gauge_admin.cpp writes them (taken from its host test), plus the helpers
// that build commands and follow the engine.
final class AdminTests: XCTestCase {
    func testSettingsFromTheGauge() throws {
        let j = #"{"tempF":true,"speedMph":false,"pressPsi":false,"logAuto":false,"logActive":false,"logFile":"log_0002.csv","recOn":false,"recActive":false,"recFile":"drive_20261118-120000.txt","engine":false,"transport":1,"klproto":2,"klmode":"BMW (KWP2000)","klpins":1,"klpinsNow":0,"freeKB":4882,"totalKB":9765}"#
        let s = try XCTUnwrap(AdminReply.decode(GaugeSettings.self, j))
        XCTAssertTrue(s.tempF)
        XCTAssertFalse(s.logAuto)
        XCTAssertEqual(s.klproto, 2)
        XCTAssertEqual(s.recFile, "drive_20261118-120000.txt")
        XCTAssertTrue(s.restartNeeded, "wiring saved as header pins, UART in use: needs a restart")
        XCTAssertNil(s.klpinNames, "older firmware sends no names")
        XCTAssertEqual(s.wiringName(1), "Header pins (17/18)")
    }

    func testWiringNamesFromTheLcd21() throws {
        let j = #"{"tempF":false,"speedMph":false,"pressPsi":false,"logAuto":true,"logActive":false,"logFile":"","recOn":true,"recActive":false,"recFile":"","engine":false,"transport":1,"klproto":0,"klmode":"","klpins":1,"klpinsNow":1,"klpinNames":["UART header RXD / TXD (not with USB-C power)","12-pin header D- / D+"],"freeKB":1,"totalKB":2}"#
        let s = try XCTUnwrap(AdminReply.decode(GaugeSettings.self, j))
        XCTAssertEqual(s.wiringName(0), "UART header RXD / TXD (not with USB-C power)")
        XCTAssertEqual(s.wiringName(1), "12-pin header D- / D+")
        XCTAssertFalse(s.restartNeeded)
    }

    func testWifiSwitchedOffPendingRestart() throws {
        // gauge_admin.cpp's host test after "set wifi=0": saved off, still on this boot
        let j = #"{"tempF":true,"speedMph":false,"pressPsi":false,"wifi":false,"wifiNow":true,"logAuto":false,"logActive":false,"logFile":"log_0002.csv","recOn":false,"recActive":false,"recFile":"drive_20261118-120000.txt","engine":false,"transport":1,"klproto":2,"klmode":"BMW (KWP2000)","klpins":1,"klpinsNow":0,"klpinNames":["UART connector RXD / TXD","Header pins 17 / 18"],"freeKB":4882,"totalKB":9765}"#
        let s = try XCTUnwrap(AdminReply.decode(GaugeSettings.self, j))
        XCTAssertEqual(s.wifi, false)
        XCTAssertTrue(s.wifiRestartNeeded)
        var t = s; t.wifiNow = false
        XCTAssertFalse(t.wifiRestartNeeded, "off and already off this boot")
        let old = try XCTUnwrap(AdminReply.decode(GaugeSettings.self, #"{"tempF":true,"speedMph":false,"pressPsi":false,"logAuto":false,"logActive":false,"logFile":"","recOn":false,"recActive":false,"recFile":"","engine":false,"transport":1,"klproto":0,"klmode":"","klpins":0,"klpinsNow":0,"freeKB":1,"totalKB":2}"#))
        XCTAssertNil(old.wifi, "older firmware: no Wi-Fi switch shown")
        XCTAssertFalse(old.wifiRestartNeeded)
    }

    func testFourZones() throws {
        // gauge_admin.cpp's host test after "zones=3&z1al=1&z2al=0 ..." (v5.12)
        let j = #"{"apMode":false,"ssid":"","tempF":true,"speedMph":false,"pressPsi":false,"slots":[{"en":true,"pid":5,"min":40.0,"max":130.0,"ticks":9,"major":2,"dec":-1,"label":"","emblem":0,"emtext":"","needle":"00FF00","bg":"000000","text":"000000","arc":"000000","emcol":"000000","z":[{"on":true,"from":110.0,"to":130.0,"col":"FF0000","al":2},{"on":true,"from":100.0,"to":110.0,"col":"FFB020","al":1},{"on":true,"from":40.0,"to":70.0,"col":"3A8DFF","al":0},{"on":false,"from":0.0,"to":0.0,"col":"3A8DFF","al":0}]}],"combo":[0,-1,-1,-1]}"#
        var c = try XCTUnwrap(AdminReply.decode(GaugeConfig.self, j))
        XCTAssertEqual(c.slots[0].z.count, 4)
        XCTAssertEqual(c.slots[0].zoneCount, 3)
        XCTAssertEqual(c.slots[0].alarm(2), 0)
        c.slots[0].zoneCount = 1
        XCTAssertEqual(c.slots[0].z.map(\.on), [true, false, false, false])
        XCTAssertEqual(c.slots[0].z[2].from, 40, "fewer zones keeps their values")
        XCTAssertNil(c.slots[0].zsaved, "firmware without default zones: no buttons")
        let d = try XCTUnwrap(AdminReply.decode(GaugeConfig.self, j.replacingOccurrences(of: #""emcol":"000000","#, with: #""emcol":"000000","zsaved":true,"#)))
        XCTAssertEqual(d.slots[0].zsaved, true)
        // older firmware: two zones, no alarm field
        let old = try XCTUnwrap(AdminReply.decode(GaugeConfig.self, #"{"apMode":false,"ssid":"","tempF":true,"speedMph":false,"pressPsi":false,"slots":[{"en":true,"pid":5,"min":40.0,"max":130.0,"ticks":9,"major":2,"dec":-1,"label":"","emblem":0,"emtext":"","needle":"00FF00","bg":"000000","text":"000000","arc":"000000","emcol":"000000","z":[{"on":true,"from":110.0,"to":130.0,"col":"FF0000"},{"on":true,"from":100.0,"to":110.0,"col":"FFB020"}]}],"combo":[0,-1,-1,-1]}"#))
        XCTAssertNil(old.slots[0].z[0].al)
        XCTAssertEqual(old.slots[0].alarm(0), 2)
        XCTAssertEqual(old.slots[0].alarm(1), 1)
    }

    func testConfigWithEscapedLabel() throws {
        let j = #"{"apMode":false,"ssid":"","tempF":true,"speedMph":false,"pressPsi":false,"slots":[{"en":true,"pid":5,"min":40.0,"max":130.0,"ticks":9,"major":2,"dec":-1,"label":"Water \"temp\"","emblem":0,"emtext":"","needle":"00FF00","bg":"000000","text":"FFFFFF","arc":"00E5FF","emcol":"FFFFFF","z":[{"on":true,"from":110.0,"to":130.0,"col":"FF0000"},{"on":false,"from":0.0,"to":0.0,"col":"FFB020"}]}],"combo":[0,-1,-1,-1]}"#
        let c = try XCTUnwrap(AdminReply.decode(GaugeConfig.self, j))
        XCTAssertEqual(c.slots.count, 1)
        XCTAssertEqual(c.slots[0].label, "Water \"temp\"")
        XCTAssertEqual(c.slots[0].z[0].col, "FF0000")
        XCTAssertEqual(c.combo, [0, -1, -1, -1])
    }

    func testFilesThemesDynoCarPids() throws {
        let files = try XCTUnwrap(AdminReply.decode(GaugeFiles.self, #"{"freeKB":4882,"totalKB":9765,"files":[{"n":"dyno_20261118-130840.csv","s":3404,"busy":""},{"n":"bmwtest.txt","s":6,"busy":""},{"n":"drive_20261118-120000.txt","s":5,"busy":"rec"},{"n":"log_0001.csv","s":668890,"busy":""},{"n":"dyno_0001.csv","s":8735,"busy":""}]}"#))
        XCTAssertEqual(files.files.map(\.kind), [.dyno, .other, .drive, .log, .dyno])
        XCTAssertEqual(files.files[0].title, "2026-11-18 13:08")
        XCTAssertEqual(files.files[3].title, "No. 1")
        XCTAssertEqual(files.files[1].title, "bmwtest")
        XCTAssertEqual(GaugeFile(n: "drive_20261117-162205-2.txt", s: 1, busy: "").title, "2026-11-17 16:22 (2)")
        XCTAssertEqual(files.files[2].busy, "rec")

        let themes = try XCTUnwrap(AdminReply.decode([ThemeInfo].self, #"[{"t":0,"n":"Night","needle":"000000","bg":"000000","text":"000000","arc":"000000"}]"#))
        XCTAssertEqual(themes.first?.n, "Night")

        let car = try XCTUnwrap(AdminReply.decode(DynoCarSettings.self, #"{"mass":1250,"cda":0.700,"crr":0.0110,"loss":13.0}"#))
        XCTAssertEqual(car.settings, DynoSettings(massKg: 1250, cdA: 0.7, crr: 0.011, lossPct: 13))
        XCTAssertEqual(car.command, "dynocar mass=1250&cda=0.700&crr=0.0110&loss=13.0")

        let pids = try XCTUnwrap(AdminReply.decode([PidInfo].self, #"[{"pid":4,"key":"load","name":"Engine Load","unit":"%","min":0,"max":100,"sup":true},{"pid":237,"key":"fueltank","name":"Fuel in Tank","unit":"L","min":0,"max":50,"sup":false}]"#))
        XCTAssertEqual(pids.map(\.pid), [4, 237])
    }

    func testReplies() {
        XCTAssertNil(AdminReply.error("ok"))
        XCTAssertEqual(AdminReply.error("error: bad slot index"), "bad slot index")
        XCTAssertEqual(AdminReply.error(nil), "No reply from the gauge.")
        XCTAssertNil(AdminReply.decode(GaugeSettings.self, "error: nope"))
    }

    func testQueryEncodingAndSplitting() {
        XCTAssertEqual(AdminQuery.encode([("i", "2"), ("label", "Boost pre, S/C & more")]), "i=2&label=Boost%20pre%2C%20S%2FC%20%26%20more")
        let pairs: [(String, String)] = (0..<30).map { ("k\($0)", "value\($0)") }
        let cmds = AdminQuery.commands("slot", fixed: [("i", "3")], pairs: pairs)
        XCTAssertGreaterThan(cmds.count, 1)
        for c in cmds {
            XCTAssertLessThanOrEqual(c.count, 190)
            XCTAssertTrue(c.hasPrefix("slot i=3&"))
        }
        XCTAssertEqual(cmds.joined().components(separatedBy: "=value").count - 1, 30, "every pair sent once")
        XCTAssertEqual(AdminQuery.commands("slot", fixed: [("i", "0")], pairs: []), ["slot i=0"])
    }

    func testFileChunk() throws {
        let c = try XCTUnwrap(FileChunk.parse("120\nt_ms,rpm\n0,1000\n"))
        XCTAssertEqual(c.total, 120)
        XCTAssertEqual(String(decoding: c.data, as: UTF8.self), "t_ms,rpm\n0,1000\n")
        let end = try XCTUnwrap(FileChunk.parse("120\n"))
        XCTAssertTrue(end.data.isEmpty)
        XCTAssertNil(FileChunk.parse("error: no such file"))
    }

    func testEngineRunDetector() {
        var d = EngineRunDetector()
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        func at(_ s: Double) -> Date { t0.addingTimeInterval(s) }
        XCTAssertNil(d.update(rpm: 0, at: at(0)), "key on, engine off")
        XCTAssertNil(d.update(rpm: 900, at: at(1)))
        XCTAssertNil(d.update(rpm: 900, at: at(2.5)), "not 2 s yet")
        XCTAssertEqual(d.update(rpm: 850, at: at(3.1)), .started)
        XCTAssertNil(d.update(rpm: 850, at: at(4)))
        XCTAssertNil(d.update(rpm: 0, at: at(10)), "stalled")
        XCTAssertNil(d.update(rpm: 800, at: at(20)), "restarted within 30 s: same run")
        XCTAssertNil(d.update(rpm: nil, at: at(25)), "link gap starts the stop timer")
        XCTAssertNil(d.update(rpm: nil, at: at(54)))
        XCTAssertEqual(d.update(rpm: nil, at: at(55.1)), .stopped)
        XCTAssertFalse(d.running)
        XCTAssertNil(d.update(rpm: 0, at: at(70)))
    }
}
