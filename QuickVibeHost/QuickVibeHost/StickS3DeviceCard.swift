import SwiftUI

/// 已记忆 Stick S3 设备的卡片：连接 / 重连中 / 已断开 三态。
/// 布局：header 一行放 绿点+名+断开/重连+移除设备；
/// 信息块放在 header 下方，已就绪/接收状态紧跟协议版本下。
struct StickS3DeviceCard: View {
    @EnvironmentObject var bleManager: BLEManager
    @State private var confirmingForget = false
    @State private var isForgetHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            HStack(alignment: .top, spacing: 10) {
                Image("StickS3Scratch")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 44, height: 76)

                VStack(alignment: .leading, spacing: 4) {
                    Text(statusText)
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundStyle(statusTextColor)
                    Text(protocolText)
                        .font(.caption2)
                        .foregroundStyle(bleManager.deviceProtocolVersion > 0 && bleManager.deviceProtocolVersion < VibePanelBLE.protocolVersion ? Color.red : Color.secondary)

                    if bleManager.connectionState == .connected {
                        readyStatusRow
                    }
                }

                Spacer()
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.primary.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.primary.opacity(0.12), lineWidth: 1)
        )
        .confirmationDialog(
            AppL10n.tr("移除后将断开连接并清除设备记忆，确定？"),
            isPresented: $confirmingForget,
            titleVisibility: .visible
        ) {
            Button(AppL10n.tr("移除设备"), role: .destructive) { bleManager.forgetDevice() }
            Button(AppL10n.tr("取消"), role: .cancel) {}
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
            Text(bleManager.memorizedDeviceName ?? "Stick S3")
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.middle)
                .layoutPriority(1)
            Spacer()
            actionButtons
                .controlSize(.small)
            Button {
                confirmingForget = true
            } label: {
                Text(AppL10n.tr("移除设备"))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .foregroundStyle(isForgetHovering ? Color.red : Color.secondary)
            .onHover { isForgetHovering = $0 }
            .help(AppL10n.tr("移除设备"))
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
                .foregroundStyle(.red)
        case .memorizedReconnecting:
            Button(AppL10n.tr("取消重连")) { bleManager.disconnect() }
                .buttonStyle(.bordered)
        case .memorizedWaiting:
            Button(AppL10n.tr("取消等待")) { bleManager.disconnect() }
                .buttonStyle(.bordered)
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
        let current = bleManager.deviceProtocolVersion == 0 ? "?" : "\(bleManager.deviceProtocolVersion)"
        return AppL10n.format("协议 v%@ / 要求 v%@", String(current), String(VibePanelBLE.protocolVersion))
    }
}
