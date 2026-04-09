import CoreBluetooth
import Combine

final class BleManager: NSObject, ObservableObject {

    @Published var devices: [FoundDevice] = []
    @Published var isScanning: Bool = false
    @Published var statusMessage: String = "Ready"
    @Published var bluetoothState: CBManagerState = .unknown

    var targetFilter: String = ""

    private var centralManager: CBCentralManager!
    private var deviceMap: [UUID: FoundDevice] = [:]
    private var activeConnections: [UUID: CBPeripheral] = [:]
    private var pendingCommands: [UUID: (BleConstants.Cmd, (Bool) -> Void)] = [:]
    private var serialCallbacks: [UUID: (String?) -> Void] = [:]
    private var lastSerialReadAt: [UUID: Date] = [:]
    private let serialReadCooldown: TimeInterval = 10.0
    private var scanTimer: Timer?

    override init() {
        super.init()
        centralManager = CBCentralManager(delegate: self, queue: .main)
    }

    func startScan() {
        guard centralManager.state == .poweredOn else {
            statusMessage = bluetoothState == .poweredOff ? "Bluetooth is OFF" : "Bluetooth not ready"
            return
        }
        guard !isScanning else { return }
        devices.removeAll()
        deviceMap.removeAll()
        statusMessage = "Scanning (no filter)…"
        isScanning = true
        centralManager.scanForPeripherals(
            withServices: [BleConstants.serviceUUID],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: true]
        )
        scanTimer = Timer.scheduledTimer(withTimeInterval: BleConstants.scanTimeout, repeats: false) { [weak self] _ in
            self?.stopScan()
        }
    }

    func stopScan() {
        guard isScanning else { return }
        centralManager.stopScan()
        isScanning = false
        scanTimer?.invalidate()
        scanTimer = nil
        statusMessage = "Stopped. Found=\(devices.count)"
    }

    func sendIdentify(to device: FoundDevice, cmd: BleConstants.Cmd, onDone: @escaping (Bool) -> Void) {
        let peripheral = device.peripheral
        statusMessage = "Connecting to \(device.displayName)…"
        pendingCommands[peripheral.identifier] = (cmd, onDone)
        activeConnections[peripheral.identifier] = peripheral
        peripheral.delegate = self
        centralManager.connect(peripheral, options: nil)
    }

    func readSerial(from device: FoundDevice, onDone: @escaping (String?) -> Void) {
        let peripheral = device.peripheral
        serialCallbacks[peripheral.identifier] = onDone
        activeConnections[peripheral.identifier] = peripheral
        peripheral.delegate = self
        centralManager.connect(peripheral, options: nil)
    }

    private func disconnect(_ peripheral: CBPeripheral, delay: TimeInterval = 0.5) {
        // Add delay before disconnect so iPad BLE stack has time to process the write
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.centralManager.cancelPeripheralConnection(peripheral)
            self?.activeConnections.removeValue(forKey: peripheral.identifier)
        }
    }
}

extension BleManager: CBCentralManagerDelegate {

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        bluetoothState = central.state
        switch central.state {
        case .poweredOn:     statusMessage = "Ready"
        case .poweredOff:    statusMessage = "Bluetooth is OFF"; isScanning = false
        case .unauthorized:  statusMessage = "BLE permissions required"
        default:             statusMessage = "Bluetooth not available"
        }
    }

    func centralManager(_ central: CBCentralManager,
                        didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any],
                        rssi RSSI: NSNumber) {
        let rssiVal = RSSI.intValue
        let pid = peripheral.identifier

        var idHex = ""
        if let mfgData = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data,
           mfgData.count >= 10 {
            let companyID = UInt16(mfgData[0]) | (UInt16(mfgData[1]) << 8)
            if companyID == BleConstants.mfgID {
                let payload = mfgData.dropFirst(2).prefix(8)
                idHex = payload.map { String(format: "%02X", $0) }.joined()
            }
        }

        if !targetFilter.isEmpty {
            let knownFull = deviceMap[pid]?.fullId?.uppercased() ?? ""
            if targetFilter != idHex && targetFilter != knownFull { return }
        }

        if let existing = deviceMap[pid] {
            existing.rssi = rssiVal
            existing.mfgHits += 1
            if !idHex.isEmpty { existing.idHex = idHex }
        } else {
            let found = FoundDevice(peripheral: peripheral, rssi: rssiVal, idHex: idHex)
            deviceMap[pid] = found
            devices.append(found)
            devices.sort { $0.rssi > $1.rssi }
        }
        statusMessage = "Found=\(devices.count)"
        maybeReadFullSerial(pid: pid)
    }

    private func maybeReadFullSerial(pid: UUID) {
        guard let device = deviceMap[pid], device.fullId == nil else { return }
        let now = Date()
        if let last = lastSerialReadAt[pid], now.timeIntervalSince(last) < serialReadCooldown { return }
        lastSerialReadAt[pid] = now
        readSerial(from: device) { [weak self] serial in
            guard let serial = serial, !serial.isEmpty else { return }
            self?.deviceMap[pid]?.fullId = serial.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.discoverServices([BleConstants.serviceUUID])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        completePendingCommand(for: peripheral, success: false)
        completeSerialRead(for: peripheral, value: nil)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        activeConnections.removeValue(forKey: peripheral.identifier)
    }
}

