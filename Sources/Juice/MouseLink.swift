@preconcurrency import CoreBluetooth
import os

/// Reads a Bluetooth LE mouse's level from the standard Battery Service (0x180F, Battery
/// Level 0x2A19). macOS also lists the MX Master 3S as a power source, but drops it from
/// that list for long stretches while the mouse stays connected; the GATT read does not.
///
/// The manager runs on the main queue, so every delegate callback arrives on main.
@MainActor
final class MouseLink: NSObject {
    var onUpdate: ((_ connected: Bool, _ level: Int?) -> Void)?

    private nonisolated static let batteryService = CBUUID(string: "180F")
    private nonisolated static let batteryLevel = CBUUID(string: "2A19")

    private let deviceName: String
    private var manager: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var characteristic: CBCharacteristic?
    private let log = Logger(subsystem: "ai.pivotstudio.juice", category: "mouse")
    private var rescanTask: Task<Void, Never>?

    init(deviceName: String) {
        self.deviceName = deviceName
    }

    func start() {
        manager = CBCentralManager(delegate: self, queue: .main)
    }

    func refresh() {
        log.debug("refresh: peripheral=\(self.peripheral != nil) state=\(self.peripheral?.state.rawValue ?? -1) characteristic=\(self.characteristic != nil)")
        if let peripheral, let characteristic, peripheral.state == .connected {
            peripheral.readValue(for: characteristic)
        } else {
            attach()
        }
    }

    /// The mouse is already connected to the system; retrieving it and connecting from this
    /// app shares that link rather than opening a new one.
    private func attach() {
        guard let manager, manager.state == .poweredOn else { return }
        guard let found = manager.retrieveConnectedPeripherals(withServices: [Self.batteryService])
            .first(where: { $0.name == deviceName })
        else {
            log.debug("attach: not among connected peripherals")
            detach()
            return
        }
        log.debug("attach: found, state=\(found.state.rawValue)")
        peripheral = found
        found.delegate = self
        switch found.state {
        case .connected: found.discoverServices([Self.batteryService])
        case .connecting: break
        default: manager.connect(found)
        }
    }

    /// Marks the mouse gone and watches for its return two ways: a pending CoreBluetooth
    /// connect to the same peripheral, which completes the moment the mouse reconnects to the
    /// Mac, and a 2 s look through the system's connected peripherals as a fallback.
    private func detach(pendingReconnect: CBPeripheral? = nil) {
        characteristic = nil
        peripheral = pendingReconnect
        if let pendingReconnect, let manager, manager.state == .poweredOn {
            manager.connect(pendingReconnect)
        }
        onUpdate?(false, nil)
        guard rescanTask == nil, manager?.state == .poweredOn else { return }
        rescanTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard let self, !Task.isCancelled, self.characteristic == nil else { break }
                self.attach()
            }
            self?.rescanTask = nil
        }
    }

    private func linked(_ found: CBCharacteristic) {
        characteristic = found
        rescanTask?.cancel()
        rescanTask = nil
    }
}

extension MouseLink: CBCentralManagerDelegate, CBPeripheralDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        MainActor.assumeIsolated {
            if central.state == .poweredOn { attach() } else { detach() }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        MainActor.assumeIsolated { log.debug("didConnect") }
        peripheral.discoverServices([Self.batteryService])
    }

    nonisolated func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: (any Error)?) {
        MainActor.assumeIsolated {
            log.debug("didFailToConnect: \(String(describing: error), privacy: .public)")
            detach()
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: (any Error)?) {
        MainActor.assumeIsolated {
            log.debug("didDisconnect: \(String(describing: error), privacy: .public)")
            detach(pendingReconnect: peripheral)
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: (any Error)?) {
        for service in peripheral.services ?? [] where service.uuid == Self.batteryService {
            peripheral.discoverCharacteristics([Self.batteryLevel], for: service)
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: (any Error)?) {
        guard let found = service.characteristics?.first(where: { $0.uuid == Self.batteryLevel }) else { return }
        MainActor.assumeIsolated { linked(found) }
        if found.properties.contains(.notify) { peripheral.setNotifyValue(true, for: found) }
        peripheral.readValue(for: found)
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: (any Error)?) {
        guard characteristic.uuid == Self.batteryLevel, error == nil,
              let byte = characteristic.value?.first, byte <= 100
        else { return }
        MainActor.assumeIsolated { onUpdate?(true, Int(byte)) }
    }
}
