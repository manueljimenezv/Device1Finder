import CoreBluetooth
import Combine
import UIKit

/// Drives all BLE operations.
/// Replaces the Android BluetoothAdapter / BluetoothLeScanner / BluetoothGatt logic
/// that lived in  MainActivity.kt  and the inner callback classes.
final class BleManager: NSObject, ObservableObject {

    // MARK: - Published state

    @Published var devices: [FoundDevice] = []
    @Published var isScanning: Bool = false
    @Published var statusMessage: String = "Ready"
    @Published var bluetoothState: CBManagerState = .unknown

    // MARK: - Private

    private var centralManager: CBCentralManager!
    /// Map from peripheral identifier → FoundDevice for fast lookup
    private var deviceMap: [UUID: FoundDevice] = [:]
    /// Active GATT connections keyed by peripheral identifier
    private var activeConnections: [UUID: CBPeripheral] = [:]
    /// Pending (cmd, completion) keyed by peripheral identifier
    private var pendingCommands: [UUID: (BleConstants.Cmd, (Bool) -> Void)] = [:]
    /// Serial read completions
    private var serialCallbacks: [UUID: (String?) -> Void] = [:]

    private var scanTimer: Timer?

    override init() {
        super.init()
        centralManager = CBCentralManager(delegate: self, queue: .main)
    }

    // MARK: - Scan

    /// Starts a BLE scan for peripherals advertising SERVICE_UUID.
    /// Mirrors  ensurePermsThenScan()  /  scanCb  in MainActivity.kt.
    func startScan() {
        guard centralManager.state == .poweredOn else {
            statusMessage = bluetoothState == .poweredOff ? "Bluetooth is OFF" : "Bluetooth not ready"
            return
        }
        guard !isScanning else { return }

        statusMessage = "Scanning… (no filter)"
        isScanning = true

        // Scan without a UUID filter so we see all advertising packets,
        // matching the Android "no filter" approach. We filter in the callback.
        centralManager.scanForPeripherals(
            withServices: [BleConstants.serviceUUID],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: true]
        )

        // Auto-stop after timeout (mirrors Android stopScanRunnable)
        scanTimer = Timer.scheduledTimer(withTimeInterval: BleConstants.scanTimeout, repeats: false) { [weak self] _ in
            self?.stopScan()
        }
    }

    /// Stops an active scan.
    func stopScan() {
        guard isScanning else { return }
        centralManager.stopScan()
        isScanning = false
        scanTimer?.invalidate()
        scanTimer = nil
        statusMessage = "Stopped scan. Found=\(devices.count)"
    }

    // MARK: - connectAndWrite  (mirrors MainActivity.connectAndWrite)

    /// Connects to a peripheral, discovers services, and writes the IDENTIFY command
    /// to the IDENTIFY_CHAR_UUID characteristic.
    /// Mirrors  connectAndWrite()  in MainActivity.kt.
    func sendIdentify(to device: FoundDevice, cmd: BleConstants.Cmd, onDone: @escaping (Bool) -> Void) {
        let peripheral = device.peripheral
        statusMessage = "Connecting to \(device.displayName)…"
        pendingCommands[peripheral.identifier] = (cmd, onDone)
        activeConnections[peripheral.identifier] = peripheral
        peripheral.delegate = self
        centralManager.connect(peripheral, options: nil)
    }

    // MARK: - readSerialCharacteristic  (mirrors MainActivity.readSerialCharacteristic)

    /// Connects and reads the SERIAL_CHAR_UUID characteristic.
    func readSerial(from device: FoundDevice, onDone: @escaping (String?) -> Void) {
        let peripheral = device.peripheral
        serialCallbacks[peripheral.identifier] = onDone
        activeConnections[peripheral.identifier] = peripheral
        peripheral.delegate = self
        centralManager.connect(peripheral, options: nil)
    }

    // MARK: - Disconnect helper

    private func disconnect(_ peripheral: CBPeripheral) {
        centralManager.cancelPeripheralConnection(peripheral)
        activeConnections.removeValue(forKey: peripheral.identifier)
    }
}

// MARK: - CBCentralManagerDelegate

