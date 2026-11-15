import SwiftUI

/// 输入模式介绍(设备 TAB)。
/// 从设置页 Beta 区整块迁来：自由 / 直通两条说明 + 直通开关 + vibepty alias 安装 UI。
/// `@AppStorage("enableExclusiveInputMode")` key 不变 → 直通/自由行为零回归(只挪 View)。
struct InputModeIntroSection: View {
    @EnvironmentObject var aliasInstaller: VibeptyAliasInstaller
    /// 「重新检测」点击反馈:refreshStatus 是同步秒查,结果不变时 UI 无变化,
    /// 短暂切换按钮文案确认检测确实执行过,不额外撑开布局。
    @State private var recheckAcknowledged = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // 自由模式(默认)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(AppL10n.tr("自由模式"))
                        .font(.subheadline)
                        .fontWeight(.medium)
                    Spacer()
                    Text(AppL10n.tr("默认"))
                        .font(.caption2)
                        .fontWeight(.medium)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            Capsule()
                                .fill(Color.primary.opacity(0.06))
                        )
                }
                // 【REQ-013-待确认】草稿,待 user 用 REQ-013 原文校对替换
                Text(AppL10n.tr("语音文本输入到当前光标所在窗口，像键盘输入一样，适合临时记录和单窗口使用。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            // 直通模式(原设置页 Beta 区,整块迁移)
            VStack(alignment: .leading, spacing: 10) {
                Text(AppL10n.tr("直通模式"))
                    .font(.subheadline)
                    .fontWeight(.medium)

                // REQ-013 ②改:直通开关移除,恒可用——选中会话即直通,未选中即自由模式
                Text(AppL10n.tr("选中可直通会话后，语音文本直接写入对应终端；未选中时回到自由模式。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                vibeptyStatusBlock
                    .task {
                        aliasInstaller.refreshStatus()
                    }
            }
        }
    }

    // MARK: - vibepty 依赖状态(REQ-013:并入直通模式,无独立区/无折叠;单条状态,重新检测保留)

    @ViewBuilder
    private var vibeptyStatusBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            if aliasInstaller.isInstalling {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(AppL10n.tr("正在安装直通注入环境…")).font(.caption)
                }
            } else {
                vibeptyStatusContent
            }

            if let err = aliasInstaller.lastError {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
                if let log = aliasInstaller.lastInstallLog, !log.isEmpty {
                    ScrollView {
                        Text(log)
                            .font(.system(.caption2, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 120)
                    .padding(6)
                    .background(Color(NSColor.textBackgroundColor).opacity(0.5))
                    .cornerRadius(4)
                }
            }
        }
    }

    @ViewBuilder
    private var vibeptyStatusContent: some View {
        switch aliasInstaller.status {
        case .unknown:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(AppL10n.tr("正在检测直通注入环境…")).font(.caption)
            }

        case .installed:
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
                Text(AppL10n.tr("直通注入已就绪，重新打开终端后生效"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(recheckAcknowledged ? AppL10n.tr("已检测") : AppL10n.tr("重新检测")) {
                    aliasInstaller.refreshStatus()
                    recheckAcknowledged = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        recheckAcknowledged = false
                    }
                }
                .controlSize(.small)
                .frame(minWidth: 72)
            }

        case .notInstalled:
            statusLine(icon: "exclamationmark.triangle.fill",
                       color: .orange,
                       text: AppL10n.tr("直通注入需要安装终端 alias。"))
            Text(AppL10n.tr("**App 仅检测 `~/.zshrc`**：若您使用 bash / fish / nushell，即使脚本为您的 shell 成功写入了 alias，此处仍会显示未安装。其他 shell 请参考手动安装说明。"))
                .font(.caption2)
                .foregroundStyle(.secondary)
            installButton(label: AppL10n.tr("一键安装 vibepty alias"))

        case .partialFileOnly:
            statusLine(icon: "wrench.fill",
                       color: .orange,
                       text: AppL10n.tr("已安装 vibepty，但未找到终端 alias 配置。"))
            installButton(label: AppL10n.tr("修复安装"))

        case .partialMarkerOnly:
            statusLine(icon: "wrench.fill",
                       color: .orange,
                       text: AppL10n.tr("已找到 alias 标记，但 vibepty 可执行文件缺失。"))
            installButton(label: AppL10n.tr("重新安装"))

        case .aliasLineBroken:
            statusLine(icon: "wrench.fill",
                       color: .orange,
                       text: AppL10n.tr("alias 指向过期或错误路径。"))
            installButton(label: AppL10n.tr("修复安装"))

        case .versionOutdated:
            HStack(spacing: 8) {
                statusLine(icon: "arrow.triangle.2.circlepath.circle.fill",
                           color: .orange,
                           text: AppL10n.tr("直通组件有更新，更新后重新打开终端生效。"))
                Spacer()
                installButton(label: AppL10n.tr("更新组件"))
                    .frame(minWidth: 72)
            }

        case .detectionError(let msg):
            statusLine(icon: "xmark.circle.fill",
                       color: .red,
                       text: msg)
            Button(AppL10n.tr("重试检测")) { aliasInstaller.refreshStatus() }
                .controlSize(.small)
        }
    }

    private func statusLine(icon: String, color: Color, text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(color)
                .frame(width: 14)
            Text(text)
                .font(.caption)
        }
    }

    private func installButton(label: String) -> some View {
        Button {
            Task { await aliasInstaller.install() }
        } label: {
            Text(label)
        }
        .controlSize(.small)
        .disabled(aliasInstaller.isInstalling)
    }
}
