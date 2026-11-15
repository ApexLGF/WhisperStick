import SwiftUI

/// 已记忆 VE 语音棒(MicPad)设备的卡片：连接 / 重连中 / 等待 / 未连接 / 无记忆 五态。
/// 复刻 StickS3DeviceCard —— 读同一份 `bleManager` 状态；仅换设备线稿图与默认名。
/// 布局：设备图与信息位于同一张卡片内；操作区紧邻右侧更多菜单。
struct MicPadDeviceCard: View {
    @EnvironmentObject var bleManager: BLEManager
    @State private var confirmingForget = false
    @State private var confirmingTransportMode = false
    @State private var isDisconnectHovering = false

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            deviceArtwork

            VStack(alignment: .leading, spacing: 6) {
                header

                VStack(alignment: .leading, spacing: 3) {
                    Text(statusText)
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundStyle(statusTextColor)
                    Text(protocolText)
                        .font(.caption2)
                        .foregroundStyle(protocolTextColor)
                        .lineLimit(1)
                    if bleManager.connectionState == .connected,
                       bleManager.isConnectedMicStick {
                        firmwareStatusArea
                    }
                }

                // v5(REQ-007): 版本不匹配拒连提示
                if let mismatch = bleManager.versionMismatchMessage {
                    Text(mismatch)
                        .font(.caption2)
                        .foregroundStyle(.red)
                }

                if bleManager.connectionState == .connected {
                    readyStatusRow
                }
                // REQ-015: 语音操作选择已移至设备 TAB 独立区块
                // (MicPadVoiceModeSection,NewDeviceTab.swift)

            }
            .frame(maxWidth: .infinity, minHeight: 112, alignment: .leading)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.primary.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.primary.opacity(0.12), lineWidth: 1)
        )
        .confirmationDialog(
            AppL10n.tr("移除后将断开连接并清除设备记忆，确定？"),
            isPresented: $confirmingForget,
            titleVisibility: .visible
        ) {
            Button(AppL10n.tr("移除设备"), role: .destructive) { bleManager.forgetDevice() }
                .disabled(bleManager.firmwareUpdateState.isActive ||
                          bleManager.firmwareUpdateState == .downloading)
            Button(AppL10n.tr("取消"), role: .cancel) {}
        }
        .alert(
            AppL10n.tr("进入运输模式？"),
            isPresented: $confirmingTransportMode
        ) {
            Button(AppL10n.tr("进入运输模式"), role: .destructive) {
                bleManager.requestDeviceTransportModeConfirmation()
            }
            Button(AppL10n.tr("取消"), role: .cancel) {}
        } message: {
            Text(AppL10n.tr("设备将断开电池并完全关机。开机时，请先长按侧面 SW1 约 1 秒（或插入 USB 充电），再按任意键。"))
        }
        .onAppear {
            if bleManager.connectionState == .connected,
               bleManager.isConnectedMicStick {
                bleManager.refreshMicStickFirmwareUpdate()
            }
        }
    }

    private var displayedDeviceName: String? {
        bleManager.connectedDeviceName ?? bleManager.memorizedDeviceName
    }

    private var deviceArtwork: some View {
        MicPadFamilyDeviceArtwork(deviceName: displayedDeviceName)
            .frame(width: 56, height: 112)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
            Text(bleManager.memorizedDeviceName ?? AppL10n.tr("VE 语音棒"))
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.middle)
                .layoutPriority(1)
            Spacer()
            actionButtons
                .controlSize(.small)
            Menu {
                Button(AppL10n.tr("移除设备"), role: .destructive) {
                    confirmingForget = true
                }
                .disabled(bleManager.firmwareUpdateState.isActive ||
                          bleManager.firmwareUpdateState == .downloading)
                if bleManager.deviceLifecycle == .memorizedConnected &&
                    bleManager.supportsTransportMode {
                    Divider()
                    Button {
                        confirmingTransportMode = true
                    } label: {
                        Label(AppL10n.tr("运输模式"), systemImage: "shippingbox")
                    }
                    .disabled(!bleManager.characteristicsReady ||
                              bleManager.deviceProtocolVersion < 5)
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
            }
            .menuStyle(.borderlessButton)
            .help(AppL10n.tr("更多操作"))
        }
    }

    @ViewBuilder
    private var readyStatusRow: some View {
        HStack(spacing: 10) {
            if bleManager.isReceivingAudio {
                Label(AppL10n.format("接收中 %@ 包", String(bleManager.packetsReceived)), systemImage: "waveform")
                    .font(.caption2)
                    .foregroundStyle(.green)
            } else if bleManager.packetsReceived > 0 {
                Text(AppL10n.format("%@ 包 · %@ KB", String(bleManager.packetsReceived), String(bleManager.bytesReceived / 1024)))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                Text(AppL10n.tr("已就绪"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if !bleManager.characteristicsReady {
                Text(AppL10n.tr("· 特征发现中…"))
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
    }

    @ViewBuilder
    private var actionButtons: some View {
        switch bleManager.deviceLifecycle {
        case .memorizedConnected:
            Button(AppL10n.tr("断开")) { bleManager.disconnect() }
                .buttonStyle(.bordered)
                .foregroundStyle(isDisconnectHovering ? Color.red : Color.secondary)
                .onHover { isDisconnectHovering = $0 }
                .disabled(bleManager.firmwareUpdateState.isActive ||
                          bleManager.firmwareUpdateState == .downloading)
        case .memorizedReconnecting:
            Button(AppL10n.tr("取消重连")) { bleManager.disconnect() }
                .buttonStyle(.bordered)
                .disabled(bleManager.firmwareUpdateState.isActive ||
                          bleManager.firmwareUpdateState == .downloading)
        case .memorizedWaiting:
            Button(AppL10n.tr("取消等待")) { bleManager.disconnect() }
                .buttonStyle(.bordered)
                .disabled(bleManager.firmwareUpdateState.isActive ||
                          bleManager.firmwareUpdateState == .downloading)
        case .memorizedFailed:
            Button(AppL10n.tr("重新连接")) { bleManager.retryConnect() }
                .buttonStyle(.borderedProminent)
        case .noMemory:
            EmptyView()
        }
    }

    private var statusColor: Color {
        switch bleManager.deviceLifecycle {
        case .memorizedConnected: return .green
        case .memorizedReconnecting: return .secondary
        case .memorizedWaiting: return .orange
        case .memorizedFailed: return .red
        case .noMemory: return .secondary
        }
    }

    private var statusText: String {
        switch bleManager.deviceLifecycle {
        case .memorizedConnected:
            return AppL10n.tr("已连接")
        case .memorizedReconnecting(let attempt):
            return AppL10n.format("连接中 · 第 %@ 次", String(attempt))
        case .memorizedWaiting:
            return AppL10n.tr("等待设备出现 · 自动重连")
        case .memorizedFailed:
            return AppL10n.tr("未连接")
        case .noMemory:
            return ""
        }
    }

    private var statusTextColor: Color {
        switch bleManager.deviceLifecycle {
        case .memorizedConnected: return .green
        case .memorizedWaiting: return .orange
        case .memorizedFailed: return .red
        case .memorizedReconnecting, .noMemory: return .secondary
        }
    }

    private var protocolText: String {
        if bleManager.deviceProtocolVersion == 0 {
            return AppL10n.format("协议未知 · 需要 v%@", String(VibePanelBLE.micPadProtocolVersion))
        }
        return AppL10n.format("协议 v%@ · 需要 v%@", String(bleManager.deviceProtocolVersion), String(VibePanelBLE.micPadProtocolVersion))
    }

    private var protocolTextColor: Color {
        bleManager.deviceProtocolVersion > 0 && bleManager.deviceProtocolVersion != VibePanelBLE.micPadProtocolVersion ? .red : .secondary
    }

    private var firmwareVersionText: String {
        guard let version = bleManager.micStickFirmwareVersion, !version.isEmpty else {
            return AppL10n.tr("固件版本读取中…")
        }
        return AppL10n.format("固件 v%@", version)
    }

    @ViewBuilder
    private var firmwareStatusArea: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Text(firmwareVersionText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Spacer(minLength: 6)

                if bleManager.firmwareUpdateState == .available,
                   let target = bleManager.availableMicStickFirmwareVersion {
                    Text(AppL10n.format("可更新至 %@", target))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Button(AppL10n.tr("更新固件")) {
                        bleManager.startMicStickFirmwareUpdate()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(bleManager.isReceivingAudio)
                }
            }

            firmwareUpdateStatus
        }
    }

    @ViewBuilder
    private var firmwareUpdateStatus: some View {
        switch bleManager.firmwareUpdateState {
        case .checking:
            compactFirmwareActivity(AppL10n.tr("正在检查更新…"))
        case .downloading:
            firmwareProgressRow(label: AppL10n.tr("正在下载固件"), progress: nil,
                                allowsCancellation: true)
        case .transferring:
            let progress = bleManager.firmwareUpdateProgress
            let label = progress.map {
                AppL10n.format("正在传输 %@%%", String(Int($0 * 100)))
            } ?? AppL10n.tr("正在传输固件")
            firmwareProgressRow(label: label, progress: progress, allowsCancellation: true)
        case .waitingForReboot, .verifying:
            VStack(alignment: .leading, spacing: 2) {
                compactFirmwareActivity(AppL10n.tr("正在验证固件"), color: .orange)
                Text(AppL10n.tr("更新期间请勿断开设备电源"))
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        case .succeeded:
            Label(AppL10n.tr("更新完成"), systemImage: "checkmark.circle.fill")
                .font(.caption2)
                .foregroundStyle(.green)
        case .cancelled:
            HStack(spacing: 8) {
                Text(AppL10n.tr("更新已取消"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 6)
                Button(AppL10n.tr("检查更新")) {
                    bleManager.refreshMicStickFirmwareUpdate()
                }
                .controlSize(.small)
            }
        case .failed:
            HStack(spacing: 8) {
                Text(bleManager.availableMicStickFirmwareVersion == nil
                     ? AppL10n.tr("无法检查固件更新")
                     : AppL10n.tr("固件更新失败"))
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .lineLimit(1)
                Spacer(minLength: 6)
                Button(AppL10n.tr("检查更新")) {
                    bleManager.refreshMicStickFirmwareUpdate()
                }
                .controlSize(.small)
            }
        case .available, .unavailable:
            EmptyView()
        }
    }

    private func compactFirmwareActivity(_ label: String, color: Color = .secondary) -> some View {
        HStack(spacing: 6) {
            ProgressView()
                .controlSize(.small)
            Text(label)
                .font(.caption2)
                .foregroundStyle(color)
        }
    }

    private func firmwareProgressRow(label: String, progress: Double?,
                                     allowsCancellation: Bool) -> some View {
        HStack(spacing: 8) {
            Group {
                if let progress {
                    ProgressView(value: progress)
                } else {
                    ProgressView()
                }
            }
            .frame(maxWidth: 130)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 6)
            if allowsCancellation {
                Button(AppL10n.tr("取消更新"), role: .cancel) {
                    bleManager.cancelMicStickFirmwareUpdate()
                }
                .controlSize(.small)
            }
        }
    }
}

/// MicPad 协议族的产品图。MicStick 的 PNG 是普通 bundle 资源，MicPad 继续使用 asset。
struct MicPadFamilyDeviceArtwork: View {
    let deviceName: String?

    var body: some View {
        deviceArtwork
            .resizable()
            .scaledToFit()
    }

    /// MicStick 资源缺失时安全回退到同协议族的 MicPad 线稿。
    private var deviceArtwork: Image {
        let imageName = DeviceType.micPadFamilyImageName(for: deviceName)
        if imageName == "LineQVMSImage",
           let url = Bundle.main.url(forResource: imageName, withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            return Image(nsImage: image)
        }
        return Image("MicPadScratch")
    }
}
