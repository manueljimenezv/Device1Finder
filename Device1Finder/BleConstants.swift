import CoreBluetooth

enum BleConstants {
    static let serviceUUID       = CBUUID(string: "0000FEED-0000-1000-8000-00805F9B34FB")
    static let identifyCharUUID  = CBUUID(string: "0000BEEF-0000-1000-8000-00805F9B34FB")
    static let serialCharUUID    = CBUUID(string: "0000C0DE-0000-1000-8000-00805F9B34FB")

    /// Manufacturer ID used in advertisement packets (matches Android MFG_ID = 0x1234)
    static let mfgID: UInt16 = 0x1234

    enum Cmd: UInt8 {
        case blink = 0x01
        case sound = 0x02
        case both  = 0x03
    }

    static let scanTimeout: TimeInterval = 20.0  // matches Android SCAN_DURATION_MS = 20_000
}
