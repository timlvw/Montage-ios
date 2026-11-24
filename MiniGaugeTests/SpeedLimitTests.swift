import XCTest
@testable import MiniGauge

// Speed limit: OSM maxspeed parsing, Overpass replies, road matching, the
// gauge command and the zones the phone draws.
final class SpeedLimitTests: XCTestCase {
    func testMaxSpeed() {
        XCTAssertEqual(MaxSpeed.kmh("45 mph")!, 72.42, accuracy: 0.01)
        XCTAssertEqual(MaxSpeed.kmh("45mph")!, 72.42, accuracy: 0.01)
        XCTAssertEqual(MaxSpeed.kmh("50"), 50)
        XCTAssertEqual(MaxSpeed.kmh("80 km/h"), 80)
        XCTAssertEqual(MaxSpeed.kmh("35 mph;45 mph")!, 56.33, accuracy: 0.01)
        XCTAssertNil(MaxSpeed.kmh("none"))
        XCTAssertNil(MaxSpeed.kmh("signals"))
        XCTAssertNil(MaxSpeed.kmh("US:urban"))
        XCTAssertNil(MaxSpeed.kmh(nil))
        XCTAssertNil(MaxSpeed.kmh(""))
    }

    func testOverpassReply() throws {
        let json = #"""
        {"version":0.6,"elements":[
          {"type":"way","id":11,"tags":{"highway":"primary","name":"Main Street","maxspeed":"45 mph"},
           "geometry":[{"lat":42.0,"lon":-71.0},{"lat":42.0,"lon":-70.99}]},
          {"type":"way","id":12,"tags":{"highway":"secondary","ref":"MA 9","maxspeed:forward":"40 mph","maxspeed:backward":"30 mph","oneway":"no"},
           "geometry":[{"lat":42.001,"lon":-71.0},{"lat":42.001,"lon":-70.99}]},
          {"type":"way","id":13,"tags":{"highway":"motorway","maxspeed":"65 mph"},"geometry":[{"lat":42.01,"lon":-71.0},{"lat":42.02,"lon":-71.0}]},
          {"type":"way","id":14,"tags":{"highway":"residential","oneway":"-1"},"geometry":[{"lat":42.0,"lon":-71.0}]},
          {"type":"node","id":15}
        ]}
        """#
        let roads = try XCTUnwrap(Overpass.roads(Data(json.utf8)))
        XCTAssertEqual(roads.map(\.id), [11, 12, 13], "a one-point way and a node are dropped")
        XCTAssertEqual(roads[0].label, "Main Street")
        XCTAssertEqual(roads[0].fwd!, 72.42, accuracy: 0.01)
        XCTAssertEqual(roads[0].bwd!, 72.42, accuracy: 0.01)
        XCTAssertEqual(roads[1].label, "MA 9", "no name: the route number")
        XCTAssertEqual(roads[1].fwd!, 64.37, accuracy: 0.01)
        XCTAssertEqual(roads[1].bwd!, 48.28, accuracy: 0.01)
        XCTAssertEqual(roads[2].oneway, 1, "motorways are one-way")
        XCTAssertTrue(Overpass.query(Tile(lat: 42.005, lon: -70.995)).contains("(42.0000,-71.0000,42.0200,-70.9800)"))
    }

    func testTiles() {
        let t = Tile(lat: 42.005, lon: -70.995)
        XCTAssertEqual(t, Tile(x: -3550, y: 2100))
        XCTAssertEqual(Tile.around(lat: 42.01, lon: -70.99).count, 1, "middle of a tile: just that one")
        XCTAssertEqual(Tile.around(lat: 42.0001, lon: -70.9999).count, 4, "a corner: its neighbours too")
    }

    func testGeo() {
        let a = Geo.local(42.0, -71.0, from: 42.0001, -70.9995)
        let b = Geo.local(42.0, -70.999, from: 42.0001, -70.9995)
        XCTAssertEqual(Geo.toSegment(a, b).d, 11.13, accuracy: 0.2, "about 11 m north of an east-west road")
        XCTAssertEqual(Geo.bearing(a, b), 90, accuracy: 0.5)
        XCTAssertEqual(Geo.angle(350, 10), 20)
        XCTAssertEqual(Geo.angle(90, 270), 180)
    }

    // An east-west main road (45 mph), a parallel side road 30 m north (25 mph),
    // and a north-south cross street (30 mph) through x = -70.995.
    private let main = Road(id: 1, name: "Main St", highway: "primary", oneway: 0, fwd: 72.42, bwd: 72.42,
                            pts: [[42.0, -71.0], [42.0, -70.99]])
    private let side = Road(id: 2, name: "Side St", highway: "residential", oneway: 0, fwd: 40.23, bwd: 40.23,
                            pts: [[42.00027, -71.0], [42.00027, -70.99]])
    private let cross = Road(id: 3, name: "Cross St", highway: "tertiary", oneway: 0, fwd: 48.28, bwd: 48.28,
                             pts: [[41.99, -70.995], [42.01, -70.995]])
    private let oneWayWest = Road(id: 4, name: "Oneway", highway: "secondary", oneway: 1, fwd: 56.33, bwd: 56.33,
                                  pts: [[41.9999, -70.99], [41.9999, -71.0]])

    func testMatcherStaysOnTheRoad() {
        var m = RoadMatcher()
        let roads = [main, side, cross]
        // driving east on Main St, GPS wandering a few metres, through the junction
        let fixes: [(Double, Double)] = [(42.00003, -70.998), (41.99997, -70.997), (42.00006, -70.996), (42.00002, -70.995), (42.00004, -70.994)]
        for (lat, lon) in fixes {
            let r = m.update(lat: lat, lon: lon, course: 90, speed: 15, accuracy: 8, roads: roads)
            XCTAssertEqual(r?.road.id, 1, "at \(lon): Main St, not the side road or the cross street")
        }
        XCTAssertEqual(m.current?.limitKmh ?? 0, 72.42, accuracy: 0.01)
        // one bad fix nearer the side road doesn't switch...
        XCTAssertEqual(m.update(lat: 42.00021, lon: -70.993, course: 90, speed: 15, accuracy: 10, roads: roads)?.road.id, 1)
        // ...two in a row (and closer to it) do
        _ = m.update(lat: 42.00026, lon: -70.992, course: 90, speed: 15, accuracy: 5, roads: roads)
        XCTAssertEqual(m.update(lat: 42.00027, lon: -70.991, course: 90, speed: 15, accuracy: 5, roads: roads)?.road.id, 2)
    }

    func testMatcherTurnsOntoCrossStreet() {
        var m = RoadMatcher()
        let roads = [main, cross]
        _ = m.update(lat: 42.0, lon: -70.997, course: 90, speed: 12, accuracy: 6, roads: roads)
        // turned north: heading now matches the cross street, and Main St (east-west) no longer does
        XCTAssertEqual(m.update(lat: 42.0004, lon: -70.995, course: 0, speed: 10, accuracy: 6, roads: roads)?.road.id, 3)
        XCTAssertEqual(m.current?.limitKmh ?? 0, 48.28, accuracy: 0.01)
        // far from every road: unknown after two misses
        _ = m.update(lat: 42.005, lon: -70.98, course: 0, speed: 10, accuracy: 6, roads: roads)
        XCTAssertNil(m.update(lat: 42.0051, lon: -70.98, course: 0, speed: 10, accuracy: 6, roads: roads))
    }

    func testOneWayAndDirection() {
        var m = RoadMatcher()
        // eastbound right on top of a west-only one-way: not it (wrong way)
        XCTAssertEqual(m.update(lat: 41.9999, lon: -70.995, course: 90, speed: 15, accuracy: 5, roads: [oneWayWest, main])?.road.id, 1)
        var w = RoadMatcher()
        XCTAssertEqual(w.update(lat: 41.9999, lon: -70.995, course: 270, speed: 15, accuracy: 5, roads: [oneWayWest, main])?.road.id, 4)
        // direction-specific limits: along the way vs against it
        let ma9 = Road(id: 9, name: "MA 9", highway: "secondary", oneway: 0, fwd: 64.37, bwd: 48.28, pts: [[42.0, -71.0], [42.0, -70.99]])
        var e = RoadMatcher(), wb = RoadMatcher()
        XCTAssertEqual(e.update(lat: 42.0, lon: -70.995, course: 90, speed: 15, accuracy: 5, roads: [ma9])?.limitKmh ?? 0, 64.37, accuracy: 0.01)
        XCTAssertEqual(wb.update(lat: 42.0, lon: -70.995, course: 270, speed: 15, accuracy: 5, roads: [ma9])?.limitKmh ?? 0, 48.28, accuracy: 0.01)
        // parked (no course): nearest road
        var p = RoadMatcher()
        XCTAssertEqual(p.update(lat: 42.00001, lon: -70.995, course: -1, speed: 0, accuracy: 5, roads: [main, side])?.road.id, 1)
    }

    func testCommandAndZones() {
        var s = LimitSettings()
        XCTAssertEqual(LimitCommand.text(s, limitKmh: 72.42), "limit off", "off by default")
        s.on = true
        XCTAssertEqual(LimitCommand.text(s, limitKmh: 72.42), "limit v=72.4&a=8.05&r=16.09&aa=0&ra=1")
        XCTAssertEqual(LimitCommand.text(s, limitKmh: nil), "limit v=-1&a=8.05&r=16.09&aa=0&ra=1")
        let toMph: (Double) -> Double = { $0 / 1.609344 }
        let z = LimitZones.zones(limitKmh: 72.42, s, toDisplay: toMph, rangeMin: 0, rangeMax: 140)
        XCTAssertEqual(z.count, 3)
        XCTAssertEqual(z[0].to, 50, accuracy: 0.05)
        XCTAssertEqual(z[1].from, 50, accuracy: 0.05)
        XCTAssertEqual(z[1].to, 55, accuracy: 0.05)
        XCTAssertEqual(z[2].al, 1)
        XCTAssertEqual(z[2].to, 140)
        XCTAssertEqual(LimitZones.index(z, rangeMin: 0, 44), 0)
        XCTAssertEqual(LimitZones.index(z, rangeMin: 0, 52), 1)
        XCTAssertEqual(LimitZones.index(z, rangeMin: 0, 150), 2, "past the dial: red")
        s.redOverKmh = s.amberOverKmh
        XCTAssertEqual(LimitZones.zones(limitKmh: 72.42, s, toDisplay: toMph, rangeMin: 0, rangeMax: 140).count, 2, "no amber step")
    }

    func testDirectModeFollowsTheLimit() {
        var d = DirectData()
        d.running = true
        var s = LimitSettings(); s.on = true
        d.limit = (72.42, s)
        let t = Date(timeIntervalSince1970: 3_000_000)
        d.add(0x0D, 92, at: t)              // km/h: 57 mph in a 45
        let info = d.info()
        XCTAssertEqual(info.slots[0].zones.count, 3)
        XCTAssertEqual(info.slots[0].zones[0].to, 50, accuracy: 0.05)
        let g = d.slots(at: t)
        XCTAssertEqual(g[0].zone, 2)
        XCTAssertTrue(g[0].warn)
        XCTAssertEqual(d.status(at: t).alarmLevel, 1)
        XCTAssertEqual(d.status(at: t).alarmText, "Speed 57 mph")
        d.limit = nil
        XCTAssertEqual(d.slots(at: t)[0].zone, 0, "no limit: the usual speed zones (57 mph is green)")
    }
}
