import SwiftUI

enum Theme {
    static let bg = Color(red: 0.043, green: 0.051, blue: 0.063)
    static let card = Color(red: 0.082, green: 0.102, blue: 0.125)
    static let trough = Color(red: 0.094, green: 0.137, blue: 0.180)
    static let text = Color(red: 0.91, green: 0.93, blue: 0.95)
    static let muted = Color(red: 0.54, green: 0.59, blue: 0.64)
    static let accent = Color(red: 0.0, green: 0.898, blue: 1.0)
    static let warn = Color(red: 1.0, green: 0.69, blue: 0.125)
    static let danger = Color(red: 1.0, green: 0.176, blue: 0.333)
    static let ok = Color(red: 0.208, green: 0.78, blue: 0.349)

    static func level(_ l: Int) -> Color { l >= 2 ? danger : l == 1 ? warn : text }
}

extension Color {
    /// "#RRGGBB"
    init(hex: String) {
        let s = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        let v = UInt32(s, radix: 16) ?? 0xFFFFFF
        self.init(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }
}

struct Card<Content: View>: View {
    var title: String? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let t = title {
                Text(t.uppercased())
                    .font(.caption.weight(.semibold))
                    .tracking(0.8)
                    .foregroundStyle(Theme.muted)
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

/// Label above a big number with its unit.
struct ValueTile: View {
    var label: String
    var reading: Reading
    var level: Int = 0
    var size: CGFloat = 30
    var sub: String? = nil

    var body: some View {
        Card(title: label) {
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(reading.value)
                    .font(.system(size: size, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Theme.level(level))
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                if !reading.unit.isEmpty {
                    Text(reading.unit)
                        .font(.system(size: max(11, size * 0.4)))
                        .foregroundStyle(Theme.muted)
                        .lineLimit(1)
                }
            }
            if let sub = sub {
                Text(sub).font(.caption).foregroundStyle(Theme.muted).lineLimit(1)
            }
        }
    }
}

/// A metric as a tile.
struct MetricTile: View {
    @EnvironmentObject var store: GaugeStore
    var metric: Metric
    var size: CGFloat = 28
    var sub: String? = nil

    var body: some View {
        let s = store.snapshot
        ValueTile(label: metric.label, reading: s.reading(metric), level: s.level(metric), size: size, sub: sub)
    }
}

/// Line of recent values, zero line dashed.
struct Sparkline: View {
    var values: [Double]
    var color: Color = Theme.accent

    var body: some View {
        GeometryReader { geo in
            let lo = min(values.min() ?? 0, 0), hi = max(values.max() ?? 1, lo + 1)
            let w = geo.size.width, h = geo.size.height
            let y: (Double) -> CGFloat = { h - CGFloat(($0 - lo) / (hi - lo)) * h }
            ZStack {
                Path { p in
                    p.move(to: CGPoint(x: 0, y: y(0)))
                    p.addLine(to: CGPoint(x: w, y: y(0)))
                }
                .stroke(Theme.muted.opacity(0.4), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                if values.count > 1 {
                    Path { p in
                        for (i, v) in values.enumerated() {
                            let pt = CGPoint(x: w * CGFloat(i) / CGFloat(max(values.count - 1, 1)), y: y(v))
                            if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
                        }
                    }
                    .stroke(color, style: StrokeStyle(lineWidth: 2, lineJoin: .round))
                }
            }
        }
    }
}

/// Four ignition bars; a bar below the best cylinder is that cylinder
/// pulling timing (knock). Amber line: lowest in the last 10 s.
struct IgnitionBars: View {
    var ignition: [Double]?
    var retard: [Double]
    var height: CGFloat = 110

    private let lo = -5.0, hi = 45.0

    var body: some View {
        let best = ignition?.max() ?? 0
        HStack(alignment: .bottom, spacing: 12) {
            ForEach(0..<4, id: \.self) { c in
                let v = ignition?[c]
                let drop = v.map { best - $0 } ?? 0
                let col = drop > 2 ? Theme.danger : drop > 0.75 ? Theme.warn : Theme.accent
                VStack(spacing: 4) {
                    ZStack(alignment: .bottom) {
                        RoundedRectangle(cornerRadius: 6).fill(Theme.trough)
                        if let v = v {
                            RoundedRectangle(cornerRadius: 6).fill(col)
                                .frame(height: max(3, height * CGFloat(min(max((v - lo) / (hi - lo), 0), 1))))
                            if retard[c] > 0.5 {
                                let peakAt = min(max(((v - retard[c]) - lo) / (hi - lo), 0), 1)
                                Rectangle().fill(Theme.warn).frame(height: 3)
                                    .offset(y: -height * CGFloat(peakAt))
                            }
                        }
                    }
                    .frame(height: height)
                    Text(v.map { String(format: "%.1f°", $0) } ?? "--")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(drop > 2 ? Theme.danger : Theme.text)
                    Text("cyl \(c + 1)").font(.caption2).foregroundStyle(Theme.muted)
                }
                .frame(maxWidth: .infinity)
            }
        }
    }
}

/// The gauge's own dial for one slot: arc with its zones and the value.
struct ArcGauge: View {
    var slot: GaugeInfo.Slot?
    var value: GaugeSlotValue?
    var fallbackName: String
    var sign: String? = nil              // speed-limit sign: the limit, or "?"

    var body: some View {
        let mn = slot?.min ?? 0, mx = max(slot?.max ?? 100, mn + 1)
        let frac = value.map { min(max(($0.value - mn) / (mx - mn), 0), 1) } ?? 0
        // The colour of the zone the value is in, as on the gauge (v5.12+);
        // older firmware only says warning / critical.
        let zoneCol: Color? = value.flatMap { v in v.zone.flatMap { zi in
            (slot?.zones ?? []).enumerated().first { ($0.element.z ?? $0.offset) == zi }.map { Color(hex: $0.element.color) } } }
        let col: Color = zoneCol ?? ((value?.critical ?? false) ? Theme.danger : (value?.warn ?? false) ? Theme.warn : Theme.accent)
        let dec = slot?.d ?? 0
        Card {
            VStack(spacing: 2) {
                ZStack {
                    Circle().trim(from: 0, to: 0.75)
                        .stroke(Theme.trough, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                        .rotationEffect(.degrees(135))
                    ForEach(Array((slot?.zones ?? []).enumerated()), id: \.offset) { _, z in
                        let a = min(max((z.from - mn) / (mx - mn), 0), 1), b = min(max((z.to - mn) / (mx - mn), 0), 1)
                        Circle().trim(from: 0.75 * a, to: 0.75 * b)
                            .stroke(Color(hex: z.color).opacity(0.55), style: StrokeStyle(lineWidth: 10))
                            .rotationEffect(.degrees(135))
                    }
                    Circle().trim(from: 0, to: 0.75 * frac)
                        .stroke(col, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                        .rotationEffect(.degrees(135))
                        .padding(3)
                    VStack(spacing: 0) {
                        Text(value?.valid == true ? String(format: "%.\(dec)f", value!.value) : "--")
                            .font(.system(size: 26, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(col == Theme.accent ? Theme.text : col)
                            .lineLimit(1)
                            .minimumScaleFactor(0.5)
                        Text(slot?.unit ?? "").font(.caption).foregroundStyle(Theme.muted)
                    }
                }
                .frame(height: 120)
                .overlay(alignment: .topTrailing) { if let s = sign { LimitSign(text: s) } }
                .padding(.horizontal, 8)
                Text(slot?.name ?? fallbackName)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Theme.muted)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .frame(maxWidth: .infinity)
        }
    }
}

/// A small US-style SPEED LIMIT sign.
struct LimitSign: View {
    var text: String
    var body: some View {
        VStack(spacing: 0) {
            Text("SPEED").font(.system(size: 6, weight: .bold))
            Text("LIMIT").font(.system(size: 6, weight: .bold))
            Text(text).font(.system(size: 15, weight: .bold, design: .rounded)).monospacedDigit()
        }
        .foregroundStyle(.black)
        .padding(.horizontal, 4)
        .padding(.vertical, 3)
        .frame(minWidth: 30)
        .background(RoundedRectangle(cornerRadius: 4).fill(.white))
        .overlay(RoundedRectangle(cornerRadius: 4).inset(by: 1.5).stroke(.black, lineWidth: 1))
        .accessibilityLabel(text == "?" ? "Speed limit unknown"
                            : text.hasPrefix("~") ? "Speed limit about \(text.dropFirst())" : "Speed limit \(text)")
    }
}

/// Shown at the top of screens while there's no live data.
struct ConnectionBanner: View {
    @EnvironmentObject var store: GaugeStore

    var body: some View {
        if store.conn != .connected && store.conn != .demo {
            HStack(spacing: 10) {
                if store.conn == .scanning || store.conn == .connecting { ProgressView().tint(Theme.accent) }
                else { Image(systemName: "antenna.radiowaves.left.and.right.slash").foregroundStyle(Theme.warn) }
                VStack(alignment: .leading, spacing: 2) {
                    Text(store.connText).font(.subheadline.weight(.semibold))
                    Text(store.isAdapter ? "Straight to your Bluetooth OBD adapter: plugged in, key on, gauge off the K-line."
                                         : "The gauge streams over Bluetooth. Key on, gauge powered.")
                        .font(.caption).foregroundStyle(Theme.muted)
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        } else if store.conn == .connected && store.engine.link != .bmw && store.engine.link != .obd {
            HStack(spacing: 10) {
                ProgressView().tint(Theme.accent)
                Text(store.status.linkText.isEmpty ? (store.isAdapter ? "Adapter connected, waking the car…" : "Gauge connected, waiting for the car…")
                                                   : store.status.linkText)
                    .font(.subheadline)
                Spacer(minLength: 0)
            }
            .padding(12)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }
}
