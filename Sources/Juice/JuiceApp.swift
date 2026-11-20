import ServiceManagement
import SwiftUI

struct JuiceApp: App {
    @State private var store: BatteryStore

    init() {
        let store = BatteryStore()
        store.start()
        _store = State(initialValue: store)
    }

    var body: some Scene {
        MenuBarExtra {
            MenuView(store: store)
        } label: {
            StatusLabel(store: store)
        }
        .menuBarExtraStyle(.window)
    }
}

/// Menu bar label: an SF Symbol and percentage per device that has a level, or a battery
/// icon while neither does.
///
/// The status item keeps only the string of a Text and drops interpolated images, so the row
/// is rendered to a template image, which also follows the menu bar's light or dark look.
///
/// macOS animates a status item's width change itself: it slides the item's content from the
/// old left edge to the new one. Changing the width more than once per transition restarts
/// that slide and stutters, so a transition fades slots at a fixed width, changes the width
/// in one step, waits for the system slide, then fades the new slots in.
private struct StatusLabel: View {
    let store: BatteryStore

    private struct Slot: Equatable {
        enum ID: Hashable { case device(DeviceReading.Kind), idle }
        let id: ID
        var badge: Badge?
        var opacity: Double
    }

    private static let fade: Duration = .milliseconds(180)
    /// How long macOS takes to finish sliding the item after its width changes.
    private static let settle: Duration = .milliseconds(500)

    @State private var slots: [Slot] = []
    @State private var transition: Task<Void, Never>?

    var body: some View {
        Group {
            if let image = Self.render(slots) {
                Image(nsImage: image)
            } else {
                Image(systemName: "battery.100percent")
            }
        }
        .onAppear { slots = Self.layout(store.badges, opacity: 1) }
        .onChange(of: store.badges) { _, badges in show(badges) }
    }

    private static func layout(_ badges: [Badge], opacity: Double) -> [Slot] {
        guard !badges.isEmpty else { return [Slot(id: .idle, badge: nil, opacity: opacity)] }
        return badges.map { Slot(id: .device($0.kind), badge: $0, opacity: opacity) }
    }

    private func show(_ badges: [Badge]) {
        let target = Self.layout(badges, opacity: 1)
        guard target.map(\.id) != slots.map(\.id) else {
            // Same devices, new levels: redraw in place and let any fade carry on.
            for index in slots.indices { slots[index].badge = target[index].badge }
            return
        }
        transition?.cancel()
        transition = Task { @MainActor in
            let staying = slots.map(\.id).filter { id in target.contains { $0.id == id } }
            // The system slide keeps the left edge of the content continuous. Slots that stay
            // can remain visible through it only if they lead both the old and the new row;
            // otherwise they would jump sideways, so the whole row fades out first.
            let stable = slots.map(\.id).starts(with: staying) && target.map(\.id).starts(with: staying)
            let kept = Set(stable ? staying : [])

            await fade(slots.map(\.id).filter { !kept.contains($0) }, to: 0)
            guard !Task.isCancelled else { return }

            let previous = Dictionary(uniqueKeysWithValues: slots.map { ($0.id, $0.opacity) })
            slots = target.map { slot in
                var slot = slot
                slot.opacity = kept.contains(slot.id) ? previous[slot.id] ?? 1 : 0
                return slot
            }
            try? await Task.sleep(for: Self.settle)
            guard !Task.isCancelled else { return }

            await fade(slots.map(\.id), to: 1)
        }
    }

    /// Fades the given slots as one Core Animation crossfade on the status item's button, so
    /// the compositor runs it at the display's refresh rate. MenuBarExtra does not expose its
    /// button, so it is looked up in the app's windows; if that ever fails the slots change
    /// without a fade.
    private func fade(_ ids: [Slot.ID], to target: Double) async {
        guard slots.contains(where: { ids.contains($0.id) && $0.opacity != target }) else { return }
        if let layer = Self.statusButton?.layer {
            let crossfade = CATransition()
            crossfade.type = .fade
            crossfade.duration = Self.fade / .seconds(1)
            crossfade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            layer.add(crossfade, forKey: "juice.fade")
        }
        for index in slots.indices where ids.contains(slots[index].id) {
            slots[index].opacity = target
        }
        try? await Task.sleep(for: Self.fade)
    }

    private static var statusButton: NSStatusBarButton? {
        func find(in view: NSView) -> NSStatusBarButton? {
            if let button = view as? NSStatusBarButton { return button }
            return view.subviews.lazy.compactMap(find).first
        }
        return NSApp.windows.lazy.compactMap { $0.contentView.flatMap(find) }.first
    }

    private static func render(_ slots: [Slot]) -> NSImage? {
        guard !slots.isEmpty else { return nil }
        let row = HStack(spacing: 8) {
            ForEach(slots, id: \.id) { slot in
                Group {
                    if let badge = slot.badge {
                        HStack(spacing: 3) {
                            Image(systemName: badge.symbol)
                            Text("\(badge.level)%").monospacedDigit()
                        }
                    } else {
                        Image(systemName: "battery.100percent")
                    }
                }
                .opacity(slot.opacity)
            }
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
