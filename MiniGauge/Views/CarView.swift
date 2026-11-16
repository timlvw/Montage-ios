import SwiftUI

/// Trouble codes and the gauge's /car jobs (all read-only).
struct CarView: View {
    @EnvironmentObject var store: GaugeStore
    @State private var confirmJob: Int? = nil

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 10) {
                    ConnectionBanner()
                    codesCard
                    Card(title: "Engine computer (any time in BMW mode)") {
                        HStack {
                            jobButton("Identify", 1)
                            jobButton("Fault memory", 2)
                        }
                    }
                    Card(title: "Other modules (park first)") {
                        Text("The gauges pause for a few seconds while the gauge talks to these.")
                            .font(.caption).foregroundStyle(Theme.muted)
                        HStack {
                            jobButton("Steering pump", 3, parked: true)
                            jobButton("Find DSC", 4, parked: true)
                        }
                        jobButton("Full address sweep (~6 min)", 5, parked: true)
                    }
                    if !store.carText.isEmpty || store.carBusy {
                        Card(title: store.carBusy ? "Running…" : "Result") {
                            if store.carBusy { ProgressView().tint(Theme.accent) }
                            Text(store.carText)
                                .font(.system(size: 12, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            if !store.carBusy && !store.carText.isEmpty {
                                ShareLink(item: store.carText) { Label("Share", systemImage: "square.and.arrow.up") }
                                    .padding(.top, 4)
                            }
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 16)
            }
            .background(Theme.bg.ignoresSafeArea())
            .navigationTitle("Car")
            .confirmationDialog("Car parked?", isPresented: Binding(get: { confirmJob != nil }, set: { if !$0 { confirmJob = nil } }),
                                titleVisibility: .visible) {
                Button("Yes, run it") { if let j = confirmJob { store.runCarJob(j) }; confirmJob = nil }
                Button("Cancel", role: .cancel) { confirmJob = nil }
            } message: {
                Text("This talks to another module on the K-line. The gauge refuses if the car is moving.")
            }
        }
    }

    private var codesCard: some View {
        Card(title: "Trouble codes") {
            if let n = store.engine.dtcCount {
                if n == 0 {
                    Label("No stored codes", systemImage: "checkmark.circle").foregroundStyle(Theme.ok)
                } else {
                    ForEach(store.status.codes, id: \.self) { c in
                        HStack {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.warn)
                            Text(c).font(.body.monospaced())
                        }
                    }
                    if store.engine.milValid {
                        Text(store.engine.milOn ? "Check-engine lamp: ON" : "Check-engine lamp: off")
                            .font(.caption).foregroundStyle(store.engine.milOn ? Theme.danger : Theme.muted)
                    }
                    Text("“Fault memory” below gives the engine computer's own description of each.")
                        .font(.caption).foregroundStyle(Theme.muted)
                }
            } else {
                Text("Not read yet.").foregroundStyle(Theme.muted)
            }
            Button("Read codes") { store.readCodes() }
                .buttonStyle(.bordered).tint(Theme.accent).padding(.top, 4)
        }
    }

    private func jobButton(_ title: String, _ job: Int, parked: Bool = false) -> some View {
        Button {
            if parked { confirmJob = job } else { store.runCarJob(job) }
        } label: {
            Text(title).frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .tint(parked ? Color(white: 0.25) : Theme.ok)
        .disabled(store.carBusy)
    }
}
