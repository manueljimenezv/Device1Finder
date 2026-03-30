# Device1Finder – iOS / iPadOS

Native Swift/SwiftUI port of the Android `device1finder.apk`.

## What was extracted from the APK

| Android (Kotlin)             | iOS (Swift)              |
|------------------------------|--------------------------|
| `BleConstants.kt`            | `BleConstants.swift`     |
| `FoundDevice.kt`             | `FoundDevice.swift`      |
| `MainActivity.kt` (BLE logic)| `BleManager.swift`       |
| `activity_main.xml` (UI)     | `ContentView.swift`      |

### BLE Protocol (extracted from `classes3.dex`)

| Constant           | UUID                                   |
|--------------------|----------------------------------------|
| `SERVICE_UUID`     | `0000FEED-0000-1000-8000-00805F9B34FB` |
| `IDENTIFY_CHAR`    | `0000BEEF-0000-1000-8000-00805F9B34FB` |
| `SERIAL_CHAR`      | `0000C0DE-0000-1000-8000-00805F9B34FB` |

| Command | Byte  | Action       |
|---------|-------|--------------|
| BLINK   | `0x01`| Trigger LED  |
| SOUND   | `0x02`| Play buzzer  |

---

## Requirements

- **Xcode 15+**
- **iOS / iPadOS 16.0+** deployment target
- A **paid Apple Developer account** (required for Bluetooth entitlements on a real device)

---

## Setup in Xcode

1. Open `Device1Finder.xcodeproj` in Xcode.
2. Select the `Device1Finder` target → **Signing & Capabilities**.
3. Set your **Team** (Apple Developer account).
4. Add the **Background Modes** capability if you need background BLE scanning:
   - Tick **Uses Bluetooth LE accessories**.
5. Build & run on a real iPhone or iPad (BLE does not work in the Simulator).

---

## Permissions

The app requires:

- `NSBluetoothAlwaysUsageDescription` – already in `Info.plist`.
- On iOS 13+, CoreBluetooth will prompt the user automatically on first launch.

---

## Architecture

```
Device1FinderApp   ← @main SwiftUI entry point
  └── ContentView  ← scan list + scan button
        └── DeviceDetailView  ← per-device identify / serial actions

BleManager (ObservableObject)
  ├── CBCentralManager  ← replaces BluetoothAdapter + BluetoothLeScanner
  ├── scanCb            ← replaces ScanCallback.onScanResult
  ├── sendIdentify()    ← replaces connectAndWrite()
  └── readSerial()      ← replaces readSerialCharacteristic()

FoundDevice (ObservableObject)
  ├── addr / label / fullId / displayName
  ├── rssi, mfgHits
  └── serial (optional)

BleConstants
  └── SERVICE_UUID / IDENTIFY_CHAR_UUID / SERIAL_CHAR_UUID / Cmd enum
```

---

## Known iOS differences vs Android

| Android behaviour                        | iOS equivalent                                     |
|------------------------------------------|----------------------------------------------------|
| MAC address (`59:8C:50:…`)               | UUID assigned by iOS (privacy feature, unfixable)  |
| Location permission needed for BLE scan  | Not required on iOS                                |
| Samsung scan-callback warning            | Not applicable                                     |
| `gatt.disconnect()` after write          | `cancelPeripheralConnection()` after write         |