extension BleManager: CBCentralManagerDelegate {

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        bluetoothState = central.state
        switch central.state {
        case .poweredOn:
            statusMessage = "Ready"
        case .poweredOff:
            statusMessage = "Bluetooth is OFF"
            isScanning = false
        case .unauthorized:
            statusMessage = "BLE permissions required"
        default:
            statusMessage = "Bluetooth not available"
        }
    }

    /// Mirrors  scanCb  (ScanCallback.onScanResult) in MainActivity.kt.
    func centralManager(_ central: CBCentralManager,
                        didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any],
                        rssi RSSI: NSNumber) {

        let rssiVal = RSSI.intValue
        let pid = peripheral.identifier

        if let existing = deviceMap[pid] {
            existing.rssi = rssiVal
            existing.mfgHits += 1
        } else {
            let found = FoundDevice(peripheral: peripheral, rssi: rssiVal)
            deviceMap[pid] = found
            devices.append(found)
            devices.sort { $0.rssi > $1.rssi }   // highest RSSI first, like Android
            statusMessage = "Found=\(devices.count)"
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.discoverServices([BleConstants.serviceUUID])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        completePendingCommand(for: peripheral, success: false)
        completeSerialRead(for: peripheral, value: nil)
    }

    func centralManager(_ central: CBCentralManager,
                        didDisconnectPeripheral peripheral: CBPeripheral,
                        error: Error?) {
        activeConnections.removeValue(forKey: peripheral.identifier)
    }
}

// MARK: - CBPeripheralDelegate

extension BleManager: CBPeripheralDelegate {

    /// Mirrors  onServicesDiscovered  in connectAndWrite$1 / readSerialCharacteristic$1.
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

        // --- IDENTIFY path ---
        if let (cmd, _) = pendingCommands[peripheral.identifier], let char = identifyChar {
            let data = Data([cmd.rawValue])
            peripheral.writeValue(data, for: char, type: .withResponse)
            statusMessage = String(format: "to write cmd=0x%02X", cmd.rawValue)
        } else if pendingCommands[peripheral.identifier] != nil {
            // "No identify char"
            statusMessage = "No identify char"
            completePendingCommand(for: peripheral, success: false)
            disconnect(peripheral)
        }

        // --- SERIAL read path ---
        if serialCallbacks[peripheral.identifier] != nil {
            if let char = serialChar {
                peripheral.readValue(for: char)
            } else {
                statusMessage = "serial read: service/char missing"
                completeSerialRead(for: peripheral, value: nil)
                disconnect(peripheral)
            }
        }
    }

    /// Mirrors  onCharacteristicWrite  → success path → disconnect.
    func peripheral(_ peripheral: CBPeripheral,
                    didWriteValueFor characteristic: CBCharacteristic,
                    error: Error?) {

        if characteristic.uuid == BleConstants.identifyCharUUID {
            let success = error == nil
            if let (cmd, _) = pendingCommands[peripheral.identifier] {
                statusMessage = success
                    ? String(format: "Sent identify 0x%02X", cmd.rawValue)
                    : "Write failed: \(error?.localizedDescription ?? "unknown")"
            }
            completePendingCommand(for: peripheral, success: success)
            // Disconnect after write (mirrors Android gatt.disconnect())
            disconnect(peripheral)
        }
    }

    /// Mirrors  onCharacteristicRead  for SERIAL_CHAR.
    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateValueFor characteristic: CBCharacteristic,
                    error: Error?) {

        if characteristic.uuid == BleConstants.serialCharUUID {
            var serialString: String?
            if let data = characteristic.value, error == nil {
                serialString = String(data: data, encoding: .utf8)
                    ?? data.map { String(format: "%02X", $0) }.joined()
                // Update the FoundDevice model
                if let device = deviceMap[peripheral.identifier] {
                    device.serial = serialString
                }
                statusMessage = "serial read: status=OK"
            } else {
                statusMessage = "serial read: status=ERROR"
            }
            completeSerialRead(for: peripheral, value: serialString)
            disconnect(peripheral)
        }
    }

    // MARK: - Completion helpers

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
