import SwiftUI

/// 首次启用本地引擎且模型未下载时显示的轻量提示条。
/// **不静默失败、不自动回退云端** — 用户必须点"下载模型"或主动切到豆包云端。
struct FirstRunASRGuide: View {
    @EnvironmentObject var modelManager: ASRModelManager
    @EnvironmentObject var manager: VoiceInputManager

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.circle")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.tint)
                    .frame(width: 18, height: 18)
                VStack(alignment: .leading, spacing: 3) {
                    Text(AppL10n.tr("首次使用需先下载离线模型"))
                        .font(.subheadline.weight(.semibold))
                    Text(AppL10n.tr("本地识别依赖 SeACo-Paraformer；未下载前，本地 ASR 不会生效。"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack(spacing: 8) {
                Color.clear
                    .frame(width: 18)
                Button {
                    Task { await modelManager.downloadModels() }
                } label: {
                    Text(AppL10n.tr("下载模型"))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(isDownloading)

                Button(AppL10n.tr("切到豆包云端")) {
                    manager.asrEngine = .doubao
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            if case .downloading(let progress) = modelManager.state {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                Text(AppL10n.format("下载中 %@%", String(Int(progress * 100))))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            if case .failed(let reason) = modelManager.state {
                Text(reason)
                    .font(.caption)
                .foregroundStyle(.red)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.accentColor.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.accentColor.opacity(0.18), lineWidth: 1)
        )
    }

    private var isDownloading: Bool {
        if case .downloading = modelManager.state { return true }
        if case .verifying = modelManager.state { return true }
        return false
    }
}
