import SwiftUI

/// BLE 扫描/发现面板(单一入口)。展示全部已识别的自有设备(Stick S3 / MicPad)。
struct DeviceDiscoverySheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        DeviceDiscoveryContent {
            dismiss()
        }
    }
}

/// Shared BLE discovery content for the sheet and first-run setup.
struct DeviceDiscoveryContent: View {
    @EnvironmentObject var bleManager: BLEManager
    var width: CGFloat? = 420
    var onSelect: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text(AppL10n.tr("发现设备"))
                    .font(.headline)
                Spacer()
                scanActionButton
                if let onSelect {
                    Button { onSelect() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 12, weight: .medium))
                            .frame(width: 28, height: 28)
                    }
                        .buttonStyle(.plain)
                        .foregroundStyle(.tertiary)
                        .help(AppL10n.tr("关闭"))
                }
            }

            if filteredDevices.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "dot.radiowaves.left.and.right")
                        .font(.system(size: 28))
                        .foregroundStyle(.secondary)

                    VStack(spacing: 3) {
                        Text(emptyStateTitle)
                            .font(.subheadline)
                            .fontWeight(.medium)
                            .foregroundStyle(.secondary)
                        Text(emptyStateMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 118)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.primary.opacity(0.06))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.primary.opacity(0.10), lineWidth: 1)
                )
            } else {
                VStack(spacing: 0) {
                    ForEach(filteredDevices) { device in
                        Button {
                            bleManager.connect(to: device)
                            onSelect?()
                        } label: {
                            HStack(spacing: 8) {
                                bluetoothIcon
                                Text(device.name)
                                    .font(.subheadline)
                                if let type = device.type {
                                    Text(deviceTypeLabel(type))
                                        .font(.caption2)
                                        .fontWeight(.medium)
                                        .foregroundStyle(.secondary)
                                        .padding(.horizontal, 7)
                                        .padding(.vertical, 3)
                                        .background(
                                            RoundedRectangle(cornerRadius: 6)
                                                .fill(Color.primary.opacity(0.06))
                                        )
                                }
                                Spacer()
                                Text(rssiLabel(device.rssi))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Image(systemName: rssiIcon(device.rssi))
                                    .foregroundStyle(rssiColor(device.rssi))
                                    .font(.caption)
                            }
                            .padding(.vertical, 8)
                            .padding(.horizontal, 10)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(rssiHelp(device.rssi))
                        if device.id != filteredDevices.last?.id {
                            Divider()
                        }
                    }
                }
                .background(RoundedRectangle(cornerRadius: 6).fill(Color(.quaternaryLabelColor).opacity(0.4)))
            }
        }
        .padding(16)
        .frame(width: width)
        .onAppear { bleManager.startScan() }
        .onDisappear {
            if bleManager.connectionState == .scanning {
                bleManager.stopScan()
            }
        }
    }

    @ViewBuilder
    private var scanActionButton: some View {
        if bleManager.connectionState == .scanning {
            Button { bleManager.stopScan() } label: {
                Text(AppL10n.tr("停止扫描"))
                    .font(.caption)
                    .fontWeight(.semibold)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.primary.opacity(0.06))
                    )
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        } else {
            Button { bleManager.startScan() } label: {
                Text(AppL10n.tr("开始扫描"))
                    .font(.caption)
                    .fontWeight(.semibold)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.accentColor)
                    )
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white)
        }
    }

    private var emptyStateTitle: String {
        switch bleManager.connectionState {
        case .scanning: return AppL10n.tr("正在搜索附近设备…")
        case .connecting: return AppL10n.tr("正在连接设备…")
        case .connected: return AppL10n.tr("已连接")
        case .disconnected: return AppL10n.tr("准备扫描设备")
        }
    }

    private var emptyStateMessage: String {
        switch bleManager.connectionState {
        case .scanning: return AppL10n.tr("请确认设备已开机并靠近 Mac")
        case .connecting: return AppL10n.tr("请稍候")
        case .connected: return ""
        case .disconnected: return AppL10n.tr("打开设备并靠近 Mac")
        }
    }

    private var bluetoothIcon: some View {
        Image(nsImage: NSImage(named: NSImage.Name("NSBluetoothTemplate")) ?? NSImage())
            .resizable()
            .scaledToFit()
            .foregroundStyle(.secondary)
            .frame(width: 16, height: 16)
    }

    /// 展示全部已识别的自有设备(Stick S3 / MicPad 共用 audio Service UUID,
    /// 分型后按名前缀已带 type;单入口不再按单一类型过滤,否则 MicPad 会被漏掉)。
    private var filteredDevices: [DiscoveredDevice] {
        bleManager.discoveredDevices.filter { $0.type != nil }
    }

    private func rssiLabel(_ rssi: Int) -> String {
        if rssi == 0 { return AppL10n.tr("信号未知") }
        if rssi >= -65 { return AppL10n.tr("信号良好") }
        if rssi >= -75 { return AppL10n.tr("信号一般") }
        return AppL10n.tr("信号较弱")
    }

    private func deviceTypeLabel(_ type: DeviceType) -> String {
        switch type {
        case .micPad: return AppL10n.tr("VE 语音棒")
        case .stickS3: return "Stick S3"
        }
    }

    private func rssiHelp(_ rssi: Int) -> String {
        rssi == 0 ? AppL10n.tr("信号强度未知") : AppL10n.format("信号强度 %@ dBm", String(rssi))
    }

    private func rssiIcon(_ rssi: Int) -> String {
        if rssi == 0 { return "wifi.slash" }
        if rssi >= -70 { return "wifi" }
        return "wifi.exclamationmark"
    }

    private func rssiColor(_ rssi: Int) -> Color {
        if rssi == 0 { return .secondary }
        if rssi >= -65 { return .green }
        if rssi >= -75 { return .orange }
        return .red
    }
}
