import XCTest
@testable import MiniGauge

final class UnitsTests: XCTestCase {
    func testFormatting() {
        XCTAssertEqual(Fmt.temp(90, .imperial), Reading(value: "194", unit: "°F"))
        XCTAssertEqual(Fmt.temp(90, .metric), Reading(value: "90", unit: "°C"))
        XCTAssertEqual(Fmt.speed(100, .imperial).value, "62")
        XCTAssertEqual(Fmt.pressureRel(67.1, .imperial), Reading(value: "9.7", unit: "psi"))
        XCTAssertEqual(Fmt.fuelFlow(28.4, .imperial).value, "7.50")
        XCTAssertNil(Fmt.economy(kph: 0, lph: 1, .metric))
        XCTAssertEqual(Fmt.economy(kph: 100, lph: 7, .metric)?.value, "7.0")
        XCTAssertEqual(Fmt.temp(nil, .metric).value, "--")
    }

    func testBoostLearnsBaro() {
        var b = BoostTracker()
        var e = EngineFrame()
        e.values = [.rpm: 0, .map: 98.9, .mapPre: 99.0]
        b.update(e)
        XCTAssertEqual(b.baroKpa, 99.0, accuracy: 0.001)
        e.values = [.rpm: 4000, .map: 168.0, .mapPre: 70]
        b.update(e)
        XCTAssertEqual(b.baroKpa, 99.0, accuracy: 0.001)          // not while running
        XCTAssertEqual(b.boost(e)!, 69.0, accuracy: 0.001)
    }

    func testCSV() {
        var e = EngineFrame()
        e.values = [.rpm: 812, .coolant: 90.5, .battery: 14.12]
        e.link = .bmw
        let row = TripCSV.row(t: 1.5, frame: e, boostKpa: -60)
        let cols = row.split(separator: ",", omittingEmptySubsequences: false)
        XCTAssertEqual(cols.count, TripCSV.header.split(separator: ",").count)
        XCTAssertEqual(cols[0], "1.50")
        XCTAssertEqual(cols[1], "812")
        XCTAssertEqual(cols[1 + Field.coolant.rawValue], "90.5")
        XCTAssertEqual(cols[1 + Field.battery.rawValue], "14.12")
        XCTAssertEqual(cols.last, "3")
    }

    func testDerived() {
        var e = EngineFrame()
        e.values = [.ign1: 20, .ign2: 20, .ign3: 17, .ign4: 20, .map: 150, .mapPre: 75]
        XCTAssertEqual(e.ignitionSpread, 3)
        XCTAssertEqual(e.scRatio!, 2.0, accuracy: 0.0001)
    }
}
