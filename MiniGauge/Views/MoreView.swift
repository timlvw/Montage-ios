import SwiftUI
import Charts
import Combine

enum MoreRoute: String, Hashable {
    case dyno, logs, raw, klog, files, gaugeSettings, layout, activity, settings
}

struct MoreView: View {
    @EnvironmentObject var store: GaugeStore
    @State private var path: [MoreRoute] = Self.initialPath

    // For the cloud build's screenshots: -screen <route> opens that page.
    private static var initialPath: [MoreRoute] {
        let a = ProcessInfo.processInfo.arguments
        if let i = a.firstIndex(of: "-screen"), i + 1 < a.count, let r = MoreRoute(rawValue: a[i + 1]) { return [r] }
        return []
    }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                Section {
                    NavigationLink(value: MoreRoute.dyno) { Label("Dyno", systemImage: "speedometer") }
                    NavigationLink(value: MoreRoute.logs) { Label("Trip logs (this phone)", systemImage: "doc.text") }
                    NavigationLink(value: MoreRoute.raw) { Label("Raw blocks", systemImage: "number") }
                    NavigationLink(value: MoreRoute.klog) { Label("K-line log", systemImage: "list.bullet.rectangle") }
                }
                Section("On the gauge") {
                    NavigationLink(value: MoreRoute.files) { Label("Gauge files", systemImage: "externaldrive") }
                    NavigationLink(value: MoreRoute.gaugeSettings) { Label("Gauge settings", systemImage: "slider.horizontal.3") }
                    NavigationLink(value: MoreRoute.layout) { Label("Gauge layout", systemImage: "square.grid.2x2") }
                }
                Section {
                    NavigationLink(value: MoreRoute.activity) { Label("Lock Screen & CarPlay", systemImage: "car") }
                    NavigationLink(value: MoreRoute.settings) { Label("App settings", systemImage: "gearshape") }
                }
                Section("Gauge") {
                    LabeledContent("Status", value: store.conn.text)
                    if let i = store.info {
                        LabeledContent("Board", value: i.board)
                        LabeledContent("Firmware", value: i.build)
                        LabeledContent("K-line", value: i.proto.isEmpty ? "—" : i.proto)
                    }
                }
            }
            .navigationTitle("More")
            .navigationDestination(for: MoreRoute.self) { r in
                switch r {
                case .dyno: DynoView()
                case .logs: LogsView()
                case .raw: TextPage(title: "Raw blocks", command: "raw")
                case .klog: TextPage(title: "K-line log", command: "log")
                case .files: GaugeFilesView()
                case .gaugeSettings: GaugeSettingsView()
                case .layout: GaugeLayoutView()
                case .activity: LiveActivitySettings()
                case .settings: SettingsView()
                }
            }
        }
    }
}

/// A command's text reply, refreshable (raw blocks, K-line log).
struct TextPage: View {
    @EnvironmentObject var store: GaugeStore
    var title: String
    var command: String
    @State private var auto = true
    private let timer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    private var text: String { command == "raw" ? store.rawText : store.logText }

    var body: some View {
        ScrollView {
            Text(text.isEmpty ? "Waiting for the gauge…" : text)
                .font(.system(size: 12, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
        }
        .background(Theme.bg.ignoresSafeArea())
        .navigationTitle(title)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Toggle(isOn: $auto) { Image(systemName: "arrow.triangle.2.circlepath") }.toggleStyle(.button)
                ShareLink(item: text)
            }
        }
        .onAppear { store.send(command) }
        .onReceive(timer) { _ in if auto { store.send(command) } }
    }
}

struct LogsView: View {
    @EnvironmentObject var store: GaugeStore
    @State private var files: [URL] = []

