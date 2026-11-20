import Foundation
import IOKit.ps

/// Reads Bluetooth LE accessories that macOS already tracks as power sources. The MX Master 3S
/// reports its level through the standard BLE Battery Service, which macOS lists alongside
/// the internal battery (the same data `pmset -g ps` prints).
enum PowerSources {
    struct Entry: Equatable {
        var level: Int
        var charging: Bool
    }

    static func entry(named name: String) -> Entry? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef]
        else { return nil }

        for source in list {
            guard let description = IOPSGetPowerSourceDescription(info, source)?
                .takeUnretainedValue() as? [String: Any],
                  (description[kIOPSNameKey] as? String) == name,
                  let current = description[kIOPSCurrentCapacityKey] as? Int
            else { continue }
            let maximum = (description[kIOPSMaxCapacityKey] as? Int).flatMap { $0 > 0 ? $0 : nil } ?? 100
            let charging = description[kIOPSIsChargingKey] as? Bool ?? false
            return Entry(level: min(100, current * 100 / maximum), charging: charging)
        }
        return nil
    }
}
