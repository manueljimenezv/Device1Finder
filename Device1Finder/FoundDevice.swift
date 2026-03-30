import CoreBluetooth
import Combine

/// Mirrors  FoundDevice  data class from the Android APK.
/// Represents one discovered BLE peripheral.
final class FoundDevice: ObservableObject, Identifiable {
    let id: UUID = UUID()

    /// CBPeripheral reference (replaces Android BluetoothDevice)
    let peripheral: CBPeripheral

    /// MAC-style address string (iOS gives a UUID instead of a MAC, so we use the peripheral UUID)
    var addr: String { peripheral.identifier.uuidString }

    /// Last known RSSI
    @Published var rssi: Int

    /// Short hex label derived from the last bytes of the identifier (mirrors idHex / label logic)
    var label: String {
        let uuidStr = peripheral.identifier.uuidString.replacingOccurrences(of: "-", with: "")
        return String(uuidStr.suffix(8)).uppercased()
    }

    /// Full identifier shown in the list row (mirrors fullId)
    var fullId: String { peripheral.identifier.uuidString.uppercased() }

    /// Serial string read from the SERIAL_CHAR characteristic (0000C0DE…)
    @Published var serial: String?

    /// How many times this device was seen in manufacturing-ID scan hits
    @Published var mfgHits: Int = 0

    /// Human-readable display name: prefer peripheral.name, fall back to label
    var displayName: String {
        if let name = peripheral.name, !name.isEmpty { return name }
        return label
    }

    init(peripheral: CBPeripheral, rssi: Int) {
        self.peripheral = peripheral
        self.rssi = rssi
    }
}

extension FoundDevice: Equatable {
    static func == (lhs: FoundDevice, rhs: FoundDevice) -> Bool {
        lhs.peripheral.identifier == rhs.peripheral.identifier
    }
}

extension FoundDevice: Hashable {
    func hash(into hasher: inout Hasher) {
        hasher.combine(peripheral.identifier)
    }
}
