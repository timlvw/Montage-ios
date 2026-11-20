import XCTest
@testable import MiniGauge

// Direct-to-adapter mode: ELM327 replies, OBD decoding, the session's
// wake-up / polling / retry logic, and the frames DirectData makes.
final class ElmTests: XCTestCase {
    func testReplyLines() {
        XCTAssertEqual(ElmReply.lines("SEARCHING...\r41 0C 1A F8\r\r>"), ["41 0C 1A F8"])
        XCTAssertEqual(ElmReply.lines("010C\r410C1AF8\r\r", sent: "010C"), ["410C1AF8"], "echo dropped")
        XCTAssertEqual(ElmReply.lines("BUS INIT: ...OK\r41 00 BE 1F A8 13\r"), ["41 00 BE 1F A8 13"])
        XCTAssertEqual(ElmReply.lines("BUS INIT: ...\rOK\r41 00 BE 1F A8 13"), ["OK", "41 00 BE 1F A8 13"])
        XCTAssertEqual(ElmReply.error(ElmReply.lines("NO DATA\r\r")), .noData)
        XCTAssertEqual(ElmReply.error(ElmReply.lines("BUS INIT: ...ERROR\r")), .busInit)
        XCTAssertEqual(ElmReply.error(ElmReply.lines("UNABLE TO CONNECT\r")), .unableToConnect)
        XCTAssertEqual(ElmReply.error(["?"]), .unknownCommand)
        XCTAssertEqual(ElmReply.error([]), .noData)
        XCTAssertNil(ElmReply.error(["41 0C 1A F8"]))
        XCTAssertEqual(ElmReply.bytes("41 0C 1A F8"), [0x41, 0x0C, 0x1A, 0xF8])
        XCTAssertNil(ElmReply.bytes("NO DATA"))
    }

    func testDecode() {
        XCTAssertEqual(ObdDecode.value(0x0C, ["41 0C 1A F8"])!, 1726, accuracy: 0.01)
        XCTAssertEqual(ObdDecode.value(0x05, ["41057B"])!, 83)
        XCTAssertEqual(ObdDecode.value(0x0B, ["41 0B BE"])!, 190)
        XCTAssertEqual(ObdDecode.value(0x0D, ["41 0D 64"])!, 100)
        XCTAssertEqual(ObdDecode.value(0x11, ["41 11 FF"])!, 100, accuracy: 0.01)
        XCTAssertEqual(ObdDecode.value(0x06, ["41 06 70"])!, -12.5, accuracy: 0.01)
        XCTAssertEqual(ObdDecode.value(0x14, ["41 14 5A FF"])!, 0.45, accuracy: 0.001)
        XCTAssertEqual(ObdDecode.value(0x42, ["41 42 31 2C"])!, 12.588, accuracy: 0.001)
        XCTAssertNil(ObdDecode.value(0x0C, ["41 0D 64"]), "a reply to another PID")
        let s = ObdDecode.supported(0x00, ["41 00 BE 1F A8 13"])!
        XCTAssertEqual(s, [0x01, 0x03, 0x04, 0x05, 0x06, 0x07, 0x0C, 0x0D, 0x0E, 0x0F, 0x10, 0x11, 0x13, 0x15, 0x1C, 0x1F, 0x20])
        XCTAssertEqual(ObdDecode.status(["41 01 83 07 65 04"])?.mil, true)
        XCTAssertEqual(ObdDecode.status(["41 01 83 07 65 04"])?.count, 3)
        XCTAssertEqual(ObdDecode.codes(["43 01 33 00 00 00 00"]), ["P0133"])
        XCTAssertEqual(ObdDecode.codes(["43 01 30 01 28 C1 23", "43 00 00 00 00 00 00"]), ["P0130", "P0128", "U0123"])
        XCTAssertEqual(ObdDecode.codes(["43 00 00 00 00 00 00"]), [])
        XCTAssertEqual(ObdDecode.volts(["12.6V"])!, 12.6, accuracy: 0.001)
    }

