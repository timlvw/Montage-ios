import SwiftUI

struct DashboardView: View {
    @EnvironmentObject var store: GaugeStore
    private let cols = [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 10) {
                    ConnectionBanner()
                    LazyVGrid(columns: cols, spacing: 10) {
                        MetricTile(metric: .rpm, size: 32)
                        MetricTile(metric: .gear, size: 32)
                        MetricTile(metric: .speed, size: 32)
                    }
                    boostCard
                    Card(title: ignitionTitle) {
                        IgnitionBars(ignition: store.engine.ignition, retard: store.engine.retard, height: 96)
                    }
                    LazyVGrid(columns: cols, spacing: 10) {
                        MetricTile(metric: .slip)
                        MetricTile(metric: .fuel, sub: economyText)
                        MetricTile(metric: .injDuty)
                        MetricTile(metric: .coolant)
                        MetricTile(metric: .intake)
                        MetricTile(metric: .battery)
                        ValueTile(label: "Thr / pedal", reading: throttlePedal, size: 22)
                        ValueTile(label: "O2 up / dn", reading: o2, size: 22)
                        MetricTile(metric: .fuelLevel)
                    }
                    footer
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 16)
            }
            .background(Theme.bg.ignoresSafeArea())
            .navigationTitle("MiniGauge")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { store.toggleLogging() } label: {
                        Label(store.logging ? "Logging" : "Log", systemImage: store.logging ? "record.circle.fill" : "record.circle")
                            .foregroundStyle(store.logging ? Theme.danger : Theme.accent)
                    }
                }
            }
        }
    }

    private var boostCard: some View {
        let s = store.snapshot
        let b = s.reading(.boost)
        return HStack(spacing: 10) {
            Card(title: "Boost") {
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(b.value).font(.system(size: 34, weight: .semibold, design: .rounded)).monospacedDigit()
                        .foregroundStyle(Theme.level(s.level(.boost)))
                    Text(b.unit).font(.subheadline).foregroundStyle(Theme.muted)
                }
                Sparkline(values: store.boostHistory).frame(height: 54)
            }
            .frame(maxWidth: .infinity)
            VStack(spacing: 10) {
                MetricTile(metric: .scRatio, size: 26)
                ValueTile(label: "Before S/C", reading: Fmt.pressureRel(store.boost.preBoost(store.engine), store.units), size: 20)
            }
            .frame(width: 130)
        }
    }

    private var ignitionTitle: String {
        if let s = store.engine.ignitionSpread { return String(format: "Ignition per cylinder — spread %.1f°", s) }
        return "Ignition per cylinder"
    }

    private var economyText: String? {
        let s = store.snapshot
        if let e = Fmt.economy(kph: store.engine[.speed], lph: store.engine[.fuel], s.units) { return "\(e.value) \(e.unit)" }
        guard store.engine[.fuel] != nil else { return nil }
        let t = Fmt.volume(store.status.fuelTripL, s.units)
        return "trip \(t.value) \(t.unit)"
    }

    private var throttlePedal: Reading {
        Reading(value: "\(Fmt.num(store.engine[.throttle], 0))/\(Fmt.num(store.engine[.pedal], 0))", unit: "%")
    }

    private var o2: Reading {
        Reading(value: "\(Fmt.num(store.engine[.o2Up].map { $0 / 1000 }, 2))/\(Fmt.num(store.engine[.o2Down].map { $0 / 1000 }, 2))", unit: "V")
    }

    private var footer: some View {
        HStack {
            Circle().fill(store.isLive ? Theme.ok : Theme.muted).frame(width: 8, height: 8)
            Text(store.status.linkText.isEmpty ? store.conn.text : store.status.linkText)
            Spacer()
            if store.engine.link == .bmw { Text(String(format: "%.1f blocks/s", store.engine.blocksPerSec)) }
        }
        .font(.caption)
        .foregroundStyle(Theme.muted)
        .padding(.top, 4)
    }
}
