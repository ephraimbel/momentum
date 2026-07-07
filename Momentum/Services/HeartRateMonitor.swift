import Foundation
import CoreBluetooth

/// Live heart rate from a Bluetooth-LE monitor (standard Heart Rate Service `0x180D`) — R3. iPhone has
/// no HR sensor of its own, so a paired BLE strap/armband is the real live-HR source on phone-only
/// runs. Publishes the latest BPM; no-ops gracefully when no monitor is present, so the run loop never
/// depends on it.
///
/// The BLE transport can't be exercised in the simulator — the measurement **parser** (`parseHeartRate`)
/// is unit-tested against the spec; the connect/notify path is device-verified.
@MainActor
protocol HeartRateServing: AnyObject {
    var bpm: Int? { get }
    var isConnected: Bool { get }
    func start()
    func stop()
}

@MainActor
final class HeartRateMonitor: NSObject, HeartRateServing {
    private(set) var bpm: Int?
    private(set) var isConnected = false

    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?

    private static let hrService = CBUUID(string: "180D")
    private static let hrMeasurement = CBUUID(string: "2A37")   // Heart Rate Measurement characteristic

    /// Begin scanning for a heart-rate monitor. Safe to call when Bluetooth is off — it simply waits.
    func start() {
        guard central == nil else { return }
        // nil queue → delegate callbacks arrive on the main thread (we're @MainActor).
        central = CBCentralManager(delegate: self, queue: nil)
    }

    func stop() {
        if let peripheral { central?.cancelPeripheralConnection(peripheral) }
        central?.stopScan()
        central = nil
        peripheral = nil
        bpm = nil
        isConnected = false
    }

    /// Parse a Heart Rate Measurement value (Bluetooth HRS spec 3.113). Bit 0 of the flags byte selects
    /// the BPM format: 0 → UInt8 at byte 1, 1 → UInt16 (little-endian) at bytes 1–2. Pure + testable;
    /// `nonisolated` so the BLE notification callback can parse without hopping actors.
    nonisolated static func parseHeartRate(_ data: Data) -> Int? {
        let bytes = [UInt8](data)
        guard let flags = bytes.first else { return nil }
        if flags & 0x01 == 0 {
            guard bytes.count >= 2 else { return nil }
            return Int(bytes[1])
        } else {
            guard bytes.count >= 3 else { return nil }
            return Int(bytes[1]) | (Int(bytes[2]) << 8)
        }
    }
}

extension HeartRateMonitor: CBCentralManagerDelegate, CBPeripheralDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        MainActor.assumeIsolated {
            if central.state == .poweredOn {
                central.scanForPeripherals(withServices: [Self.hrService])
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                                    advertisementData: [String: Any], rssi RSSI: NSNumber) {
        MainActor.assumeIsolated {
            central.stopScan()
            self.peripheral = peripheral
            peripheral.delegate = self
            central.connect(peripheral)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        MainActor.assumeIsolated {
            self.isConnected = true
            peripheral.discoverServices([Self.hrService])
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral,
                                    error: Error?) {
        MainActor.assumeIsolated {
            self.isConnected = false
            self.bpm = nil
            // Try to re-acquire the strap if it dropped mid-run.
            if self.central != nil { central.scanForPeripherals(withServices: [Self.hrService]) }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        MainActor.assumeIsolated {
            for service in peripheral.services ?? [] where service.uuid == Self.hrService {
                peripheral.discoverCharacteristics([Self.hrMeasurement], for: service)
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService,
                                error: Error?) {
        MainActor.assumeIsolated {
            for ch in service.characteristics ?? [] where ch.uuid == Self.hrMeasurement {
                peripheral.setNotifyValue(true, for: ch)   // subscribe to per-beat notifications
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic,
                                error: Error?) {
        guard let data = characteristic.value, let value = HeartRateMonitor.parseHeartRate(data) else { return }
        MainActor.assumeIsolated { self.bpm = value }
    }
}
