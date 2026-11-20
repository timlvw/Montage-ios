import SwiftUI
import UIKit

// The gauge's own files, settings and layout: the same things its web page
// offers, through the same functions on the gauge (gauge_admin.cpp).

/// Cloud-build diagnostics: counts body evaluations (a runaway count means an
/// update loop) and prints what changed, only with -diag.
enum Diag {
    static let on = ProcessInfo.processInfo.arguments.contains("-diag")
    static var counts: [String: Int] = [:]
    static func body<V: View>(_ name: String, _ t: V.Type) {
        guard on else { return }
        let n = (counts[name] ?? 0) + 1
        counts[name] = n
        if n <= 20 || n % 200 == 0 { write("\(name) body #\(n)") }
    }
    static func note(_ s: String) { if on { write(s) } }
    /// stderr is unbuffered, so the lines survive the app being stopped.
    private static func write(_ s: String) { FileHandle.standardError.write(Data(("[MG] " + s + "\n").utf8)) }
}

private func kb(_ k: Int) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(k) * 1024, countStyle: .file)
}

extension Color {
    /// "RRGGBB" for the gauge.
    var hex6: String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(self).getRed(&r, green: &g, blue: &b, alpha: &a)
        func c(_ v: CGFloat) -> Int { Int((min(max(v, 0), 1) * 255).rounded()) }
        return String(format: "%02X%02X%02X", c(r), c(g), c(b))
    }
}

// MARK: - files

struct GaugeFilesView: View {
    // not observed: these pages only ask the gauge, and the live data
    // (10 updates a second) must not redraw them
    private var store: GaugeStore { GaugeStore.shared }
    var onOpenDyno: ((String) -> Void)? = nil
    @State private var files: GaugeFiles?
    @State private var loading = false
    @State private var error = ""
    @State private var progress: [String: Double] = [:]
    @State private var saved: [String: URL] = [:]
    @State private var confirmDelete: GaugeFile?

    var body: some View {
        let _ = Diag.body("files", Self.self)
        List {
            if let f = files {
                Section {
                    LabeledContent("Free", value: "\(kb(f.freeKB)) of \(kb(f.totalKB))")
                } footer: {
                    Text("Tap a file to copy it to this phone (Files app → MiniGauge → Gauge), then share it. The oldest drive recordings make room when space runs low.")
                }
                group("Gauge logs", .log, f)
                group("Drive recordings", .drive, f)
                group("Dyno runs", .dyno, f)
                group("Other", .other, f)
            } else if loading {
                HStack { ProgressView(); Text("Asking the gauge…").foregroundStyle(.secondary) }
            }
            if !error.isEmpty { Section { Text(error).foregroundStyle(Theme.warn) } }
        }
        .navigationTitle("Gauge files")
        .refreshable { await load() }
        .task { await load() }
        .alert("Delete \(confirmDelete?.title ?? "")?", isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } })) {
            Button("Delete", role: .destructive) { if let f = confirmDelete { Task { await delete(f) } }; confirmDelete = nil }
            Button("Cancel", role: .cancel) { confirmDelete = nil }
        } message: { Text("It's removed from the gauge. A copy already on this phone stays.") }
    }

    @ViewBuilder private func group(_ title: String, _ kind: GaugeFile.Kind, _ f: GaugeFiles) -> some View {
        let items = f.files.filter { $0.kind == kind }.sorted { $0.sortKey > $1.sortKey }
        if !items.isEmpty {
            Section(title) {
                ForEach(items) { file in row(file) }
                    .onDelete { idx in confirmDelete = idx.map { items[$0] }.first }
            }
        }
    }

    private func row(_ file: GaugeFile) -> some View {
        HStack(spacing: 12) {
            Image(systemName: file.kind == .dyno ? "speedometer" : file.kind == .drive ? "car" : "tablecells")
                .foregroundStyle(Theme.accent).frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(file.title).font(.subheadline)
                HStack(spacing: 6) {
                    Text(ByteCountFormatter.string(fromByteCount: Int64(file.s), countStyle: .file))
                    if file.busy == "rec" { Text("recording").foregroundStyle(Theme.danger) }
                    if file.busy == "log" { Text("logging now").foregroundStyle(Theme.danger) }
                }
                .font(.caption).foregroundStyle(.secondary)
                if let p = progress[file.n] { ProgressView(value: p).tint(Theme.accent) }
            }
            Spacer()
            if let url = saved[file.n] {
                if file.kind == .dyno, let open = onOpenDyno {
                    Button("Open") { if let t = try? String(contentsOf: url, encoding: .utf8) { open(t) } }.buttonStyle(.bordered)
                }
                ShareLink(item: url) { Image(systemName: "square.and.arrow.up") }.buttonStyle(.borderless)
            } else if progress[file.n] == nil {
                Button { Task { await fetch(file) } } label: { Image(systemName: "arrow.down.circle") }
                    .buttonStyle(.borderless)
                    .disabled(file.busy == "log")
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { if saved[file.n] == nil && progress[file.n] == nil && file.busy != "log" { Task { await fetch(file) } } }
    }

    private func load() async {
        Diag.note("files load start")
        loading = true
        defer { loading = false; Diag.note("files load end") }
        if let f = await store.fetch(GaugeFiles.self, "files") {
            files = f
            error = ""
            // copies already on the phone (same size: the file hasn't grown since)
            for file in f.files {
                let url = GaugeStore.downloadFolder.appendingPathComponent(file.n)
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -1
                if size == file.s && file.busy.isEmpty { saved[file.n] = url } else { saved[file.n] = nil }
            }
        } else {
            error = store.isLive ? "The gauge didn't answer. Pull down to try again." : "Not connected to the gauge."
        }
    }

    private func fetch(_ file: GaugeFile) async {
        progress[file.n] = 0
        let r = await store.download(file) { p in progress[file.n] = p }
        progress[file.n] = nil
        switch r {
        case .success(let url): saved[file.n] = url; error = ""
        case .failure(let e): error = "\(file.title): \(e.text)"
        }
    }

    private func delete(_ file: GaugeFile) async {
        if let e = await store.act("fdel \(file.n)") { error = e }
        await load()
    }
}

