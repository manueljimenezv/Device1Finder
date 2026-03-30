import CoreBluetooth
import Combine

final class FoundDevice: ObservableObject, Identifiable {
    let id: UUID = UUID()
    let peripheral: CBPeripheral

    var addr: String { peripheral.identifier.uuidString }

    @Published var rssi: Int
    @Published var idHex: String       // 8-byte manufacturer ID hex (mirrors FoundDevice.idHex)
    @Published var fullId: String?     // full serial from SERIAL_CHAR (mirrors FoundDevice.fullId)
    @Published var mfgHits: Int = 1

    var label: String { idHex.isEmpty ? String(peripheral.identifier.uuidString.suffix(8)).uppercased() : idHex }

    var displayName: String {
        if let full = fullId, !full.isEmpty { return full }
        if let name = peripheral.name, !name.isEmpty { return name }
        return label
    }

    init(peripheral: CBPeripheral, rssi: Int, idHex: String = "") {
        self.peripheral = peripheral
        self.rssi = rssi
        self.idHex = idHex
    }
}

extension FoundDevice: Equatable {
    static func == (lhs: FoundDevice, rhs: FoundDevice) -> Bool {
        lhs.peripheral.identifier == rhs.peripheral.identifier
    }
}

extension FoundDevice: Hashable {
    func hash(into hasher: inout Hasher) { hasher.combine(peripheral.identifier) }
}
