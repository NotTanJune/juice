// BMAP (Bose Media Application Protocol) framing, as documented by the open-source bosectl
// project and confirmed against a QuietComfort Ultra Headphones (PID 0x4066, firmware 1.6.7).
//
// Every packet is [functionBlock, function, flags, payloadLength, payload...]. The low nibble
// of `flags` is the operator. Battery level is function block 2, function 2.

public enum BMAPOperator: UInt8, Sendable {
    case set = 0
    case get = 1
    case setGet = 2
    case status = 3
    case error = 4
    case start = 5
    case result = 6
    case processing = 7
}

public struct BMAPPacket: Equatable, Sendable {
    public var functionBlock: UInt8
    public var function: UInt8
    public var flags: UInt8
    public var payload: [UInt8]

    public init(functionBlock: UInt8, function: UInt8, flags: UInt8, payload: [UInt8] = []) {
        self.functionBlock = functionBlock
        self.function = function
        self.flags = flags
        self.payload = payload
    }

    public var op: BMAPOperator? { BMAPOperator(rawValue: flags & 0x0F) }

    public var bytes: [UInt8] {
        [functionBlock, function, flags, UInt8(payload.count)] + payload
    }

    public static let batteryRequest = BMAPPacket(
        functionBlock: 2, function: 2, flags: BMAPOperator.get.rawValue
    )

    public var isBatteryStatus: Bool {
        functionBlock == 2 && function == 2 && op == .status
    }
}

/// Splits an RFCOMM byte stream into packets. RFCOMM delivers bytes, not messages, so one
/// callback can carry several packets or only part of one.
public struct BMAPStreamParser: Sendable {
    private var buffer: [UInt8] = []

    public init() {}

    public mutating func append(_ bytes: [UInt8]) -> [BMAPPacket] {
        buffer += bytes
        var packets: [BMAPPacket] = []
        while buffer.count >= 4 {
            let length = Int(buffer[3])
            guard buffer.count >= 4 + length else { break }
            packets.append(BMAPPacket(
                functionBlock: buffer[0],
                function: buffer[1],
                flags: buffer[2],
                payload: Array(buffer[4..<(4 + length)])
            ))
            buffer.removeFirst(4 + length)
        }
        return packets
    }

    public mutating func reset() { buffer.removeAll() }
}

public enum BMAPBattery {
    /// Battery percentage from a [2.2] STATUS payload, or nil when the device reports unknown.
    ///
    /// Headphones answer `[level, 0xFF, 0xFF, 0x00]`. Earbuds answer several 4-byte records
    /// `[level, reserved, reserved, componentID]` where 0x01 is right, 0x02 left, 0x03 case and
    /// 0x04 the combined buds; records are identified by ID, not position.
    public static func level(fromPayload payload: [UInt8]) -> Int? {
        guard let first = payload.first else { return nil }
        let records = stride(from: 0, to: payload.count - payload.count % 4, by: 4).map {
            Array(payload[$0..<($0 + 4)])
        }
        let byComponent = Dictionary(
            records.filter { $0[3] != 0 }.map { ($0[3], $0[0]) },
            uniquingKeysWith: { a, _ in a }
        )
        if !byComponent.isEmpty {
            if let combined = byComponent[0x04], combined <= 100 { return Int(combined) }
            let buds = [byComponent[0x01], byComponent[0x02]].compactMap { $0 }.filter { $0 <= 100 }
            return buds.min().map(Int.init)
        }
        return first <= 100 ? Int(first) : nil
    }
}