extension BleManager: CBPeripheralDelegate {

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let services = peripheral.services else {
            completePendingCommand(for: peripheral, success: false)
            completeSerialRead(for: peripheral, value: nil)
            return
        }
        for service in services where service.uuid == BleConstants.serviceUUID {
            peripheral.discoverCharacteristics(
                [BleConstants.identifyCharUUID, BleConstants.serialCharUUID],
                for: service
            )
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didDiscoverCharacteristicsFor service: CBService,
                    error: Error?) {

        let chars = service.characteristics ?? []
        let identifyChar = chars.first(where: { $0.uuid == BleConstants.identifyCharUUID })
        let serialChar   = chars.first(where: { $0.uuid == BleConstants.serialCharUUID })

        if let (cmd, _) = pendingCommands[peripheral.identifier] {
            if let char = identifyChar {
                let data = Data([cmd.rawValue])

                // KEY FIX: Check characteristic properties to decide write type.
                // Android uses WRITE_TYPE_NO_RESPONSE — use .withoutResponse if supported,
                // otherwise fall back to .withResponse (needed on some iPads).
                let writeType: CBCharacteristicWriteType
                if char.properties.contains(.writeWithoutResponse) {
                    writeType = .withoutResponse
                } else {
                    writeType = .withResponse
                }

                peripheral.writeValue(data, for: char, type: writeType)
                statusMessage = String(format: "Sent 0x%02X", cmd.rawValue)

                if writeType == .withoutResponse {
                    // No delegate callback for withoutResponse — complete after delay
                    completePendingCommand(for: peripheral, success: true)
                    disconnect(peripheral, delay: 0.5)
                }
                // If withResponse, wait for didWriteValueFor callback
            } else {
                statusMessage = "No identify char"
                completePendingCommand(for: peripheral, success: false)
                disconnect(peripheral, delay: 0)
            }
        }

        if serialCallbacks[peripheral.identifier] != nil {
            if let char = serialChar {
                peripheral.readValue(for: char)
            } else {
                statusMessage = "serial read: service/char missing"
                completeSerialRead(for: peripheral, value: nil)
                disconnect(peripheral, delay: 0)
            }
        }
    }

    // Called only when write type is .withResponse
    func peripheral(_ peripheral: CBPeripheral,
                    didWriteValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        if characteristic.uuid == BleConstants.identifyCharUUID {
            let success = error == nil
            statusMessage = success ? "Identify sent ✓" : "Write failed: \(error?.localizedDescription ?? "")"
            completePendingCommand(for: peripheral, success: success)
            disconnect(peripheral, delay: 0.3)
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        if characteristic.uuid == BleConstants.serialCharUUID {
            var serialString: String?
            if let data = characteristic.value, error == nil {
                serialString = String(data: data, encoding: .utf8)
                    ?? data.map { String(format: "%02X", $0) }.joined()
                deviceMap[peripheral.identifier]?.fullId = serialString
                statusMessage = "serial read: status=OK"
            } else {
                statusMessage = "serial read: status=ERROR"
            }
            completeSerialRead(for: peripheral, value: serialString)
            disconnect(peripheral, delay: 0.3)
        }
    }

    private func completePendingCommand(for peripheral: CBPeripheral, success: Bool) {
        if let (_, completion) = pendingCommands.removeValue(forKey: peripheral.identifier) {
            DispatchQueue.main.async { completion(success) }
        }
    }

    private func completeSerialRead(for peripheral: CBPeripheral, value: String?) {
        if let completion = serialCallbacks.removeValue(forKey: peripheral.identifier) {
            DispatchQueue.main.async { completion(value) }
        }
    }
}
