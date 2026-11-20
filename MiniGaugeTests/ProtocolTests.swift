import XCTest
@testable import MiniGauge

// Frames below are exactly what the firmware's encoder produces (printed by
// its host test, cluster175 scratch phtest/t.cpp) for known values.
final class ProtocolTests: XCTestCase {
    static func hex(_ s: String) -> [UInt8] {
        var out: [UInt8] = []
        var i = s.startIndex
        while i < s.endIndex {
            let j = s.index(i, offsetBy: 2)
            out.append(UInt8(s[i..<j], radix: 16)!)
            i = j
        }
        return out
    }

    static let engineHex = "010134120303050267007fa228a29a109c0303009406d1029303d5ff000000008405000000000000bd060000b7050000000000002c010000dd04000000000000180b0000000000006aff0000a401"
    static let gaugesHex = "0202000c0300d0cf45780003050000000000ffff"
    static let statusHex = "0301030a0000a03f436f6e6e65637465642028424d572900000000000000000000000000000000000000000000000000436f6f6c616e742031313200000000000000000000000000000000000000000000000000000000000250303137315030333032"
    static let textHex = "07000168656c6c6f20776f726c642c20746869732069732061207265706c79"

    func testEngine() throws {
        guard case .engine(let e) = try FrameDecoder.decode(Self.hex(Self.engineHex)) else { return XCTFail("not engine") }
        XCTAssertEqual(e.seq, 0x1234)
        XCTAssertEqual(e.link, .bmw)
        XCTAssertTrue(e.milValid && e.milOn)
        XCTAssertTrue(e.tempF && e.pressPsi && !e.speedMph)
        XCTAssertEqual(e.dtcCount, 2)
        XCTAssertEqual(e.blocksPerSec, 10.3, accuracy: 0.001)
        XCTAssertEqual(e[.rpm], 4250)
        XCTAssertEqual(e[.speed]!, 92.4, accuracy: 0.001)
        XCTAssertEqual(e[.gear], 3)
        XCTAssertEqual(e[.map]!, 168.4, accuracy: 0.001)
        XCTAssertEqual(e[.mapPre]!, 72.1, accuracy: 0.001)
        XCTAssertEqual(e[.coolant]!, 91.5, accuracy: 0.001)
        XCTAssertEqual(e[.intake]!, -4.3, accuracy: 0.001)     // -42.5 rounds to -43 on the wire
        XCTAssertEqual(e[.battery]!, 14.12, accuracy: 0.001)
        XCTAssertEqual(e[.ign1]!, 17.25, accuracy: 0.001)
        XCTAssertEqual(e[.ign3]!, 14.63, accuracy: 0.001)
        XCTAssertEqual(e[.ret3]!, 3.0, accuracy: 0.001)
        XCTAssertEqual(e[.knock], 1245)
        XCTAssertEqual(e[.fuel]!, 28.4, accuracy: 0.001)
        XCTAssertEqual(e[.lambda]!, -1.5, accuracy: 0.001)
        XCTAssertEqual(e[.fuelLevel]!, 42, accuracy: 0.001)
        XCTAssertNil(e[.ign2])
        XCTAssertNil(e[.slip])
        XCTAssertEqual(e.values.count, 15)
    }

    func testGaugesZoneIndex() throws {
        // v5.12: flags bits 4-6 carry the zone the value is in, + 1
        guard case .gauges(let g) = try FrameDecoder.decode(Self.hex("0202000c2300d0cf45780003050000000000ffff")) else { return XCTFail("not gauges") }
        XCTAssertTrue(g[0].valid && g[0].warn && !g[0].critical)
        XCTAssertEqual(g[0].zone, 1)
        XCTAssertNil(g[1].zone)
        guard case .gauges(let o) = try FrameDecoder.decode(Self.hex(Self.gaugesHex)) else { return XCTFail("not gauges") }
        XCTAssertNil(o[0].zone, "older firmware: no zone index")
    }

    func testGauges() throws {
        guard case .gauges(let g) = try FrameDecoder.decode(Self.hex(Self.gaugesHex)) else { return XCTFail("not gauges") }
        XCTAssertEqual(g.count, 2)
        XCTAssertEqual(g[0].slot, 0)
        XCTAssertEqual(g[0].pid, 0x0C)
        XCTAssertTrue(g[0].valid && g[0].warn && !g[0].critical)
        XCTAssertEqual(g[0].value, 6650)
        XCTAssertEqual(g[0].ageMs, 120)
        XCTAssertEqual(g[1].slot, 3)
        XCTAssertFalse(g[1].valid)
        XCTAssertNil(g[1].ageMs)
    }

    func testStatus() throws {
        guard case .status(let s) = try FrameDecoder.decode(Self.hex(Self.statusHex)) else { return XCTFail("not status") }
        XCTAssertEqual(s.alarmLevel, 1)
        XCTAssertEqual(s.link, .bmw)
        XCTAssertEqual(s.pollsPerSec, 10)
        XCTAssertEqual(s.fuelTripL, 1.25, accuracy: 0.0001)
        XCTAssertEqual(s.linkText, "Connected (BMW)")
        XCTAssertEqual(s.alarmText, "Coolant 112")
        XCTAssertEqual(s.codes, ["P0171", "P0302"])
    }

    func testText() {
        var r = TextReassembler()
        let got = r.feed(Self.hex(Self.textHex))
        XCTAssertEqual(got?.id, 7)
        XCTAssertEqual(got?.text, "hello world, this is a reply")
    }

    func testTextChunks() {
        var r = TextReassembler()
        let big = (0..<400).map { UInt8(97 + $0 % 26) }
        func chunk(_ part: UInt8) -> [UInt8] {
            let off = Int(part) * 160
            let n = min(160, big.count - off)
            return [1, part, off + n >= big.count ? 1 : 0] + Array(big[off..<(off + n)])
        }
        XCTAssertNil(r.feed(chunk(0)))
        XCTAssertNil(r.feed(chunk(1)))
        let got = r.feed(chunk(2))
        XCTAssertEqual(got?.text.count, 400)
        // a lost middle chunk drops the reply
        XCTAssertNil(r.feed(chunk(0)))
        XCTAssertNil(r.feed(chunk(2)))
    }

    func testBadFrames() {
        XCTAssertThrowsError(try FrameDecoder.decode([]))
        XCTAssertThrowsError(try FrameDecoder.decode([9, 1, 2]))
        XCTAssertThrowsError(try FrameDecoder.decode([1, 1, 0, 0]))
        var e = Self.hex(Self.engineHex)
        e[1] = 2
        XCTAssertThrowsError(try FrameDecoder.decode(e))
    }

    func testInfo() {
        let json = """
        {"v":1,"board":"AMOLED 1.75","build":"Nov 16 2026 01:02:03","units":{"tempF":true,"mph":true,"psi":true},\
        "proto":"BMW (KWP2000)","pref":0,"slots":[{"i":0,"pid":12,"key":"rpm","name":"RPM","unit":"rpm","d":0,\
        "min":0.000,"max":7500.000,"zones":[{"from":6500.000,"to":7500.000,"crit":true,"color":"#FF2D55"}]}]}
        """
        let info = GaugeInfo.parse(json)
        XCTAssertEqual(info?.slots.first?.name, "RPM")
        XCTAssertEqual(info?.slots.first?.zones.first?.crit, true)
        XCTAssertEqual(info?.units.psi, true)
    }
}