// MARK: - settings

struct GaugeSettingsView: View {
    // not observed: these pages only ask the gauge, and the live data
    // (10 updates a second) must not redraw them
    private var store: GaugeStore { GaugeStore.shared }
    @State private var s: GaugeSettings?
    @State private var error = ""
    @State private var confirmRestart = false

    var body: some View {
        let _ = Diag.body("settings", Self.self)
        Form {
            if let st = s {
                Section {
                    toggle("Temperature in °F", st.tempF) { "tempF=\($0 ? 1 : 0)" }
                    toggle("Speed in mph", st.speedMph) { "speedMph=\($0 ? 1 : 0)" }
                    toggle("Pressure in psi", st.pressPsi) { "pressPsi=\($0 ? 1 : 0)" }
                } header: { Text("Units on the gauge") } footer: {
                    Text("Gauge ranges move with the unit. The app's own units are under More → Settings.")
                }
                Section {
                    toggle("Log automatically while the engine runs", st.logAuto) { "logAuto=\($0 ? 1 : 0)" }
                    LabeledContent("Gauge log", value: st.logActive ? st.logFile : "not logging")
                    Button(st.logActive ? "Stop logging now" : "Start logging now") {
                        Task { error = await store.act(st.logActive ? "log stop" : "log start") ?? ""; try? await Task.sleep(nanoseconds: 600_000_000); await load() }
                    }
                    toggle("Drive recorder", st.recOn) { "rec=\($0 ? 1 : 0)" }
                    LabeledContent("Recorder", value: !st.recOn ? "off" : st.recActive ? st.recFile : "waiting for the engine")
                    LabeledContent("Engine", value: st.engine ? "running" : "not running")
                } header: { Text("Logging") } footer: {
                    Text("A gauge log and a drive recording for each engine run, from start until it has been off for 30 s. Not with just the key on.")
                }
                Section {
                    Picker("Protocol", selection: Binding(get: { st.klproto }, set: { v in set("klproto=\(v)") })) {
                        Text("BMW blocks, OBD fallback").tag(0)
                        Text("OBD only").tag(1)
                        Text("BMW only").tag(2)
                    }
                    Picker("Wiring", selection: Binding(get: { st.klpins }, set: { v in set("klpins=\(v)") })) {
                        Text(st.wiringName(0)).tag(0)
                        Text(st.wiringName(1)).tag(1)
                    }
                    if !st.klmode.isEmpty { LabeledContent("Talking", value: st.klmode) }
                    if st.restartNeeded {
                        Text("The new wiring applies after a restart.").foregroundStyle(Theme.warn)
                    }
                    Button("Restart the gauge", role: .destructive) { confirmRestart = true }
                } header: { Text("K-line") }
                if let w = st.wifi {
                    Section {
                        toggle("Wi-Fi", w) { "wifi=\($0 ? 1 : 0)" }
                        if st.wifiRestartNeeded {
                            Text(w ? "Wi-Fi comes on after a restart." : "Wi-Fi goes off after a restart.").foregroundStyle(Theme.warn)
                            Button("Restart now", role: .destructive) { confirmRestart = true }
                        }
                    } header: { Text("Gauge Wi-Fi") } footer: {
                        Text("The gauge's web page, web updates and the overhead display use Wi-Fi. Off leaves more memory for Bluetooth. The app works either way; it uses Bluetooth.")
                    }
                }
                Section {
                    LabeledContent("Storage", value: "\(kb(st.freeKB)) free of \(kb(st.totalKB))")
                }
            } else if error.isEmpty {
                HStack { ProgressView(); Text("Asking the gauge…").foregroundStyle(.secondary) }
            }
            if !error.isEmpty { Section { Text(error).foregroundStyle(Theme.warn) } }
        }
        .navigationTitle("Gauge settings")
        .task { await load() }
        .refreshable { await load() }
        .confirmationDialog("Restart the gauge?", isPresented: $confirmRestart, titleVisibility: .visible) {
            Button("Restart", role: .destructive) { Task { _ = await store.request("restart", timeout: 3) } }
        } message: { Text("It's back in about 10 seconds and the app reconnects by itself.") }
    }

