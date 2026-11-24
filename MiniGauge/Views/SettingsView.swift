import SwiftUI
import ActivityKit

struct SettingsView: View {
    @EnvironmentObject var store: GaugeStore

    /// A speed margin in the display unit (whole mph or km/h), stored in km/h.
    private func margin(_ kp: WritableKeyPath<LimitSettings, Double>) -> Binding<Int> {
        let mph = store.units.mph
        return Binding(get: { Int((mph ? store.limitSettings[keyPath: kp] / 1.609344 : store.limitSettings[keyPath: kp]).rounded()) },
                       set: { store.limitSettings[keyPath: kp] = mph ? Double($0) * 1.609344 : Double($0) })
    }

    private var speedLimitSection: some View {
        let unit = store.units.mph ? "mph" : "km/h"
        return Section {
            Toggle("Follow the road's speed limit", isOn: $store.limitSettings.on)
            if store.limitSettings.on {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Now").font(.caption).foregroundStyle(Theme.muted)
                    Text(store.limitNow.text(mph: store.units.mph))
                }
                Stepper(value: margin(\.amberOverKmh), in: 0...30) {
                    LabeledContent("Amber from", value: "\(margin(\.amberOverKmh).wrappedValue) \(unit) over")
                }
                Stepper(value: margin(\.redOverKmh), in: margin(\.amberOverKmh).wrappedValue...40) {
                    LabeledContent("Red from", value: "\(margin(\.redOverKmh).wrappedValue) \(unit) over")
                }
                Picker("Amber alarm", selection: $store.limitSettings.amberAlarm) {
                    Text("Colour only").tag(0); Text("Warning").tag(1); Text("Critical").tag(2)
                }
                Picker("Red alarm", selection: $store.limitSettings.redAlarm) {
                    Text("Colour only").tag(0); Text("Warning").tag(1); Text("Critical").tag(2)
                }
            }
        } header: { Text("Speed limit") } footer: {
            Text("The phone finds the road you're on (GPS) and its limit from OpenStreetMap, and the speed gauge's zones follow it: green up to the amber margin over the limit, amber, then red. A road with no limit recorded shows \"?\" and the gauge's own zones. Roads are downloaded as you drive and kept on the phone for 30 days. Needs location for MiniGauge (it keeps running with the phone locked while connected). Not every road has a limit recorded, and it can pick the wrong road at junctions: a reminder, not gospel.")
        }
    }

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
                Picker("Connect to", selection: $store.source) {
                    Text("MiniGauge").tag(DataSource.gauge)
                    Text("OBD adapter (direct)").tag(DataSource.adapter)
                }
                if store.source == .adapter {
                    LabeledContent("Adapter", value: store.conn == .connected ? store.deviceName : store.connText)
                }
            } header: { Text("Car data") } footer: {
                if store.source == .adapter {
                    Text("Straight to a Bluetooth LE OBD adapter (ELM327), no gauge needed: standard OBD values, about one update a second each, trouble codes. Not the BMW-mode values (boost before the supercharger, ignition per cylinder, injector duty, gear), and not the gauge pages. Only with the gauge unplugged or off: two devices talking to the engine computer at once garble the K-line.")
                } else {
                    Text("The gauge reads the car (K-line, BMW mode) and streams everything to the phone.")
                }
            }
            speedLimitSection
            Section {
                Toggle("Keep the screen on while connected", isOn: $store.keepAwake)
                Toggle("Demo data (no gauge needed)", isOn: $store.demoMode)
            }
            Section {
                if store.source == .adapter {
                    Button("Forget this adapter and search again", role: .destructive) { store.forgetAdapter() }
                } else {
                    Button("Forget this gauge and search again", role: .destructive) { store.forgetGauge() }
                }
            } footer: {
                Text(store.source == .adapter
                     ? "The app remembers the adapter it last used and reconnects by itself. It looks for adapters named like OBD, ELM, Vlink, Vgate, Veepeak or SinoTrack."
                     : "The app remembers the gauge it last connected to and reconnects by itself, also in the background.")
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
