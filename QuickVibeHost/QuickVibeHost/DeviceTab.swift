import SwiftUI

struct DeviceTab: View {
    @EnvironmentObject var manager: VoiceInputManager
    @EnvironmentObject var hotkeyManager: GlobalHotkeyManager
    @EnvironmentObject var bleManager: BLEManager
    @AppStorage("useNewDeviceTabUI") private var useNewUI: Bool = true

    var body: some View {
        if useNewUI {
            NewDeviceTab()
        } else {
            legacyBody
        }
    }

    private var legacyBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                microphoneSection
                Divider()
                bleSection
            }
            .padding()
        }
    }

    // MARK: - Microphone

    private var microphoneSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(AppL10n.tr("麦克风"))
                .font(.headline)

            if !manager.audioCapture.inputDevices.isEmpty {
                HStack {
                    Text(AppL10n.tr("输入设备"))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Picker("", selection: Binding(
                        get: { manager.audioCapture.selectedDeviceID },
                        set: { manager.audioCapture.selectDevice($0) }
                    )) {
                        ForEach(manager.audioCapture.inputDevices) { device in
                            Text(device.name).tag(device.id)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                }
            }

            HStack {
                Button(action: { manager.toggleRecording() }) {
                    HStack {
                        if manager.state == .processing {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: recordButtonIcon)
                                .foregroundStyle(recordButtonColor)
                        }
                        Text(recordButtonText)
                    }
                    .frame(maxWidth: .infinity)
                }
                .disabled(manager.state == .processing)
                .keyboardShortcut("r", modifiers: [.command, .shift])
            }

            if case .error(let msg) = manager.state {
                Text(msg)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(3)
            }

            if !manager.isConfigured {
                Text(AppL10n.tr("请先在设置中配置豆包 ASR 密钥"))
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    // MARK: - BLE Stick S3

    private var bleSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("BLE Stick S3")
                    .font(.headline)
                Spacer()
                HStack(spacing: 4) {
                    Circle()
                        .fill(bleStatusColor)
                        .frame(width: 8, height: 8)
                    Text(bleStatusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 8) {
                Text(bleActionText)
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)
                Spacer()
                if bleManager.connectionState == .scanning {
                    Button(AppL10n.tr("停止扫描")) {
                        bleManager.stopScan()
                    }
                } else if bleManager.connectionState == .connected {
                    Button(AppL10n.tr("断开")) {
                        bleManager.disconnect()
                    }
                    .foregroundStyle(.red)
                } else if bleManager.connectionState == .connecting {
                    Button(AppL10n.tr("取消")) {
                        bleManager.disconnect()
                    }
                } else {
                    Button(AppL10n.tr("扫描设备")) {
                        bleManager.startScan()
                    }
                }
            }

            // 扫描到的设备列表
            if bleManager.connectionState == .scanning && !bleManager.discoveredDevices.isEmpty {
                VStack(spacing: 0) {
                    ForEach(bleManager.discoveredDevices) { device in
                        Button {
                            bleManager.connect(to: device)
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "antenna.radiowaves.left.and.right")
                                    .foregroundStyle(.secondary)
                                    .frame(width: 16)
                                Text(device.name)
                                    .font(.subheadline)
                                Spacer()
                                Text(rssiLabel(device.rssi))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Image(systemName: rssiIcon(device.rssi))
                                    .foregroundStyle(rssiColor(device.rssi))
                                    .font(.caption)
                            }
                            .padding(.vertical, 6)
                            .padding(.horizontal, 8)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        if device.id != bleManager.discoveredDevices.last?.id {
                            Divider()
                        }
                    }
                }
                .background(RoundedRectangle(cornerRadius: 6).fill(Color(.quaternaryLabelColor).opacity(0.5)))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        }
    }

    // MARK: - Computed Properties

    private var recordButtonIcon: String {
        manager.state == .recording ? "stop.circle.fill" : "mic.circle.fill"
    }

    private var recordButtonColor: Color {
        manager.state == .recording ? .red : .accentColor
    }

    private var recordButtonText: String {
        let key = hotkeyManager.hotkeyDisplayName
        switch manager.state {
        case .recording: return AppL10n.format("停止录音 (%@)", key)
        case .processing: return AppL10n.tr("识别中...")
        default: return AppL10n.format("开始录音 (%@)", key)
        }
    }

    private var bleStatusColor: Color {
        switch bleManager.connectionState {
        case .connected: .green
        case .disconnected: .secondary
        default: .orange
        }
    }

    private var bleStatusText: String {
        switch bleManager.connectionState {
        case .connected: bleManager.connectedDeviceName ?? AppL10n.tr("已连接")
        default: bleManager.connectionState.displayName
        }
    }

    private var bleActionText: String {
        switch bleManager.connectionState {
        case .connected:
            if bleManager.isReceivingAudio { return AppL10n.format("● 接收中 %@ 包", String(bleManager.packetsReceived)) }
            if bleManager.packetsReceived > 0 { return AppL10n.format("%@ 包", String(bleManager.packetsReceived)) }
            return AppL10n.tr("已就绪")
        case .scanning:
            let count = bleManager.discoveredDevices.count
            return count > 0 ? AppL10n.format("发现 %@ 台设备", String(count)) : AppL10n.tr("搜索中...")
        case .connecting: return AppL10n.tr("连接中...")
        case .disconnected: return ""
        }
    }

    private func rssiLabel(_ rssi: Int) -> String {
        if rssi == 0 { return "-- dBm" }
        return "\(rssi) dBm"
    }

    private func rssiIcon(_ rssi: Int) -> String {
        if rssi == 0 { return "wifi.slash" }
        if rssi >= -50 { return "wifi" }
        if rssi >= -70 { return "wifi" }
        return "wifi.exclamationmark"
    }

    private func rssiColor(_ rssi: Int) -> Color {
        if rssi == 0 { return .secondary }
        if rssi >= -50 { return .green }
        if rssi >= -70 { return .orange }
        return .red
    }
}