    private func toggle(_ title: String, _ value: Bool, _ arg: @escaping (Bool) -> String) -> some View {
        Toggle(title, isOn: Binding(get: { value }, set: { set(arg($0)) }))
    }

    private func set(_ args: String) {
        Task {
            error = await store.act("set " + args) ?? ""
            await load()
            store.send("info")                     // units and slots may have changed
        }
    }

    private func load() async {
        if let v = await store.fetch(GaugeSettings.self, "settings") { s = v; if error.hasPrefix("The gauge") || error.hasPrefix("Not") { error = "" } }
        else if s == nil { error = store.isLive ? "The gauge didn't answer. Pull down to try again." : "Not connected to the gauge." }
    }
}

// MARK: - layout

@MainActor
final class LayoutModel: ObservableObject {
    @Published var config: GaugeConfig?
    @Published var pids: [PidInfo] = []
    @Published var themes: [ThemeInfo] = []
    @Published var error = ""

    func name(_ pid: Int) -> String { pids.first { $0.pid == pid }?.name ?? "PID \(pid)" }
    func unit(_ pid: Int) -> String { pids.first { $0.pid == pid }?.unit ?? "" }
    func slotName(_ i: Int) -> String {
        guard let c = config, i >= 0, i < c.slots.count else { return "—" }
        let s = c.slots[i]
        return s.label.isEmpty ? name(s.pid) : s.label
    }

    /// Only what changed is published, so a reload with the same answer
    /// doesn't redraw the page.
    func load(_ store: GaugeStore) async {
        Diag.note("layout load")
        if pids.isEmpty, let p = await store.fetch([PidInfo].self, "pids"), p != pids { pids = p }
        if let c = await store.fetch(GaugeConfig.self, "config") {
            if c != config { config = c }
            if !error.isEmpty { error = "" }
        } else if config == nil {
            let e = store.isLive ? "The gauge didn't answer. Pull down to try again." : "Not connected to the gauge."
            if e != error { error = e }
        }
        if let t = await store.fetch([ThemeInfo].self, "themes"), t != themes { themes = t }
        Diag.note("layout loaded: \(config?.slots.count ?? -1) gauges, \(pids.count) values, \(themes.count) themes")
    }

    /// Run one or more commands, then reload; the gauge redraws by itself.
    func run(_ store: GaugeStore, _ cmds: [String]) async {
        var err = ""
        for c in cmds { if let e = await store.act(c) { err = e; break } }
        if err != error { error = err }
        await load(store)
        store.send("info")
    }
}

struct GaugeLayoutView: View {
    // not observed: these pages only ask the gauge, and the live data
    // (10 updates a second) must not redraw them
    private var store: GaugeStore { GaugeStore.shared }
    @StateObject private var m = LayoutModel()

