import Foundation
import Observation
import os
import UserNotifications

struct DeviceReading: Equatable {
    enum Kind { case mouse, headphones }

    let kind: Kind
    var name: String
    var level: Int?
    var charging = false
    var connected = false
    var updated: Date?

    var symbol: String { kind == .mouse ? "computermouse.fill" : "headphones" }

    /// Shown in the menu bar only when there is a number to show.
    var badge: Badge? {
        guard connected, let level else { return nil }
        return Badge(kind: kind, symbol: symbol, level: level)
    }
}

/// What the menu bar draws for one device.
struct Badge: Equatable {
    let kind: DeviceReading.Kind
    let symbol: String
    let level: Int
}

/// Device names default to the user's own hardware and can be changed with
/// `defaults write ai.pivotstudio.juice mouseName "..."` (or `headphonesName`).
@MainActor
@Observable
final class BatteryStore {
    static let lowThreshold = 20
    private static let rearmThreshold = 25

    private(set) var mouse: DeviceReading
    private(set) var headphones: DeviceReading

    var badges: [Badge] {
        [badge(.mouse), badge(.headphones)].compactMap { $0 }
    }

    /// The menu bar badge for one device, or nil while it has nothing to show.
    func badge(_ kind: DeviceReading.Kind) -> Badge? {
        guard !debugHidden.contains(kind) else { return nil }
        return kind == .mouse ? mouse.badge : headphones.badge
    }

    /// Debug builds only: posting the distributed notification
    /// `ai.pivotstudio.juice.debug.toggleMouse` (or `toggleHeadphones`) hides or shows that badge so menu bar
    /// transitions can be recorded without switching the mouse off.
    private var debugHidden: Set<DeviceReading.Kind> = []

    @ObservationIgnored private let log = Logger(subsystem: "ai.pivotstudio.juice", category: "store")
    @ObservationIgnored private var lastLogged: [Badge] = []

    /// Logs each change to what the menu bar shows: `log stream --predicate 'subsystem == "ai.pivotstudio.juice"' --level debug`.
    private func logBadges() {
        guard badges != lastLogged else { return }
        lastLogged = badges
        let text = badges.map { "\($0.kind)=\($0.level)%" }.joined(separator: " ")
        log.notice("menu bar: \(text.isEmpty ? "(none)" : text, privacy: .public)")
    }

    /// A headset reading this recent is shown the moment the headset reconnects, until the
    /// live reading replaces it a few seconds later.
    private static let carryOver: TimeInterval = 30 * 60

    @ObservationIgnored private let bose: BoseLink
    @ObservationIgnored private let mouseLink: MouseLink
    @ObservationIgnored private var mouseTask: Task<Void, Never>?
    @ObservationIgnored private var warned: Set<DeviceReading.Kind> = []
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        let mouseName = defaults.string(forKey: "mouseName") ?? "MX Master 3S"
        let headphonesName = defaults.string(forKey: "headphonesName") ?? "Atom"
        mouse = DeviceReading(kind: .mouse, name: mouseName)
        headphones = DeviceReading(kind: .headphones, name: headphonesName)
        bose = BoseLink(deviceName: headphonesName)
        mouseLink = MouseLink(deviceName: mouseName)
        self.defaults = defaults
    }

    func start(notify: Bool = true) {
        #if DEBUG
        for (name, kind) in [("toggleMouse", DeviceReading.Kind.mouse), ("toggleHeadphones", .headphones)] {
            DistributedNotificationCenter.default().addObserver(
                forName: Notification.Name("ai.pivotstudio.juice.debug.\(name)"), object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if self.debugHidden.contains(kind) { self.debugHidden.remove(kind) } else { self.debugHidden.insert(kind) }
                }
            }
        }
        #endif
        if notify {
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
        bose.onUpdate = { [weak self] state, level in
            self?.applyHeadphones(state: state, level: level, notify: notify)
        }
        bose.start()
        mouseLink.onUpdate = { [weak self] connected, level in
            self?.applyMouse(gattConnected: connected, gattLevel: level, notify: notify)
        }
        mouseLink.start()
        // MouseLink notices disconnects and reconnects itself; this only re-reads the level.
        mouseTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                self?.mouseLink.refresh()
            }
        }
    }

    func refresh() {
        mouseLink.refresh()
        bose.refresh()
    }

    /// GATT gives the level; the power-source entry, when macOS lists one, adds the charging
    /// flag and covers the level if the GATT read has not landed yet.
    private func applyMouse(gattConnected: Bool, gattLevel: Int?, notify: Bool) {
        let entry = PowerSources.entry(named: mouse.name)
        mouse.connected = gattConnected || entry != nil
        mouse.level = gattLevel ?? entry?.level ?? (mouse.connected ? mouse.level : nil)
        mouse.charging = entry?.charging ?? false
        if gattLevel != nil || entry != nil { mouse.updated = .now }
        logBadges()
        if notify { checkLow(mouse) }
    }

    private func applyHeadphones(state: BoseLink.State, level: Int?, notify: Bool) {
        headphones.connected = state == .linked || state == .connecting
        if !headphones.connected {
            headphones.level = nil
        } else if let level {
            headphones.level = level
            headphones.updated = .now
            defaults.set(level, forKey: "headphonesLastLevel")
            defaults.set(Date.now, forKey: "headphonesLastDate")
        } else if headphones.level == nil,
                  let date = defaults.object(forKey: "headphonesLastDate") as? Date,
                  Date.now.timeIntervalSince(date) < Self.carryOver,
                  defaults.object(forKey: "headphonesLastLevel") != nil {
            headphones.level = defaults.integer(forKey: "headphonesLastLevel")
            headphones.updated = date
        }
        logBadges()
        if notify { checkLow(headphones) }
    }

    /// One alert per discharge: re-armed once the level climbs back above 25%.
    private func checkLow(_ reading: DeviceReading) {
        guard let level = reading.level else { return }
        if level > Self.rearmThreshold || reading.charging {
            warned.remove(reading.kind)
            return
        }
        guard level <= Self.lowThreshold, !warned.contains(reading.kind) else { return }
        warned.insert(reading.kind)
        let content = UNMutableNotificationContent()
        content.title = "\(reading.name) at \(level)%"
        content.body = "Time to charge."
        content.sound = .default
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: "low-\(reading.kind)", content: content, trigger: nil)
        )
    }
}
