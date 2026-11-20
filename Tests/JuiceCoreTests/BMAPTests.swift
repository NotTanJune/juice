import Testing
@testable import JuiceCore

struct BMAPTests {
    @Test func batteryRequestBytes() {
        #expect(BMAPPacket.batteryRequest.bytes == [0x02, 0x02, 0x01, 0x00])
    }

    // Captured from the QC Ultra "Atom" on 2026-11-20.
    @Test func parsesCapturedHeadphoneReply() throws {
        var parser = BMAPStreamParser()
        let packets = parser.append([0x02, 0x02, 0x03, 0x04, 0x32, 0xFF, 0xFF, 0x00])
        let packet = try #require(packets.first)
        #expect(packets.count == 1)
        #expect(packet.isBatteryStatus)
        #expect(BMAPBattery.level(fromPayload: packet.payload) == 50)
    }

    @Test func reassemblesSplitAndJoinedPackets() {
        var parser = BMAPStreamParser()
        #expect(parser.append([0x02, 0x02, 0x03]).isEmpty)
        #expect(parser.append([0x04, 0x32, 0xFF]).isEmpty)
        let packets = parser.append([0xFF, 0x00, 0x00, 0x05, 0x03, 0x01, 0x41])
        #expect(packets.count == 2)
        #expect(packets[0].isBatteryStatus)
        #expect(packets[1].functionBlock == 0 && packets[1].function == 5)
        #expect(packets[1].payload == [0x41])
    }

    @Test func earbudRecordsPreferCombinedThenLowerBud() {
        let combined: [UInt8] = [0x3C, 0xFF, 0xFF, 0x01, 0x46, 0xFF, 0xFF, 0x02,
                                 0x50, 0xFF, 0xFF, 0x03, 0x41, 0xFF, 0xFF, 0x04]
        #expect(BMAPBattery.level(fromPayload: combined) == 65)
        let budsOnly: [UInt8] = [0x3C, 0xFF, 0xFF, 0x01, 0x46, 0xFF, 0xFF, 0x02]
        #expect(BMAPBattery.level(fromPayload: budsOnly) == 60)
    }

    @Test func unknownLevelIsNil() {
        #expect(BMAPBattery.level(fromPayload: [0xFF, 0xFF, 0xFF, 0x00]) == nil)
        #expect(BMAPBattery.level(fromPayload: []) == nil)
    }

    @Test func errorOperatorIsNotBatteryStatus() {
        let packet = BMAPPacket(functionBlock: 2, function: 2, flags: 0x04, payload: [0x03])
        #expect(packet.op == .error)
        #expect(!packet.isBatteryStatus)
    }
}
