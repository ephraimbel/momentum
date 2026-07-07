import Testing
import Foundation
@testable import Momentum

/// BLE Heart Rate Measurement parsing (running-excellence R3). The connect/notify transport is
/// device-only; this pins down the byte-level parse against the Bluetooth HRS spec — the part that's
/// easy to get wrong (flags byte, UInt8 vs little-endian UInt16, short/empty frames).
struct HeartRateMonitorTests {

    @Test func parsesUInt8Format() {
        // flags 0x00 → bit0 = 0 → single-byte BPM at byte 1.
        #expect(HeartRateMonitor.parseHeartRate(Data([0x00, 72])) == 72)
        // Other flag bits set (sensor contact etc.) but bit0 still 0 → still UInt8.
        #expect(HeartRateMonitor.parseHeartRate(Data([0x06, 65])) == 65)
    }

    @Test func parsesUInt16LittleEndianFormat() {
        // flags 0x01 → bit0 = 1 → 16-bit little-endian BPM at bytes 1–2. 0x00C8 = 200.
        #expect(HeartRateMonitor.parseHeartRate(Data([0x01, 0xC8, 0x00])) == 200)
        // 0x012C = 300 (exercises the high byte).
        #expect(HeartRateMonitor.parseHeartRate(Data([0x01, 0x2C, 0x01])) == 300)
    }

    @Test func rejectsShortOrEmptyFrames() {
        #expect(HeartRateMonitor.parseHeartRate(Data()) == nil)           // no flags
        #expect(HeartRateMonitor.parseHeartRate(Data([0x00])) == nil)     // UInt8 format, no value byte
        #expect(HeartRateMonitor.parseHeartRate(Data([0x01, 0xC8])) == nil) // UInt16 format, only 1 value byte
    }
}
