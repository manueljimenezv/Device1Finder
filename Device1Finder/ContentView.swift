import SwiftUI
import CoreBluetooth

@main
struct Device1FinderApp: App {
    var body: some Scene {
        WindowGroup { ContentView() }
    }
}

struct ContentView: View {
    @StateObject private var ble = BleManager()
    @State private var targetFilter = ""

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                StatusBarView(ble: ble)

                // Target filter (mirrors etTarget EditText)
                HStack {
                    Image(systemName: "magnifyingglass").foregroundColor(.secondary)
                    TextField("Filter by serial or ID…", text: $targetFilter)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.characters)
                        .onChange(of: targetFilter) { ble.targetFilter = $0.uppercased().replacingOccurrences(of: " ", with: "") }
                }
                .padding(8)
                .background(Color(.secondarySystemBackground))
                .cornerRadius(8)
                .padding(.horizontal)
                .padding(.vertical, 6)

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
                ScanButton(ble: ble).padding()
            }
            .navigationTitle("Device1Finder")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.system(size: 56)).foregroundColor(.secondary)
            Text(ble.isScanning ? "Scanning for devices…" : "No devices found")
                .font(.headline).foregroundColor(.secondary)
            if ble.isScanning {
                Text("MFG_ID=0x\(String(BleConstants.mfgID, radix: 16, uppercase: true))")
                    .font(.caption).foregroundColor(.secondary)
            }
        }
    }
}

struct StatusBarView: View {
    @ObservedObject var ble: BleManager
    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(dotColor).frame(width: 10, height: 10)
            Text(ble.statusMessage)
                .font(.caption).foregroundColor(.secondary).lineLimit(1)
            Spacer()
            if ble.isScanning { ProgressView().scaleEffect(0.7) }
        }
        .padding(.horizontal).padding(.vertical, 8)
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

struct ScanButton: View {
    @ObservedObject var ble: BleManager
    var body: some View {
        Button(action: { if ble.isScanning { ble.stopScan() } else { ble.startScan() } }) {
            Label(ble.isScanning ? "Stop Scan" : "Start Scan",
                  systemImage: ble.isScanning ? "stop.fill" : "magnifyingglass")
                .frame(maxWidth: .infinity).padding()
                .background(ble.isScanning ? Color.red : Color.blue)
                .foregroundColor(.white).cornerRadius(12).font(.headline)
        }
        .disabled(ble.bluetoothState != .poweredOn && !ble.isScanning)
    }
}

struct DeviceRowView: View {
    @ObservedObject var device: FoundDevice
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: rssiIcon).foregroundColor(rssiColor).font(.title3).frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(device.displayName).font(.headline).lineLimit(1)
                Text(device.idHex).font(.caption).foregroundColor(.secondary).lineLimit(1)
                if let full = device.fullId {
                    Text("S/N: \(full)").font(.caption2).foregroundColor(.blue)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text("\(device.rssi) dBm").font(.caption).foregroundColor(.secondary)
                Text("×\(device.mfgHits)").font(.caption2).foregroundColor(.orange)
            }
        }
        .padding(.vertical, 4)
    }
    private var rssiIcon: String {
        if device.rssi >= -50 { return "wifi" }
        if device.rssi >= -70 { return "wifi" }
        if device.rssi >= -85 { return "wifi.exclamationmark" }
        return "wifi.slash"
    }
    private var rssiColor: Color {
        if device.rssi >= -50 { return .green }
        if device.rssi >= -70 { return .yellow }
        if device.rssi >= -85 { return .orange }
        return .red
    }
}

struct DeviceDetailView: View {
    @ObservedObject var device: FoundDevice
    @ObservedObject var ble: BleManager
    @State private var actionResult: String?
    @State private var isBusy = false

    var body: some View {
        List {
            Section("Device Info") {
                row("Name",     device.displayName)
                row("UUID",     device.addr)
                row("ID (hex)", device.idHex)
                if let full = device.fullId { row("Full serial", full) }
                row("RSSI",     "\(device.rssi) dBm")
                row("MFG hits", "\(device.mfgHits)")
            }
            Section("Identify") {
                Button(action: { identify(cmd: .blink) }) {
                    Label("Blink LED (0x01)", systemImage: "light.beacon.max.fill").foregroundColor(.red)
                }.disabled(isBusy)
                Button(action: { identify(cmd: .sound) }) {
                    Label("Play Sound (0x02)", systemImage: "speaker.wave.2.fill").foregroundColor(.blue)
                }.disabled(isBusy)
                Button(action: { identify(cmd: .both) }) {
                    Label("Blink + Sound (0x03)", systemImage: "bolt.fill").foregroundColor(.purple)
                }.disabled(isBusy)
            }
            Section("Serial Number") {
                Button(action: readSerial) {
                    Label("Read Full Serial", systemImage: "barcode.viewfinder")
                }.disabled(isBusy)
            }
            if let result = actionResult {
                Section("Result") {
                    Text(result).font(.caption).foregroundColor(.secondary)
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

    private func identify(cmd: BleConstants.Cmd) {
        isBusy = true
        ble.sendIdentify(to: device, cmd: cmd) { success in
            isBusy = false
            actionResult = success
                ? String(format: "Sent 0x%02X ✓", cmd.rawValue)
                : "Write failed"
        }
    }

    private func readSerial() {
        isBusy = true
        ble.readSerial(from: device) { serial in
            isBusy = false
            actionResult = serial.map { "Serial: \($0)" } ?? "serial read: service/char missing"
        }
    }

    @ViewBuilder
    private func row(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title).foregroundColor(.secondary)
            Spacer()
            Text(value).font(.caption).multilineTextAlignment(.trailing)
        }
    }
}

#Preview { ContentView() }
