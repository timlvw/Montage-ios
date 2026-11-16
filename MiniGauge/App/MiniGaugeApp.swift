import SwiftUI

@main
struct MiniGaugeApp: App {
    @StateObject private var store = GaugeStore.shared
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
                .onAppear { store.start() }
        }
        .onChange(of: phase) { _, p in
            if p == .active { store.appBecameActive() }
        }
    }
}

struct RootView: View {
    @EnvironmentObject var store: GaugeStore
    @State private var tab = Self.initialTab

    // For the cloud build's screenshots: -tab N picks the starting tab.
    private static var initialTab: Int {
        let a = ProcessInfo.processInfo.arguments
        if let i = a.firstIndex(of: "-tab"), i + 1 < a.count, let n = Int(a[i + 1]) { return n }
        return 0
    }

    var body: some View {
        TabView(selection: $tab) {
            DashboardView()
                .tabItem { Label("Dash", systemImage: "gauge.with.dots.needle.67percent") }.tag(0)
            EngineView()
                .tabItem { Label("Engine", systemImage: "engine.combustion") }.tag(1)
            GaugesView()
                .tabItem { Label("Gauges", systemImage: "speedometer") }.tag(2)
            CarView()
                .tabItem { Label("Car", systemImage: "car") }.tag(3)
            MoreView()
                .tabItem { Label("More", systemImage: "ellipsis.circle") }.tag(4)
        }
        .overlay(alignment: .top) {
            if !store.lastNotice.isEmpty {
                Text(store.lastNotice)
                    .font(.footnote)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.top, 4)
                    .onTapGesture { store.clearNotice() }
                    .task(id: store.lastNotice) {
                        try? await Task.sleep(nanoseconds: 3_000_000_000)
                        store.clearNotice()
                    }
            }
        }
    }
}