    /// Plays the adapter: answers each command the session sends.
    private final class FakeAdapter {
        var sent: [String] = []
        var values: [UInt8: Double] = [:]
        var status: (Bool, Int)?
        var states: [ElmSession.State] = []
        var retries: [TimeInterval] = []
        var worked: String?
        var clock = Date(timeIntervalSince1970: 1_000_000)
        let s: ElmSession
        init(_ first: String? = nil) {
            s = ElmSession(protocolFirst: first)
            s.send = { [unowned self] c, _ in self.sent.append(c) }
            s.gotValue = { [unowned self] p, v in self.values[p] = v }
            s.gotStatus = { [unowned self] m, n in self.status = (m, n) }
            s.stateChanged = { [unowned self] st in self.states.append(st) }
            s.retryLater = { [unowned self] t in self.retries.append(t) }
            s.protocolWorked = { [unowned self] p in self.worked = p }
            s.now = { [unowned self] in self.clock }
        }
        var last: String { sent.last ?? "" }
        func reply(_ r: String) { s.received(r) }
        func okUntil(_ cmd: String) { while last != cmd && last.hasPrefix("AT") { reply("OK") } }
    }

    func testWakeAndPoll() {
        let a = FakeAdapter()
        a.s.start()
        XCTAssertEqual(a.last, "ATZ")
        a.reply("\r\rELM327 v1.5\r")
        a.okUntil("0100")
        XCTAssertEqual(Array(a.sent.prefix(8)), ["ATZ", "ATE0", "ATL0", "ATS0", "ATH0", "ATAT1", "ATSP3", "0100"], "ISO 9141-2 first")
        XCTAssertEqual(a.s.state, .waking("3"))
        a.reply("BUS INIT: ...OK\r41 00 BE 3E B8 11\r")
        XCTAssertEqual(a.s.state, .running("3"))
        XCTAssertEqual(a.worked, "3")
        XCTAssertEqual(a.last, "0120", "PID 0x20 supported: ask for the next page")
        a.reply("41 20 00 00 00 01")
        XCTAssertEqual(a.last, "0140")
        a.reply("41 40 40 00 00 00")
        XCTAssertTrue(a.s.supported.contains(0x42))
        XCTAssertEqual(a.last, "0101")
        a.reply("41 01 00 07 65 00")
        XCTAssertEqual(a.status?.0, false)
        XCTAssertEqual(a.status?.1, 0)
        // the fast four, then one slow
        var polled: [String] = []
        let answers = ["010C": "41 0C 1A F8", "010D": "41 0D 30", "010B": "41 0B 64", "0111": "41 11 33", "0105": "41 05 82",
                       "010F": "41 0F 3C", "0104": "41 04 40", "0142": "41 42 36 B0", "0106": "41 06 80", "0107": "41 07 82",
                       "0114": "41 14 5A FF", "0115": "41 15 80 FF"]
        for _ in 0..<10 {
            polled.append(a.last)
            a.reply(answers[a.last] ?? "NO DATA")
        }
        XCTAssertEqual(Array(polled.prefix(5)), ["010C", "010D", "010B", "0111", "0105"])
        XCTAssertEqual(Array(polled[5..<10]), ["010C", "010D", "010B", "0111", "010F"])
        XCTAssertFalse(polled.contains("012F"), "fuel level isn't supported here, so not asked")
        XCTAssertEqual(a.values[0x0C]!, 1726, accuracy: 0.01)
        XCTAssertEqual(a.values[0x05]!, 90)
        XCTAssertEqual(a.values[0x0F]!, 20)
    }

    func testProtocolLadderThenRetry() {
        let a = FakeAdapter()
        a.s.start()
        a.reply("ELM327 v1.5")
        a.okUntil("0100")
        a.reply("BUS INIT: ...ERROR")
        a.okUntil("0100")
        XCTAssertTrue(a.sent.contains("ATSP5"), "then KWP fast init")
        a.reply("UNABLE TO CONNECT")
        a.okUntil("0100")
        XCTAssertTrue(a.sent.contains("ATSP4"))
        a.s.timedOut()
        a.okUntil("0100")
        XCTAssertTrue(a.sent.contains("ATSP0"), "automatic last")
        a.reply("NO DATA")
        XCTAssertEqual(a.s.state, .noCar)
        XCTAssertEqual(a.retries, [8])
        a.s.resume()
        a.okUntil("0100")
        XCTAssertEqual(a.sent.suffix(3), ["ATPC", "ATSP3", "0100"], "starts over from ISO 9141-2")
        a.reply("41 00 BE 1F A8 13")
        XCTAssertEqual(a.s.state, .running("3"))
    }

