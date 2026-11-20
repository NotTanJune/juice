import CoreAudio
import Foundation
@preconcurrency import IOBluetooth
import JuiceCore
import os

/// Holds one RFCOMM channel to a Bose headset and asks it for its battery level over BMAP.
///
/// macOS does not surface Bose battery levels, so this talks to the headset directly. The
/// channel stays open between polls: reopening right after a close often fails with
/// kIOReturnError for a while, so a persistent link with backoff reconnects is far more
/// reliable than open, ask, close.
///
/// Whether the headset is connected comes from Core Audio, not IOBluetooth. On macOS 27.2,
/// any IOBluetooth call that enumerates paired devices (`pairedDevices()`,
/// `register(forConnectNotifications:)`) makes `isConnected()` read false for this headset
/// for the rest of the process. A connected Bluetooth headset is always a Core Audio device
/// whose UID starts with its address, and Core Audio reports device-list changes.
@MainActor
final class BoseLink: NSObject {
    enum State: Equatable {
        case notPaired
        case disconnected
        case connecting
        case linked
    }

    var onUpdate: ((State, Int?) -> Void)?

    private let deviceName: String
    private let log = Logger(subsystem: "ai.pivotstudio.juice", category: "bose")
    private var channel: IOBluetoothRFCOMMChannel?
    private var opening = false
    private var parser = BMAPStreamParser()
    private var retryDelay: Duration = .seconds(2)
    private var retryTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    private var audioListener: AudioObjectPropertyListenerBlock?
    private(set) var state: State = .disconnected
    private(set) var level: Int?
    private let tracing = ProcessInfo.processInfo.environment["JUICE_TRACE"] != nil

    /// Each step goes to the unified log; `JUICE_TRACE=1` also prints it to stderr.
    private func trace(_ message: String) {
        log.debug("\(message, privacy: .public)")
        if tracing { FileHandle.standardError.write(Data("bose: \(message)\n".utf8)) }
    }

    /// Time between battery requests while the link is up.
    var pollInterval: Duration = .seconds(120)

    init(deviceName: String) {
        self.deviceName = deviceName
    }