    var body: some View {
        let _ = Diag.body("layout", Self.self)
        List {
            if let c = m.config {
                Section {
                    ForEach(Array(c.slots.enumerated()), id: \.offset) { i, s in
                        NavigationLink { SlotEditView(m: m, index: i) } label: {
                            HStack {
                                Circle().fill(Color(hex: s.arc)).frame(width: 10, height: 10)
                                VStack(alignment: .leading) {
                                    Text(s.label.isEmpty ? m.name(s.pid) : s.label)
                                    Text("\(fmt(s.min)) – \(fmt(s.max)) \(m.unit(s.pid))\(s.en ? "" : " · hidden")")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    .onMove { from, to in
                        guard let src = from.first else { return }
                        let dst = to > src ? to - 1 : to
                        let step = dst > src ? 1 : -1
                        var cmds: [String] = []
                        var at = src
                        while at != dst { cmds.append("slot move i=\(at)&d=\(step)"); at += step }
                        Task { await m.run(store, cmds) }
                    }
                    .onDelete { idx in
                        let cmds = idx.sorted(by: >).map { "slot del i=\($0)" }
                        Task { await m.run(store, cmds) }
                    }
                    if c.slots.count < 8 {
                        Menu {
                            ForEach(m.pids) { p in
                                Button("\(p.name) (\(p.unit))") { Task { await m.run(store, ["slot add pid=\(p.pid)"]) } }
                            }
                        } label: { Label("Add a gauge", systemImage: "plus.circle") }
                    }
                } header: { Text("Gauges (swipe through them on the gauge)") } footer: {
                    Text("Drag to reorder (Edit), swipe to remove. Up to 8.")
                }
                Section {
                    ForEach(0..<4, id: \.self) { q in
                        Picker(["Top left", "Top right", "Bottom left", "Bottom right"][q],
                               selection: Binding(get: { q < c.combo.count ? c.combo[q] : -1 },
                                                  set: { v in
                                                      // only a real choice goes to the gauge
                                                      let now = q < c.combo.count ? c.combo[q] : -1
                                                      guard v != now else { return }
                                                      Diag.note("combo q\(q) \(now) -> \(v)")
                                                      Task { await m.run(store, ["combo q\(q)=\(v)"]) }
                                                  })) {
                            Text("Empty").tag(-1)
                            ForEach(Array(c.slots.indices), id: \.self) { i in Text(m.slotName(i)).tag(i) }
                        }
                    }
                } header: { Text("Four-up screen") }
                if !m.themes.isEmpty {
                    Section {
                        ForEach(m.themes) { t in
                            HStack {
                                ForEach(Array([t.arc, t.needle, t.text, t.bg].enumerated()), id: \.offset) { _, h in
                                    Circle().fill(Color(hex: h)).frame(width: 12, height: 12).overlay(Circle().stroke(.gray.opacity(0.4)))
                                }
                                Text(t.n)
                            }
                        }
                        .onDelete { idx in
                            let cmds = idx.map { "theme del t=\(m.themes[$0].t)" }.sorted(by: >)
                            Task { await m.run(store, cmds) }
                        }
                    } header: { Text("Saved themes") } footer: { Text("Apply one, or save a gauge's look, from the gauge's page.") }
                }
            } else if m.error.isEmpty {
                HStack { ProgressView(); Text("Asking the gauge…").foregroundStyle(.secondary) }
            }
            if !m.error.isEmpty { Section { Text(m.error).foregroundStyle(Theme.warn) } }
        }
        .navigationTitle("Gauge layout")
        .toolbar { EditButton() }
        .task { await m.load(store) }
        .refreshable { await m.load(store) }
    }

    private func fmt(_ v: Double) -> String { v == v.rounded() ? String(format: "%.0f", v) : String(format: "%.1f", v) }
}

struct SlotEditView: View {
    // not observed: these pages only ask the gauge, and the live data
    // (10 updates a second) must not redraw them
    private var store: GaugeStore { GaugeStore.shared }
    @ObservedObject var m: LayoutModel
    let index: Int
    @State private var edit: SlotConfig?
    @State private var original: SlotConfig?
    @State private var saving = false
    @State private var themeName = ""
    @State private var askTheme = false

    var body: some View {
        Form {
            if let binding = Binding($edit) {
                Section {
                    Picker("Shows", selection: binding.pid) {
                        ForEach(m.pids) { p in Text(p.sup ? p.name : "\(p.name) (not on this car)").tag(p.pid) }
                    }
                    Toggle("On the gauge", isOn: binding.en)
                    TextField("Label (blank: \(m.name(binding.wrappedValue.pid)))", text: binding.label)
                }
                Section {
                    numberRow("Low end", binding.min)
                    numberRow("High end", binding.max)
                    Stepper(value: binding.dec, in: -1...3) {
                        LabeledContent("Decimals", value: binding.wrappedValue.dec < 0 ? "auto" : "\(binding.wrappedValue.dec)")
                    }
                    Stepper(value: binding.ticks, in: 2...41) { LabeledContent("Ticks", value: "\(binding.wrappedValue.ticks)") }
                    Stepper(value: binding.major, in: 1...10) { LabeledContent("Number every", value: "\(binding.wrappedValue.major) ticks") }
                } header: { Text("Scale (\(m.unit(binding.wrappedValue.pid)))") } footer: {
                    if binding.wrappedValue.pid != original?.pid { Text("A new value starts from its own default range and zones.") }
                }
                Section("Colours") {
                    colorRow("Arc", binding.arc)
                    colorRow("Needle", binding.needle)
                    colorRow("Numbers", binding.text)
                    colorRow("Background", binding.bg)
                    if !m.themes.isEmpty {
                        Menu("Apply a saved theme") {
                            ForEach(m.themes) { t in Button(t.n) { Task { await m.run(store, ["theme apply i=\(index)&t=\(t.t)"]); reset() } } }
                        }
                    }
                    Button("Save this look as a theme…") { askTheme = true }
                }
                ForEach(0..<min(2, binding.wrappedValue.z.count), id: \.self) { z in
                    Section(z == 0 ? "Red zone" : "Amber zone") {
                        Toggle("On", isOn: binding.z[z].on)
                        if binding.wrappedValue.z[z].on {
                            numberRow("From", binding.z[z].from)
                            numberRow("To", binding.z[z].to)
                            colorRow("Colour", binding.z[z].col)
                        }
                    }
                }
            }
            if !m.error.isEmpty { Section { Text(m.error).foregroundStyle(Theme.warn) } }
        }
        .navigationTitle(m.slotName(index))
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(saving ? "Saving…" : "Save") { Task { await save() } }.disabled(edit == original || saving)
            }
        }
        .onAppear(perform: reset)
        .alert("Theme name", isPresented: $askTheme) {
            TextField("Name", text: $themeName)
            Button("Save") { let n = themeName; Task { await m.run(store, ["theme save " + AdminQuery.encode([("i", "\(index)"), ("name", n)])]) } }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func reset() {
        guard let c = m.config, index < c.slots.count else { return }
        edit = c.slots[index]
        original = c.slots[index]
    }

    private func numberRow(_ title: String, _ v: Binding<Double>) -> some View {
        LabeledContent(title) {
            TextField(title, value: v, format: .number.precision(.fractionLength(0...2)))
                .keyboardType(.numbersAndPunctuation)
                .multilineTextAlignment(.trailing)
        }
    }

    private func colorRow(_ title: String, _ hex: Binding<String>) -> some View {
        ColorPicker(title, selection: Binding(get: { Color(hex: hex.wrappedValue) }, set: { hex.wrappedValue = $0.hex6 }), supportsOpacity: false)
    }

    /// Only what changed goes to the gauge, split into commands that fit.
    private func save() async {
        guard let e = edit, let o = original else { return }
        saving = true
        defer { saving = false }
        var p: [(String, String)] = []
        func num(_ v: Double) -> String { String(format: "%.2f", v) }
        if e.pid != o.pid { p.append(("pid", "\(e.pid)")) }            // first: it resets the face
        if e.en != o.en { p.append(("en", e.en ? "1" : "0")) }
        if e.label != o.label { p.append(("label", e.label)) }
        if e.min != o.min || e.pid != o.pid { p.append(("min", num(e.min))) }
        if e.max != o.max || e.pid != o.pid { p.append(("max", num(e.max))) }
        if e.dec != o.dec { p.append(("dec", "\(e.dec)")) }
        if e.ticks != o.ticks { p.append(("ticks", "\(e.ticks)")) }
        if e.major != o.major { p.append(("major", "\(e.major)")) }
        for (k, a, b) in [("arc", e.arc, o.arc), ("needle", e.needle, o.needle), ("text", e.text, o.text), ("bg", e.bg, o.bg)] where a != b { p.append((k, a)) }
        for z in 0..<min(e.z.count, o.z.count) {
            let a = e.z[z], b = o.z[z]
            if a.on != b.on { p.append(("z\(z)on", a.on ? "1" : "0")) }
            if a.from != b.from { p.append(("z\(z)from", num(a.from))) }
            if a.to != b.to { p.append(("z\(z)to", num(a.to))) }
            if a.col != b.col { p.append(("z\(z)col", a.col)) }
        }
        if e.pid != o.pid {
            // a new PID re-seeds the face on the gauge: send just that, then the
            // rest on top of its defaults
            await m.run(store, ["slot i=\(index)&pid=\(e.pid)"])
            p.removeFirst()
            p.removeAll { $0.0 == "min" || $0.0 == "max" }
            if e.min != o.min { p.append(("min", num(e.min))) }
            if e.max != o.max { p.append(("max", num(e.max))) }
        }
        if !p.isEmpty { await m.run(store, AdminQuery.commands("slot", fixed: [("i", "\(index)")], pairs: p)) }
        reset()
    }
}
