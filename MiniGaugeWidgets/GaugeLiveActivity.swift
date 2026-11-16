import ActivityKit
import SwiftUI
import WidgetKit

@main
struct MiniGaugeWidgetsBundle: WidgetBundle {
    var body: some Widget {
        GaugeLiveActivity()
    }
}

private enum WTheme {
    static let text = Color(red: 0.91, green: 0.93, blue: 0.95)
    static let muted = Color(red: 0.62, green: 0.66, blue: 0.71)
    static let accent = Color(red: 0.0, green: 0.898, blue: 1.0)
    static let warn = Color(red: 1.0, green: 0.69, blue: 0.125)
    static let danger = Color(red: 1.0, green: 0.176, blue: 0.333)
    static func level(_ l: Int) -> Color { l >= 2 ? danger : l == 1 ? warn : text }
}

struct GaugeLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: GaugeActivityAttributes.self) { context in
            ActivityContentView(state: context.state)
                .activityBackgroundTint(Color.black.opacity(0.82))
                .activitySystemActionForegroundColor(WTheme.accent)
        } dynamicIsland: { context in
            let t = context.state.tiles
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    if let a = t[safe: 0] { TileView(tile: a, size: 26) }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if let b = t[safe: 1] { TileView(tile: b, size: 26, trailing: true) }
                }
                DynamicIslandExpandedRegion(.center) {
                    if !context.state.gear.isEmpty {
                        Text("GEAR \(context.state.gear)").font(.caption.weight(.semibold)).foregroundStyle(WTheme.muted)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack {
                        if let c = t[safe: 2] { TileView(tile: c, size: 18) }
                        Spacer()
                        if let d = t[safe: 3] { TileView(tile: d, size: 18, trailing: true) }
                    }
                    StatusLine(state: context.state)
                }
            } compactLeading: {
                if let a = t[safe: 0] { CompactValue(tile: a) }
            } compactTrailing: {
                if let b = t[safe: 1] { CompactValue(tile: b) }
            } minimal: {
                if let a = t[safe: 0] {
                    Text(a.value).font(.caption2.weight(.semibold)).monospacedDigit()
                        .foregroundStyle(WTheme.level(a.level)).minimumScaleFactor(0.5)
                }
            }
        }
        // .small: the layout CarPlay (iOS 26) and the Apple Watch Smart Stack use.
        .supplementalActivityFamilies([.small])
    }
}

/// Lock Screen (.medium) and CarPlay / Watch (.small).
struct ActivityContentView: View {
    @Environment(\.activityFamily) private var family
    var state: GaugeActivityAttributes.ContentState

    var body: some View {
        switch family {
        case .small:
            SmallView(state: state)
        default:
            LockView(state: state)
        }
    }
}

struct LockView: View {
    var state: GaugeActivityAttributes.ContentState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 0) {
                ForEach(Array(state.tiles.prefix(4).enumerated()), id: \.offset) { _, tile in
                    TileView(tile: tile, size: 24)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            StatusLine(state: state)
        }
        .padding(14)
    }
}

/// 2x2 grid: small and glanceable (CarPlay dashboard, Watch).
struct SmallView: View {
    var state: GaugeActivityAttributes.ContentState

    var body: some View {
        let t = Array(state.tiles.prefix(4))
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                if let a = t[safe: 0] { TileView(tile: a, size: 18) .frame(maxWidth: .infinity, alignment: .leading) }
                if let b = t[safe: 1] { TileView(tile: b, size: 18) .frame(maxWidth: .infinity, alignment: .leading) }
            }
            HStack(spacing: 6) {
                if let c = t[safe: 2] { TileView(tile: c, size: 18) .frame(maxWidth: .infinity, alignment: .leading) }
                if let d = t[safe: 3] { TileView(tile: d, size: 18) .frame(maxWidth: .infinity, alignment: .leading) }
            }
            if !state.alarm.isEmpty {
                Text(state.alarm).font(.caption2.weight(.semibold)).foregroundStyle(WTheme.level(state.alarmLevel)).lineLimit(1)
            }
        }
        .padding(8)
    }
}

struct TileView: View {
    var tile: GaugeActivityAttributes.Tile
    var size: CGFloat
    var trailing = false

    var body: some View {
        VStack(alignment: trailing ? .trailing : .leading, spacing: 0) {
            Text(tile.label)
                .font(.system(size: max(9, size * 0.42), weight: .semibold))
                .foregroundStyle(WTheme.muted)
                .lineLimit(1)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(tile.value)
                    .font(.system(size: size, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(WTheme.level(tile.level))
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                if !tile.unit.isEmpty {
                    Text(tile.unit).font(.system(size: max(9, size * 0.45))).foregroundStyle(WTheme.muted).lineLimit(1)
                }
            }
        }
    }
}

struct CompactValue: View {
    var tile: GaugeActivityAttributes.Tile

    var body: some View {
        Text(tile.value)
            .font(.system(size: 14, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(tile.level > 0 ? WTheme.level(tile.level) : WTheme.accent)
            .minimumScaleFactor(0.6)
    }
}

struct StatusLine: View {
    var state: GaugeActivityAttributes.ContentState

    var body: some View {
        HStack(spacing: 6) {
            if !state.alarm.isEmpty {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(WTheme.level(state.alarmLevel))
                Text(state.alarm).foregroundStyle(WTheme.level(state.alarmLevel)).lineLimit(1)
            } else {
                Text(state.gear.isEmpty ? state.link : "Gear \(state.gear) · \(state.link)").foregroundStyle(WTheme.muted).lineLimit(1)
            }
            Spacer(minLength: 4)
            Text(state.updated, style: .time).foregroundStyle(WTheme.muted)
        }
        .font(.caption2)
    }
}
