import SwiftUI
import ActivityKit

struct SettingsView: View {
    @EnvironmentObject var store: GaugeStore

    var body: some View {
        Form {
            Section("Units") {
                Picker("Units", selection: $store.unitMode) {
                    Text("Same as the gauge").tag(0)
                    Text("Metric").tag(1)
                    Text("Imperial").tag(2)
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }
            Section {
                Toggle("Keep the screen on while connected", isOn: $store.keepAwake)
                Toggle("Demo data (no gauge needed)", isOn: $store.demoMode)
            }
            Section {
                Button("Forget this gauge and search again", role: .destructive) { store.forgetGauge() }
            } footer: {
                Text("The app remembers the gauge it last connected to and reconnects by itself, also in the background. The gauge streams over Bluetooth in K-line mode.")
            }
        }
        .navigationTitle("Settings")
    }
}

/// The Live Activity: Lock Screen, Dynamic Island and CarPlay (iOS 26).
struct LiveActivitySettings: View {
    @EnvironmentObject var store: GaugeStore
    @State private var running = false

    var body: some View {
        Form {
            Section {
                Toggle("Show live values", isOn: $store.liveActivityOn)
                HStack {
                    Text("Now")
                    Spacer()
                    Text(running ? "Showing" : "Not showing").foregroundStyle(.secondary)
                }
                if store.liveActivityOn && !running {
                    Button("Start now") { running = store.startActivityNow() }
                }
            } footer: {
                Text("Starts by itself when the gauge connects with the app open. On iOS 26 and later it also appears on CarPlay, on the dashboard next to the map. If it doesn't show, check Settings → MiniGauge → Live Activities.")
            }
            Section {
                ForEach(store.activityMetrics) { m in
                    Text(m.label)
                }
                .onMove { from, to in store.activityMetrics.move(fromOffsets: from, toOffset: to) }
                .onDelete { idx in
                    if store.activityMetrics.count > 1 { store.activityMetrics.remove(atOffsets: idx) }
                }
            } header: {
                Text("Shown (up to 4, drag to order)")
            } footer: {
                Text("The first two also go in the Dynamic Island.")
            }
            Section("Add") {
                ForEach(Metric.allCases.filter { !store.activityMetrics.contains($0) }) { m in
                    Button {
                        if store.activityMetrics.count < 4 { store.activityMetrics.append(m) }
                    } label: {
                        Label(m.label, systemImage: "plus.circle")
                    }
                    .disabled(store.activityMetrics.count >= 4)
                }
            }
        }
        .environment(\.editMode, .constant(.active))
        .navigationTitle("Lock Screen & CarPlay")
        .onAppear { running = store.activityRunning }
    }
}
