import CoreBluetooth

/// UUIDs extracted from the Android APK (BleConstants.kt)
enum BleConstants {
    /// Primary GATT service UUID  →  0000FEED-0000-1000-8000-00805F9B34FB
    static let serviceUUID = CBUUID(string: "0000FEED-0000-1000-8000-00805F9B34FB")

    /// Characteristic used to send IDENTIFY commands  →  0000BEEF-0000-1000-8000-00805F9B34FB
    static let identifyCharUUID = CBUUID(string: "0000BEEF-0000-1000-8000-00805F9B34FB")

    /// Characteristic used to read the device serial number  →  0000C0DE-0000-1000-8000-00805F9B34FB
    static let serialCharUUID = CBUUID(string: "0000C0DE-0000-1000-8000-00805F9B34FB")

    /// Identify command values (cmd byte written to identifyChar)
    enum Cmd: UInt8 {
        case blink = 0x01   // Trigger LED blink
        case sound = 0x02   // Trigger sound/buzzer
    }

    /// BLE scan timeout in seconds (matches Android 10-second window)
    static let scanTimeout: TimeInterval = 10.0
}
