import SwiftUI

/// 设备生命周期为 `.noMemory` 时的空态：说明文案 + 单个「添加设备」按钮。
struct NoDeviceEmptyState<Intro: View>: View {
    let onAdd: () -> Void
    @ViewBuilder var intro: () -> Intro

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 18)
                Text(AppL10n.tr("添加第一台设备"))
                    .font(.headline)
                Spacer()
                AddDeviceButton(action: onAdd)
            }

            Text(AppL10n.tr("打开设备并靠近 Mac，即可开始扫描。"))
                .font(.caption)
                .foregroundStyle(.secondary)

            intro()
        }
    }
}

/// 单一「添加设备」按钮 —— 走一体化发现流程(DeviceDiscoverySheet)。
struct AddDeviceButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "plus.circle.fill")
                Text(AppL10n.tr("添加设备"))
                    .fontWeight(.medium)
            }
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.regular)
    }
}
