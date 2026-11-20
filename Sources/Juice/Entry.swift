import Foundation

/// `Juice --probe` prints one reading per device as JSON and exits, for checking the
/// Bluetooth paths without the menu bar UI. Otherwise it runs the menu bar app.
@main
enum Entry {
    @MainActor
    static func main() {
        let arguments = CommandLine.arguments
        if let flag = arguments.firstIndex(of: "--resolve-address"), flag + 1 < arguments.count {
            exit(BoseLink.printAddress(name: arguments[flag + 1]) ? 0 : 1)
        }
        guard arguments.contains("--probe") else {
            JuiceApp.main()
            return
        }

        let store = BatteryStore()
        store.start(notify: false)
        let deadline = Date().addingTimeInterval(45)
        while Date() < deadline, store.headphones.updated == nil || store.mouse.updated == nil {
            RunLoop.main.run(until: Date().addingTimeInterval(0.25))
        }

        func json(_ r: DeviceReading) -> [String: Any] {
            ["name": r.name, "connected": r.connected, "level": r.level as Any? ?? NSNull(), "charging": r.charging]
        }
        let output = ["mouse": json(store.mouse), "headphones": json(store.headphones)]
        if let data = try? JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys]) {
            print(String(decoding: data, as: UTF8.self))
        }
        exit(store.headphones.level == nil || store.mouse.level == nil ? 1 : 0)
    }
}
