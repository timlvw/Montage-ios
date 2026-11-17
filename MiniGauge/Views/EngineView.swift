import SwiftUI

/// Every value the gauge streams, grouped. The diagnostic view.
struct EngineView: View {
    @EnvironmentObject var store: GaugeStore

    var body: some View {
        NavigationStack {
            List {
                Section { ConnectionBanner().listRowBackground(Color.clear).listRowInsets(EdgeInsets()) }
                    .listSectionSpacing(0)
                Section("Knock and ignition") {
                    IgnitionBars(ignition: store.engine.ignition, retard: store.engine.retard, height: 130)
                        .padding(.vertical, 6)
                    row("Spread", Reading(value: Fmt.num(store.engine.ignitionSpread, 1), unit: "°"))
                    row("Peak drop, 10 s", Reading(value: store.engine.retard.map { String(format: "%.1f", $0) }.joined(separator: " / "), unit: "°"))
                    row("Knock sensor", Reading(value: Fmt.num(store.engine[.knock].map { $0 / 1000 }, 3), unit: "V"))
                }
                Section("Air") {
                    row("Boost", m(.boost))
                    row("Manifold (absolute)", kpa(store.engine[.map]))
                    row("Before supercharger", kpa(store.engine[.mapPre]))
                    row("Supercharger ratio", m(.scRatio))
                    row("Barometer (learned)", kpa(store.boost.baroKpa))
                    row("Airflow", Reading(value: Fmt.num(store.engine[.airflow], 0), unit: "kg/h"))
                    row("Throttle", m(.throttle))
                    row("Pedal", m(.pedal))
                    row("Load", m(.load))
                }
                Section("Fuel") {
                    row("Flow", m(.fuel))
                    if let e = Fmt.economy(kph: store.engine[.speed], lph: store.engine[.fuel], store.units) { row("Economy", e) }
                    row("Used this trip", Fmt.volume(store.engine[.fuel] == nil ? nil : store.status.fuelTripL, store.units))
                    row("Injection time", Reading(value: Fmt.num(store.engine[.injMs], 2), unit: "ms"))
                    row("Injector duty", m(.injDuty))
                    row("Lambda correction", Reading(value: store.engine[.lambda].map { String(format: "%+.1f", $0) } ?? "--", unit: "%"))
                    row("Fuel adaptation", Reading(value: store.engine[.trim].map { String(format: "%+.2f", $0) } ?? "--", unit: "%"))
                    row("O2 upstream", Reading(value: Fmt.num(store.engine[.o2Up].map { $0 / 1000 }, 3), unit: "V"))
                    row("O2 downstream", Reading(value: Fmt.num(store.engine[.o2Down].map { $0 / 1000 }, 3), unit: "V"))
                }
                Section("Drive") {
                    row("RPM", m(.rpm))
                    row("Speed", m(.speed))
                    row("Gear (from rpm/speed)", m(.gear))
                    row("Front left wheel", Fmt.speed(store.engine[.wheelFL], store.units))
                    row("Front right wheel", Fmt.speed(store.engine[.wheelFR], store.units))
                    row("Front slip", m(.slip))
                }
                Section("Temperatures and power") {
                    row("Coolant", m(.coolant))
                    row("Intake air", m(.intake))
                    row("Battery", m(.battery))
                    row("Fuel in the tank", m(.fuelLevel))
                }
                Section("Link") {
                    row("Mode", Reading(value: store.engine.link.title, unit: ""))
                    row("Blocks per second", Reading(value: Fmt.num(store.engine.blocksPerSec, 1), unit: ""))
                    row("Gauge", Reading(value: store.info.map { "\($0.board), \($0.build)" } ?? "--", unit: ""))
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.bg.ignoresSafeArea())
            .navigationTitle("Engine")
        }
    }

    private func m(_ x: Metric) -> Reading { store.snapshot.reading(x) }

    private func kpa(_ v: Double?) -> Reading {
        guard let v = v else { return .none }
        return store.units.psi ? Reading(value: String(format: "%.2f", v * 0.145038), unit: "psi a")
                               : Reading(value: String(format: "%.1f", v), unit: "kPa")
    }

    private func row(_ label: String, _ r: Reading) -> some View {
        HStack {
            Text(label).foregroundStyle(Theme.muted)
            Spacer()
            Text(r.value).monospacedDigit().foregroundStyle(Theme.text)
            if !r.unit.isEmpty { Text(r.unit).foregroundStyle(Theme.muted) }
        }
        .listRowBackground(Theme.card)
    }
}
