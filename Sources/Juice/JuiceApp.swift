import ServiceManagement
import SwiftUI

struct JuiceApp: App {
    @State private var store: BatteryStore

    init() {
        let store = BatteryStore()
        store.start()
        _store = State(initialValue: store)
    }

    /// One menu bar item per device, inserted only while that device has a level to show.
    /// macOS animates a status item being inserted or removed (it fades, and its neighbours
    /// slide), so the app only flips `isInserted` and never animates the bar itself.
    var body: some Scene {
        MenuBarExtra(isInserted: inserted(.mouse)) {
            MenuView(store: store)
        } label: {
            BadgeLabel(badge: store.badge(.mouse))
        }
        .menuBarExtraStyle(.window)

        MenuBarExtra(isInserted: inserted(.headphones)) {
            MenuView(store: store)
        } label: {
            BadgeLabel(badge: store.badge(.headphones))
        }
        .menuBarExtraStyle(.window)

        // Keeps the app reachable while neither device is connected.
        MenuBarExtra(isInserted: Binding(get: { store.badges.isEmpty }, set: { _ in })) {
            MenuView(store: store)
        } label: {
            Image(systemName: "battery.100percent")
        }
        .menuBarExtraStyle(.window)
    }

    /// Read-only: dragging an item out of the menu bar cannot remove it.
    private func inserted(_ kind: DeviceReading.Kind) -> Binding<Bool> {
        Binding(get: { store.badge(kind) != nil }, set: { _ in })
    }
}

/// Menu bar label for one device: its SF Symbol and percentage.
///
/// The status item keeps only the string of a Text and drops interpolated images, so the row
/// is rendered to a template image, which also follows the menu bar's light or dark look.
private struct BadgeLabel: View {
    let badge: Badge?
    /// Kept after the device leaves, so the item still shows its number while it fades out.
    @State private var last: Badge?

    var body: some View {
        Group {
            if let image = (badge ?? last).flatMap(Self.render) {
                Image(nsImage: image)
            } else {
                Image(systemName: "battery.100percent")
            }
        }
        .onChange(of: badge, initial: true) {
            if let badge { last = badge }
        }
    }

    private static func render(_ badge: Badge) -> NSImage? {
        let row = HStack(spacing: 3) {
            Image(systemName: badge.symbol)
            Text("\(badge.level)%").monospacedDigit()
        }
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(.black)
        .fixedSize()

        let renderer = ImageRenderer(content: row)
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
        guard let image = renderer.nsImage else { return nil }
        image.isTemplate = true
        return image
    }
}

private struct MenuView: View {
    let store: BatteryStore
    @State private var openAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            DeviceRow(reading: store.mouse)
            DeviceRow(reading: store.headphones)
            Divider()
            HStack {
                Toggle("Open at Login", isOn: $openAtLogin)
                    .toggleStyle(.checkbox)
                    .onChange(of: openAtLogin) { _, enabled in setOpenAtLogin(enabled) }
                Spacer()
                Button("Refresh", systemImage: "arrow.clockwise") { store.refresh() }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help("Refresh now")
                Button("Quit", systemImage: "power") { NSApplication.shared.terminate(nil) }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help("Quit Juice")
            }
            .font(.callout)
        }
        .padding(14)
        .frame(width: 260)
        .onAppear { store.refresh() }
    }

    private func setOpenAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            openAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}

private struct DeviceRow: View {
    let reading: DeviceReading

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: reading.symbol)
                .font(.title3)
                .frame(width: 24)
                .foregroundStyle(reading.connected ? .primary : .tertiary)
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline) {
                    Text(reading.name).font(.headline)
                    Spacer()
                    Text(trailing)
                        .font(.headline.monospacedDigit())
                        .foregroundStyle(reading.level == nil ? .secondary : tint)
                }
                if let level = reading.level {
                    ProgressView(value: Double(level), total: 100)
                        .progressViewStyle(.linear)
                        .tint(tint)
                }
            }
        }
        .opacity(reading.connected ? 1 : 0.6)
    }

    private var trailing: String {
        if let level = reading.level { return reading.charging ? "⚡︎ \(level)%" : "\(level)%" }
        return reading.connected ? "Reading…" : "Not connected"
    }

    private var tint: Color {
        guard let level = reading.level else { return .secondary }
        if reading.charging { return .green }
        return level <= BatteryStore.lowThreshold ? .red : .primary
    }
}
