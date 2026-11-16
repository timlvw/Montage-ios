import SwiftUI

/// The gauge's own slots, as dials, with the gauge's names, ranges and zones.
struct GaugesView: View {
    @EnvironmentObject var store: GaugeStore
    private let cols = [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 10) {
                    ConnectionBanner()
                    if store.gauges.isEmpty {
                        Card { Text("The gauge's dials appear here once it's connected.").foregroundStyle(Theme.muted) }
                    }
                    LazyVGrid(columns: cols, spacing: 10) {
                        ForEach(store.gauges) { g in
                            ArcGauge(slot: store.info?.slots.first { $0.i == g.slot }, value: g, fallbackName: String(format: "PID %02X", g.pid))
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 16)
            }
            .background(Theme.bg.ignoresSafeArea())
            .navigationTitle("Gauges")
            .refreshable { store.send("info") }
        }
    }
}
