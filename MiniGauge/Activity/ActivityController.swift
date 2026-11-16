import Foundation
import ActivityKit
import UIKit

/// Starts, updates and ends the Live Activity. iOS only lets an app START one
/// while it is in the foreground; updates are fine from the background (the
/// Bluetooth background mode keeps the app running while connected).
final class ActivityController {
    private var activity: Activity<GaugeActivityAttributes>?
    private var lastSent: GaugeActivityAttributes.ContentState?
    private var lastAt = Date.distantPast

    var isRunning: Bool { activity != nil }

    init() {
        // Leftovers from a previous run (app killed while connected).
        Task {
            for a in Activity<GaugeActivityAttributes>.activities {
                await a.end(nil, dismissalPolicy: .immediate)
            }
        }
    }

    /// Start if allowed and not running. Returns false when iOS says no.
    @discardableResult
    func startIfPossible(_ state: GaugeActivityAttributes.ContentState) -> Bool {
        guard activity == nil else { return true }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return false }
        guard UIApplication.shared.applicationState == .active else { return false }
        do {
            activity = try Activity.request(attributes: GaugeActivityAttributes(title: "MiniGauge"),
                                            content: ActivityContent(state: state, staleDate: Date().addingTimeInterval(30)),
                                            pushType: nil)
            lastSent = state
            lastAt = Date()
            return true
        } catch {
            return false
        }
    }

    /// At most once a second, and only when something shown changed (the
    /// timestamp alone doesn't count, except every 20 s to keep it fresh).
    func update(_ state: GaugeActivityAttributes.ContentState) {
        guard let a = activity else { return }
        let now = Date()
        guard now.timeIntervalSince(lastAt) >= 1 else { return }
        var cmp = state
        cmp.updated = lastSent?.updated ?? state.updated
        if cmp == lastSent && now.timeIntervalSince(lastAt) < 20 { return }
        lastSent = state
        lastAt = now
        Task { await a.update(ActivityContent(state: state, staleDate: now.addingTimeInterval(30))) }
    }

    func end(final state: GaugeActivityAttributes.ContentState? = nil) {
        guard let a = activity else { return }
        activity = nil
        lastSent = nil
        Task {
            if let s = state {
                await a.end(ActivityContent(state: s, staleDate: nil), dismissalPolicy: .after(Date().addingTimeInterval(60)))
            } else {
                await a.end(nil, dismissalPolicy: .immediate)
            }
        }
    }
}