    var body: some View {
        List {
            Section {
                Toggle("Record this trip", isOn: Binding(get: { store.logging }, set: { _ in store.toggleLogging(); reload() }))
                Toggle("Record automatically while the engine runs", isOn: $store.autoLog)
            } footer: {
                Text("One CSV per engine run (it ends 30 s after the engine stops), 5 rows a second, every value the gauge sends. Also in the Files app under MiniGauge. The gauge keeps its own logs too: More → Gauge files.")
            }
            Section("Saved") {
                if files.isEmpty { Text("No logs yet.").foregroundStyle(.secondary) }
                ForEach(files, id: \.self) { url in
                    ShareLink(item: url) {
                        VStack(alignment: .leading) {
                            Text(url.deletingPathExtension().lastPathComponent).font(.subheadline)
                            Text(size(url)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .onDelete { idx in
                    for i in idx { try? FileManager.default.removeItem(at: files[i]) }
                    reload()
                }
            }
        }
        .navigationTitle("Trip logs")
        .onAppear(perform: reload)
    }

    private func reload() { files = TripLogger.files() }

    private func size(_ url: URL) -> String {
        let n = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return ByteCountFormatter.string(fromByteCount: Int64(n), countStyle: .file)
    }
}

struct DynoView: View {
    @EnvironmentObject var store: GaugeStore
    @State private var seconds = 15
    @State private var result: DynoResult?
    @State private var note = ""
    @State private var times: [DynoTime] = []
    @State private var fromStop = true
    @State private var runs: [GaugeFile] = []
    @State private var loadingRun: String?
    @State private var shown = ""                  // which run the result is from
    @State private var push: Task<Void, Never>?

    var body: some View {
        List {
            Section {
                Text("Pick a gear (3rd is good), start below 2500 rpm on a flat, empty, legal road, press Record, full throttle to the limiter, lift.")
                    .font(.footnote).foregroundStyle(.secondary)
                Picker("Record for", selection: $seconds) {
                    ForEach([10, 15, 20, 30], id: \.self) { Text("\($0) s").tag($0) }
                }
                HStack {
                    Button(store.engine.dynoRecording ? "Recording…" : "Record") { store.send("dyno \(seconds)") }
                        .buttonStyle(.borderedProminent).tint(Theme.danger).disabled(store.engine.dynoRecording)
                    Button("Stop") { store.send("dyno stop") }.buttonStyle(.bordered)
                    Spacer()
                    Button("Load last pull") { store.send("dynocsv") }.buttonStyle(.bordered).tint(Theme.accent)
                }
            }
            if let r = result {
                Section("Result") {
                    Chart {
                        ForEach(r.points) { p in
                            LineMark(x: .value("rpm", p.rpm), y: .value("hp", p.crankHp), series: .value("s", "hp"))
                                .foregroundStyle(Theme.danger)
                            LineMark(x: .value("rpm", p.rpm), y: .value("lb-ft", p.torqueLbft), series: .value("s", "lb-ft"))
                                .foregroundStyle(Theme.accent)
                            LineMark(x: .value("rpm", p.rpm), y: .value("wheel hp", p.wheelHp), series: .value("s", "wheel hp"))
                                .foregroundStyle(Theme.danger.opacity(0.5))
                                .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 4]))
                        }
                    }
                    .chartXAxisLabel("rpm")
                    .frame(height: 240)
                    LabeledContent("Peak power", value: String(format: "%.0f hp @ %.0f rpm", r.peakHp, r.peakHpRpm))
                    LabeledContent("Peak torque", value: String(format: "%.0f lb-ft @ %.0f rpm", r.peakTq, r.peakTqRpm))
                    Text("Gear \(r.gear), speed from \(r.speedSource), \(r.points.count) points. Red: crank estimate; dashed: at the wheels; blue: torque.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if !note.isEmpty { Section { Text(note).foregroundStyle(.secondary) } }
            Section {
                if runs.isEmpty { Text("No saved runs yet.").foregroundStyle(.secondary) }
                ForEach(runs) { f in
                    Button {
                        Task { await open(f) }
                    } label: {
                        HStack {
                            Text(f.title).foregroundStyle(Theme.text)
                            Spacer()
                            if loadingRun == f.n { ProgressView() }
                            else if shown == f.n { Image(systemName: "checkmark").foregroundStyle(Theme.accent) }
                        }
                    }
                }
            } header: { Text("Saved runs on the gauge") } footer: {
                Text("Every recorded pull is kept on the gauge, so the web page and the app see the same runs.")
            }
            if !times.isEmpty {
                Section("Times from this run") {
                    if !fromStop { Text("0-60 and 0-100 need a run that starts from a stop.").font(.caption).foregroundStyle(.secondary) }
                    ForEach(times) { t in LabeledContent(t.name, value: t.seconds.map { String(format: "%.2f s", $0) } ?? "—") }
                }
            }
            Section {
                Stepper(value: $store.dyno.massKg, in: 900...2000, step: 10) { LabeledContent("Car + driver", value: "\(Int(store.dyno.massKg)) kg") }
                Stepper(value: $store.dyno.lossPct, in: 0...30, step: 1) { LabeledContent("Drivetrain loss", value: "\(Int(store.dyno.lossPct)) %") }
                Stepper(value: $store.dyno.cdA, in: 0.4...1.0, step: 0.01) { LabeledContent("Cd×A", value: String(format: "%.2f m²", store.dyno.cdA)) }
            } header: { Text("Car") } footer: { Text("Saved on the gauge: the web page's dyno uses the same numbers.") }
        }
        .navigationTitle("Dyno")
        .onChange(of: store.dynoCSV) { _, csv in shown = ""; compute(csv) }
        .onChange(of: store.dyno) { _, _ in
            compute(store.dynoCSV)
            push?.cancel()
            push = Task {                               // settle the steppers, then save on the gauge
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                if !Task.isCancelled { _ = await store.pushDynoCar() }
            }
        }
        .onChange(of: store.engine.dynoDone) { _, done in
            if done { store.send("dynocsv"); Task { try? await Task.sleep(nanoseconds: 1_500_000_000); await loadRuns() } }
        }
        .onAppear { if !store.dynoCSV.isEmpty { compute(store.dynoCSV) } }
        .task {
            await store.syncDynoCar()
            await loadRuns()
            if store.dynoCSV.isEmpty, let latest = runs.first, ProcessInfo.processInfo.arguments.contains("-screen") { await open(latest) }
        }
    }

    private func loadRuns() async {
        if let f = await store.fetch(GaugeFiles.self, "files") {
            runs = f.files.filter { $0.kind == .dyno }.sorted { $0.sortKey > $1.sortKey }
        }
    }

    private func open(_ f: GaugeFile) async {
        loadingRun = f.n
        defer { loadingRun = nil }
        switch await store.download(f, progress: { _ in }) {
        case .success(let url):
            if let csv = try? String(contentsOf: url, encoding: .utf8) { compute(csv); shown = f.n }
        case .failure(let e):
            note = "\(f.title): \(e.text)"
        }
    }

    private func compute(_ csv: String) {
        let rows = DynoMath.parseCSV(csv)
        let t = DynoMath.times(rows)
        times = rows.isEmpty ? [] : t.rows
        fromStop = t.fromStop
        switch DynoMath.compute(rows, store.dyno) {
        case .success(let r): result = r; note = ""
        case .failure(let f):
            result = nil
            switch f {
            case .tooFew: note = rows.isEmpty ? "No pull recorded yet." : "Too few samples."
            case .noGear: note = "No steady gear found in this run."
            case .notAccelerating: note = "Not enough accelerating samples (was it full throttle?)."
            }
        }
    }
}
