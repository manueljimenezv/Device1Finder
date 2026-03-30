import SwiftUI
import CoreBluetooth

// MARK: - Root App

@main
struct Device1FinderApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

// MARK: - ContentView  (mirrors activity_main.xml + MainActivity logic)

struct ContentView: View {

    @StateObject private var ble = BleManager()

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {

                // ── Status bar ─────────────────────────────────────────────
                StatusBarView(ble: ble)

                // ── Device list ────────────────────────────────────────────
                if ble.devices.isEmpty {
                    Spacer()
                    emptyState
                    Spacer()
                } else {
                    List(ble.devices) { device in
                        NavigationLink(destination: DeviceDetailView(device: device, ble: ble)) {
                            DeviceRowView(device: device)
                        }
                    }
                    .listStyle(.plain)
                }

                Divider()

                // ── Scan button ────────────────────────────────────────────
                ScanButton(ble: ble)
                    .padding()
            }
            .navigationTitle("Device1Finder")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.system(size: 56))
                .foregroundColor(.secondary)
            Text(ble.isScanning ? "Scanning for devices…" : "No devices found")
                .font(.headline)
                .foregroundColor(.secondary)
        }
    }
}

// MARK: - StatusBarView

struct StatusBarView: View {
    @ObservedObject var ble: BleManager

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(dotColor)
                .frame(width: 10, height: 10)
            Text(ble.statusMessage)
                .font(.caption)
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer()
            if ble.isScanning {
                ProgressView()
                    .scaleEffect(0.7)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(Color(.secondarySystemBackground))
    }

    private var dotColor: Color {
        switch ble.bluetoothState {
        case .poweredOn:  return ble.isScanning ? .green : .blue
        case .poweredOff: return .red
        default:          return .gray
        }
    }
}

// MARK: - ScanButton

struct ScanButton: View {
    @ObservedObject var ble: BleManager

    var body: some View {
        Button(action: {
            if ble.isScanning { ble.stopScan() } else { ble.startScan() }
        }) {
            Label(
                ble.isScanning ? "Stop Scan" : "Start Scan",
                systemImage: ble.isScanning ? "stop.fill" : "magnifyingglass"
            )
            .frame(maxWidth: .infinity)
            .padding()
            .background(ble.isScanning ? Color.red : Color.blue)
            .foregroundColor(.white)
            .cornerRadius(12)
            .font(.headline)
        }
        .disabled(ble.bluetoothState != .poweredOn && !ble.isScanning)
    }
}

// MARK: - DeviceRowView  (mirrors ListView item in activity_main.xml)

struct DeviceRowView: View {
    @ObservedObject var device: FoundDevice

    var body: some View {
        HStack(spacing: 12) {
            // Signal icon
            Image(systemName: rssiIcon)
                .foregroundColor(rssiColor)
                .font(.title3)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(device.displayName)
                    .font(.headline)
                    .lineLimit(1)

                Text(device.addr.prefix(23))   // show first segment of UUID
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)

                if let serial = device.serial {
                    Text("S/N: \(serial)")
                        .font(.caption2)
                        .foregroundColor(.blue)
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text("\(device.rssi) dBm")
                    .font(.caption)
                    .foregroundColor(.secondary)
                if device.mfgHits > 1 {
                    Text("×\(device.mfgHits)")
                        .font(.caption2)
                        .foregroundColor(.orange)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var rssiIcon: String {
        switch device.rssi {
        case -50...:      return "wifi"
        case -70..<(-50): return "wifi"
        case -85..<(-70): return "wifi.exclamationmark"
        default:          return "wifi.slash"
        }
    }

    private var rssiColor: Color {
        switch device.rssi {
        case -50...:      return .green
        case -70..<(-50): return .yellow
        case -85..<(-70): return .orange
        default:          return .red
        }
    }
}

// MARK: - DeviceDetailView  (identify / serial actions per device)

struct DeviceDetailView: View {
    @ObservedObject var device: FoundDevice
    @ObservedObject var ble: BleManager

    @State private var actionResult: String?
    @State private var isBusy = false

    var body: some View {
        List {
            // ── Info section ──────────────────────────────────────────────
            Section("Device Info") {
                row("Name",    device.displayName)
                row("UUID",    device.addr)
                row("Label",   device.label)
                row("RSSI",    "\(device.rssi) dBm")
                row("MFG hits", "\(device.mfgHits)")
                if let serial = device.serial {
                    row("Serial", serial)
                }
            }

            // ── Identify section ──────────────────────────────────────────
            Section("Identify") {
                // BLINK – cmd 0x01
                Button(action: { identify(cmd: .blink) }) {
                    Label("Blink LED (0x01)", systemImage: "light.beacon.max.fill")
                        .foregroundColor(.red)
                }
                .disabled(isBusy)

                // SOUND – cmd 0x02
                Button(action: { identify(cmd: .sound) }) {
                    Label("Play Sound (0x02)", systemImage: "speaker.wave.2.fill")
                        .foregroundColor(.blue)
                }
                .disabled(isBusy)
            }

            // ── Serial section ─────────────────────────────────────────────
            Section("Serial Number") {
                Button(action: readSerial) {
                    Label("Read Full Serial", systemImage: "barcode.viewfinder")
                }
                .disabled(isBusy)
            }

            // ── Result ─────────────────────────────────────────────────────
            if let result = actionResult {
                Section("Result") {
                    Text(result)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .navigationTitle(device.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .overlay {
            if isBusy {
                ProgressView("Connecting…")
                    .padding(24)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
            }
        }
    }

    // MARK: - Actions

    private func identify(cmd: BleConstants.Cmd) {
        isBusy = true
        ble.sendIdentify(to: device, cmd: cmd) { success in
            isBusy = false
            actionResult = success
                ? String(format: "Sent identify 0x%02X ✓", cmd.rawValue)
                : "Write failed"
        }
    }

    private func readSerial() {
        isBusy = true
        ble.readSerial(from: device) { serial in
            isBusy = false
            if let s = serial {
                actionResult = "Serial: \(s)"
            } else {
                actionResult = "serial read: service/char missing"
            }
        }
    }

    // MARK: - Helpers

    @ViewBuilder
    private func row(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
                .foregroundColor(.secondary)
            Spacer()
            Text(value)
                .font(.caption)
                .multilineTextAlignment(.trailing)
                .foregroundColor(.primary)
        }
    }
}

// MARK: - Previews

#Preview {
    ContentView()
}