    func testSavedProtocolFirstAndKeyOff() {
        let a = FakeAdapter("5")
        a.s.start()
        a.reply("ELM327 v1.5")
        a.okUntil("0100")
        XCTAssertTrue(a.sent.contains("ATSP5"), "the protocol that worked last time goes first")
        a.reply("41 00 BE 1F A8 13")
        a.reply("41 20 00 00 00 00")       // 0120
        a.reply("41 01 00 07 65 00")       // 0101
        for _ in 0..<4 { a.s.timedOut() }  // key off
        XCTAssertEqual(a.s.state, .noCar)
        XCTAssertEqual(a.retries, [4])
        a.s.resume()
        a.okUntil("0100")
        XCTAssertEqual(a.sent.suffix(3), ["ATPC", "ATSP5", "0100"])
    }

    func testCodesRequestAndDroppedPid() {
        let a = FakeAdapter()
        a.s.start()
        a.reply("ELM327 v1.5")
        a.okUntil("0100")
        a.reply("41 00 BE 3E B8 11")
        a.reply("41 20 00 00 00 00")
        a.reply("41 01 81 07 65 00")
        XCTAssertEqual(a.status?.1, 1)
        var got: [String]?
        a.s.request("03") { if case .success(let l) = $0 { got = ObdDecode.codes(l) } }
        // the poll that was already out finishes first
        a.reply("41 0C 0C 80")
        XCTAssertEqual(a.last, "03")
        a.reply("43 01 33 00 00 00 00")
        XCTAssertEqual(got, ["P0133"])
        // a PID that keeps saying NO DATA is dropped
        var asked13 = 0
        for _ in 0..<60 {
            if a.last == "010B" { asked13 += 1; a.reply("NO DATA") } else { a.reply("41 \(a.last.dropFirst(2)) 10 10") }
        }
        XCTAssertEqual(asked13, 3)
        XCTAssertTrue(a.s.dropped.contains(0x0B))
    }

    func testDirectFrames() {
        var d = DirectData()
        d.tempF = true; d.mph = true; d.psi = false
        d.running = true
        let t = Date(timeIntervalSince1970: 2_000_000)
        d.add(0x0C, 3000, at: t)
        d.add(0x05, 112, at: t)
        d.add(0x14, 0.45, at: t)
        d.add(0x42, 14.1, at: t)
        let e = d.engineFrame(at: t)
        XCTAssertEqual(e.link, .obd)
        XCTAssertEqual(e[.rpm], 3000)
        XCTAssertEqual(e[.coolant], 112)
        XCTAssertEqual(e[.o2Up]!, 450, accuracy: 0.01)
        XCTAssertEqual(e[.battery], 14.1)
        let info = d.info()
        XCTAssertEqual(info.slots.map(\.key), ["rpm", "coolant", "modulev"])
        XCTAssertEqual(info.slots[1].unit, "F")
        XCTAssertEqual(info.slots[1].zones.count, 4)
        XCTAssertEqual(info.slots[1].zones[1].to, 221, accuracy: 0.01)
        let g = d.slots(at: t)
        XCTAssertEqual(g[1].value, 233.6, accuracy: 0.01)
        XCTAssertTrue(g[1].critical)
        XCTAssertEqual(g[1].zone, 3)
        XCTAssertEqual(g[0].zone, 1, "3000 rpm: green")
        let s = d.status(at: t)
        XCTAssertEqual(s.alarmLevel, 2)
        XCTAssertEqual(s.alarmText, "Coolant Temp 234 F")
        XCTAssertNil(d.engineFrame(at: t.addingTimeInterval(11))[.rpm], "stale after 10 s")
        XCTAssertEqual(DirectData.zoneIndex(DirectData.defs[0].zones, min: 0, 9000), 3, "past the dial: red")
        XCTAssertTrue(AdapterAdvert.plausible(name: "OBDII", services: [], rssi: -80))
        XCTAssertTrue(AdapterAdvert.plausible(name: nil, services: ["FFF0"], rssi: -60))
        XCTAssertFalse(AdapterAdvert.plausible(name: nil, services: ["FFF0"], rssi: -90), "an adapter service far away: someone else's")
        XCTAssertFalse(AdapterAdvert.plausible(name: "MiniGauge", services: [], rssi: -50))
    }
}