    func start() {
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated { self?.audioDevicesChanged() }
        }
        var address = Self.devicesAddress
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, listener)
        audioListener = listener
        connect()
    }

    func refresh() {
        if channel != nil {
            requestBattery()
        } else {
            retryTask?.cancel()
            retryDelay = .seconds(2)
            connect()
        }
    }

    func stop() {
        if let audioListener {
            var address = Self.devicesAddress
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, audioListener)
        }
        retryTask?.cancel()
        pollTask?.cancel()
        channel?.close()
        channel = nil
    }

    // MARK: Presence

    private static var devicesAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    /// True when Core Audio lists a Bluetooth device whose UID starts with this address,
    /// e.g. `00-11-22-33-44-55:output`.
    private static func audioDevicePresent(address: String) -> Bool {
        let prefix = address.uppercased().replacingOccurrences(of: ":", with: "-")
        var listAddress = devicesAddress
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &listAddress, 0, nil, &size) == noErr else { return false }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &listAddress, 0, nil, &size, &ids) == noErr else { return false }

        return ids.contains { id in
            var transportAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyTransportType,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var transport: UInt32 = 0
            var transportSize = UInt32(MemoryLayout<UInt32>.size)
            guard AudioObjectGetPropertyData(id, &transportAddress, 0, nil, &transportSize, &transport) == noErr,
                  transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE
            else { return false }

            var uidAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceUID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var uid: Unmanaged<CFString>?
            var uidSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            guard AudioObjectGetPropertyData(id, &uidAddress, 0, nil, &uidSize, &uid) == noErr,
                  let value = uid?.takeRetainedValue() as String?
            else { return false }
            return value.uppercased().hasPrefix(prefix)
        }
    }

    private func audioDevicesChanged() {
        guard let address = address() else { return }
        if Self.audioDevicePresent(address: address) {
            guard channel == nil, !opening else { return }
            retryTask?.cancel()
            retryDelay = .seconds(2)
            // The headset accepts RFCOMM a moment after its audio profiles come up.
            retryTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                self?.connect()
            }
        } else {
            retryTask?.cancel()
            pollTask?.cancel()
            channel?.close()
            channel = nil
            publish(.disconnected)
        }
    }

    // MARK: Address

    /// The name is resolved to an address in a child process, because enumerating paired
    /// devices here would break connection state (see the type comment). Cached per name.
    private func address() -> String? {
        let defaults = UserDefaults.standard
        if defaults.string(forKey: "headphonesAddressName") == deviceName,
           let address = defaults.string(forKey: "headphonesAddress") {
            return address
        }
        guard let address = Self.resolveAddress(name: deviceName) else { return nil }
        defaults.set(address, forKey: "headphonesAddress")
        defaults.set(deviceName, forKey: "headphonesAddressName")
        return address
    }

    private static func resolveAddress(name: String) -> String? {
        guard let executable = Bundle.main.executableURL else { return nil }
        let process = Process()
        let pipe = Pipe()
        process.executableURL = executable
        process.arguments = ["--resolve-address", name]
        process.standardOutput = pipe
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let address = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return process.terminationStatus == 0 && !address.isEmpty ? address : nil
    }

    /// Runs in the child process started by `resolveAddress(name:)`.
    nonisolated static func printAddress(name: String) -> Bool {
        guard let address = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice])?
            .first(where: { $0.name == name })?.addressString
        else { return false }
        print(address)
        return true
    }

    // MARK: Connection

    /// The SPP record carries BMAP. Channel 2 is what SDP reported on the tested headset and
    /// is the fallback if the record is missing from the cache.
    private func bmapChannelID(for device: IOBluetoothDevice) -> BluetoothRFCOMMChannelID {
        var id: BluetoothRFCOMMChannelID = 0
        if let record = device.getServiceRecord(for: IOBluetoothSDPUUID(uuid16: 0x1101)),
           record.getRFCOMMChannelID(&id) == kIOReturnSuccess, id != 0 {
            return id
        }
        return 2
    }

    /// Opens the channel only while the headset is connected to this Mac, so a retry never
    /// pages it away from another host.
    private func connect() {
        guard channel == nil, !opening else { return }
        guard let address = address(), let device = IOBluetoothDevice(addressString: address) else {
            publish(.notPaired)
            return
        }
        guard Self.audioDevicePresent(address: address) else {
            publish(.disconnected)
            return
        }
        publish(.connecting)
        opening = true
        let channelID = bmapChannelID(for: device)
        var opened: IOBluetoothRFCOMMChannel?
        let result = device.openRFCOMMChannelAsync(&opened, withChannelID: channelID, delegate: self)
        trace("open channel \(channelID): \(String(format: "0x%x", result))")
        if result != kIOReturnSuccess {
            opening = false
            log.info("open channel \(channelID) failed: \(String(format: "0x%x", result), privacy: .public)")
            scheduleRetry()
        }
    }

    private func scheduleRetry() {
        retryTask?.cancel()
        let delay = retryDelay
        retryDelay = min(retryDelay * 2, .seconds(300))
        retryTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.connect()
        }
    }

    private func linkUp(_ newChannel: IOBluetoothRFCOMMChannel) {
        channel = newChannel
        parser.reset()
        retryDelay = .seconds(2)
        publish(.linked)
        requestBattery()
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let interval = self?.pollInterval else { return }
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled else { return }
                self?.requestBattery()
            }
        }
    }

    private func linkDown() {
        channel = nil
        pollTask?.cancel()
        if let address = address(), Self.audioDevicePresent(address: address) {
            publish(.connecting)
            scheduleRetry()
        } else {
            publish(.disconnected)
        }
    }

    private func requestBattery() {
        guard let channel else { return }
        var bytes = BMAPPacket.batteryRequest.bytes
        let result = channel.writeSync(&bytes, length: UInt16(bytes.count))
        trace("battery request: \(String(format: "0x%x", result))")
        if result != kIOReturnSuccess {
            log.info("battery request failed: \(String(format: "0x%x", result), privacy: .public)")
        }
    }

    private func publish(_ newState: State) {
        state = newState
        if newState == .notPaired || newState == .disconnected { level = nil }
        onUpdate?(state, level)
    }

    // MARK: Channel events

    private func handleOpenComplete(_ rfcommChannel: IOBluetoothRFCOMMChannel?, status: IOReturn) {
        trace("open complete: \(String(format: "0x%x", status))")
        opening = false
        if status == kIOReturnSuccess, let rfcommChannel {
            linkUp(rfcommChannel)
        } else {
            log.info("open complete failed: \(String(format: "0x%x", status), privacy: .public)")
            scheduleRetry()
        }
    }

    private func handleData(_ bytes: [UInt8]) {
        trace("rx \(bytes.map { String(format: "%02x", $0) }.joined(separator: " "))")
        for packet in parser.append(bytes) where packet.isBatteryStatus {
            level = BMAPBattery.level(fromPayload: packet.payload)
            onUpdate?(state, level)
        }
    }

    private func handleClosed(_ rfcommChannel: IOBluetoothRFCOMMChannel?) {
        trace("channel closed")
        guard rfcommChannel === channel else { return }
        linkDown()
    }
}

/// Lets an IOBluetooth object cross to the main actor. IOBluetooth predates Sendable; the
/// channel is only touched on main once it arrives there.
private struct Unchecked<Value>: @unchecked Sendable {
    let value: Value
}

/// RFCOMM callbacks are not guaranteed to arrive on main, so each one copies what it needs
/// and hops to the main actor.
extension BoseLink: IOBluetoothRFCOMMChannelDelegate {
    nonisolated func rfcommChannelOpenComplete(_ rfcommChannel: IOBluetoothRFCOMMChannel!, status error: IOReturn) {
        let channel = Unchecked(value: rfcommChannel)
        Task { @MainActor in self.handleOpenComplete(channel.value, status: error) }
    }

    nonisolated func rfcommChannelData(_ rfcommChannel: IOBluetoothRFCOMMChannel!, data dataPointer: UnsafeMutableRawPointer!, length dataLength: Int) {
        guard let dataPointer, dataLength > 0 else { return }
        let bytes = Array(UnsafeBufferPointer(
            start: dataPointer.assumingMemoryBound(to: UInt8.self), count: dataLength
        ))
        Task { @MainActor in self.handleData(bytes) }
    }

    nonisolated func rfcommChannelClosed(_ rfcommChannel: IOBluetoothRFCOMMChannel!) {
        let channel = Unchecked(value: rfcommChannel)
        Task { @MainActor in self.handleClosed(channel.value) }
    }
}
