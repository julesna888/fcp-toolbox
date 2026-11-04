import AppKit
import FCPCore
import Foundation
import UserNotifications

/// Runs the rules the user switched on, every ten minutes while the app is alive (window open or menu bar only).
/// With the master switch off it does nothing at all: no scan, no disk access.
@MainActor
enum AutomationRunner {
    private static var timer: Timer?

    static func start() {
        guard timer == nil else { return }
        let t = Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { _ in
            Task { @MainActor in _ = await tick() }
        }
        t.tolerance = 120  // macOS can batch the wake-up with others
        timer = t
        Task { _ = await tick() }

        // Pool clips expire 30 days after import: a promise to the user, so it does not depend on the automations switch.
        let e = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { _ in
            Task.detached(priority: .utility) { await expireAndWarn() }
        }
        e.tolerance = 60
        expiryTimer = e
        Task.detached(priority: .utility) { await expireAndWarn() }

        // Performance history: one measurement every five minutes, and only while Final Cut is open.
        let p = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { _ in
            Task { @MainActor in sampleIfEditing() }
        }
        p.tolerance = 60
        perfTimer = p
    }

    /// Trashes the clips whose day has come, then warns (once a day) about the ones that go within three days.
    nonisolated private static func expireAndWarn() async {
        Doctor.expirePoolClips()
        let warnings = Doctor.poolExpiryWarnings()
        guard !warnings.isEmpty else { return }
        await MainActor.run { warnings.forEach(notify) }
    }

    private static var perfTimer: Timer?
    private static var expiryTimer: Timer?
    static let perfKey = "perfMonitorEnabled"

    static var perfMonitorEnabled: Bool {
        get { UserDefaults.standard.object(forKey: perfKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: perfKey) }
    }

    static func sampleIfEditing() {
        guard perfMonitorEnabled,
              NSWorkspace.shared.runningApplications.contains(where: { $0.bundleIdentifier == "com.apple.FinalCut" }) else { return }
        Task.detached(priority: .utility) { _ = Doctor.sample() }
    }

    /// One pass. Returns what was found, so the screen can show it too.
    @discardableResult
    static func tick() async -> [AutomationEvent] {
        let events = await Task.detached(priority: .utility) { () -> [AutomationEvent] in
            let config = Doctor.loadAutomationConfig()
            guard config.enabled else { return [] }
            var state = Doctor.loadAutomationState()
            let found = Doctor.runAutomations(config, state: &state)
            Doctor.saveAutomationState(state)
            return found
        }.value
        for e in events { notify(e) }
        return events
    }

    static func askPermission() {
        guard Bundle.main.bundleIdentifier != nil else { return }  // not inside an app bundle (swift run)
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private static func notify(_ e: AutomationEvent) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let c = UNMutableNotificationContent()
        c.title = e.title
        c.body = e.body
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: e.key, content: c, trigger: nil))
    }
}
