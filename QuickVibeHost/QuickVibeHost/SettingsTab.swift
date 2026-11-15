import SwiftUI

import ServiceManagement
import UserNotifications
import AVFoundation
import AppKit
import CoreBluetooth

enum SettingsCategory: String, CaseIterable, Hashable, Identifiable {
    case general, shortcuts, voice, permissions, laboratory, productUpdates
    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .general: return AppL10n.tr("通用")
        case .shortcuts: return AppL10n.tr("快捷键")
        case .voice: return AppL10n.tr("语音")
        case .permissions: return AppL10n.tr("权限")
        case .laboratory: return AppL10n.tr("高级功能")
        case .productUpdates: return AppL10n.tr("产品更新")
        }
    }

    var subtitle: String {
        switch self {
        case .general: return AppL10n.tr("General")
        case .shortcuts: return AppL10n.tr("Shortcuts")
        case .voice: return AppL10n.tr("Voice")
        case .permissions: return AppL10n.tr("Permissions")
        case .laboratory: return AppL10n.tr("Advanced")
        case .productUpdates: return AppL10n.tr("Updates")
        }
    }

    var systemImage: String {
        switch self {
        case .general: return "gearshape"
        case .shortcuts: return "keyboard"
        case .voice: return "mic"
        case .permissions: return "lock.shield"
        case .laboratory: return "slider.horizontal.3"
        case .productUpdates: return "arrow.down.circle"
        }
    }
}

private enum LaboratoryLLMFeature: Hashable, Identifiable {
    case promptRecommendations
    case inputAssistant

    var id: Self { self }
    var displayName: String {
        switch self {
        case .promptRecommendations: return AppL10n.tr("Prompt 智能推荐")
        case .inputAssistant: return AppL10n.tr("输入助理")
        }
    }
}

struct SettingsTab: View {
    @EnvironmentObject var manager: VoiceInputManager
    @EnvironmentObject var appUpdateManager: AppUpdateManager
    @EnvironmentObject var modelManager: ASRModelManager
    @EnvironmentObject var englishModelManager: EnglishASRModelManager
    @EnvironmentObject var historyManager: RecognitionHistoryManager
    @EnvironmentObject var hotkeyManager: GlobalHotkeyManager
    @EnvironmentObject var toastCenter: FallbackToastCenter
    @EnvironmentObject var languageSettings: AppLanguageSettings

    @AppStorage("analyticsEnabled") private var analyticsEnabled: Bool = false
    @AppStorage("claudeIntegrationEnabled") private var claudeIntegrationEnabled: Bool = true
    @AppStorage("overlayFontScale") private var overlayFontScale: Double = 1.0
    @AppStorage(RecognitionBoostSettings.enabledKey) private var recognitionBoostEnabled: Bool = true
    @AppStorage("deepseekPostprocessEnabled") private var deepseekPostprocessEnabled: Bool = false
    @AppStorage("deepseekBaseURL") private var deepseekBaseURL: String = "https://api.deepseek.com"
    @AppStorage("deepseekModel") private var deepseekModel: String = "deepseek-v4-flash"
    @AppStorage("deepseekTimeoutSeconds") private var deepseekTimeoutSeconds: Double = 6
    @AppStorage(FirstRunSetupState.hasCompletedKey) private var hasCompletedFirstRunSetup: Bool = false
    @AppStorage(FirstRunSetupState.hasSkippedKey) private var hasSkippedFirstRunSetup: Bool = false
    @AppStorage(LaboratoryFeatureSettings.promptRecommendationsKey) private var promptRecommendationsEnabled = false
    @AppStorage(LaboratoryFeatureSettings.inputAssistantKey) private var inputAssistantEnabled = false
    @AppStorage(WorkBuddyApprovalFeature.enabledKey) private var workBuddyApprovalEnabled = false

    @State private var notificationStatusGranted: Bool = false
    @State private var permissionRefreshTick: Int = 0
    @State private var isOfflineModelDeleteHovering = false
    @State private var isEnglishModelDeleteHovering = false
    @State private var isStreamingModelDeleteHovering = false
    @State private var isCheckingDoubaoConfig = false
    @State private var isHistoryLimitInfoPresented = false
    @State private var hasRecognitionBoostData = RecognitionBoostStore.shared.hasDataFile()
    @State private var recognitionBoostCounts = RecognitionBoostStore.shared.counts()
    @State private var isTestingDeepSeekConnection = false
    @State private var deepseekConnectionStatusText = ""
    @State private var deepseekAPIKey = ""
    @State private var fastLLMConfigurationLoaded = false
    @State private var missingFastLLMFeature: LaboratoryLLMFeature?
    @State private var shouldScrollToFastLLMConfiguration = false
    @State private var workBuddyApprovalStatus = ""

    @State private var launchAtLoginEnabled: Bool = {
        if #available(macOS 13.0, *) {
            return SMAppService.mainApp.status == .enabled
        }
        return false
    }()

    @Binding var selection: SettingsCategory?

    var body: some View {
        HStack(spacing: 0) {
            List(SettingsCategory.allCases, selection: $selection) { category in
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(category.displayName)
                        Text(category.subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: category.systemImage)
                }
                .tag(category)
            }
            .listStyle(.sidebar)
            .frame(width: 180)

            Divider()

            Group {
                switch selection ?? .general {
                case .general:
                    ScrollViewReader { proxy in
                        ScrollView {
                            VStack(alignment: .leading, spacing: 16) {
                                generalSection
                                restartFirstRunSetupSection
                                fastLLMConfigurationSection
                                    .id("fast-llm-configuration")
                                floatingWindowSection
                                historySection
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 14)
                            .frame(maxWidth: 500, alignment: .leading)
                        }
                        .onAppear { scrollToFastLLMConfigurationIfNeeded(proxy) }
                        .onChange(of: shouldScrollToFastLLMConfiguration) { _, requested in
                            if requested { scrollToFastLLMConfigurationIfNeeded(proxy) }
                        }
                    }
                case .shortcuts:
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            shortcutsSection
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 14)
                        .frame(maxWidth: 500, alignment: .leading)
                    }
                case .voice:
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            voiceSection
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 14)
                        .frame(maxWidth: 500, alignment: .leading)
                    }
                case .permissions:
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            permissionsSection
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 14)
                        .frame(maxWidth: 500, alignment: .leading)
                    }
                case .laboratory:
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            laboratoryPromptSection
                            laboratoryInputAssistantSection
                            workBuddyApprovalSection
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 14)
                        .frame(maxWidth: 500, alignment: .leading)
                    }
                case .productUpdates:
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            productUpdateSection
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 14)
                        .frame(maxWidth: 500, alignment: .leading)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear {
            refreshPermissionStatus()
            loadFastLLMConfiguration()
        }
        .alert(item: $missingFastLLMFeature) { feature in
            Alert(
                title: Text(AppL10n.tr("需要配置快速 LLM")),
                message: Text(AppL10n.format("开启“%@”前，请先完成快速 LLM 配置。", feature.displayName)),
                primaryButton: .default(Text(AppL10n.tr("前往配置"))) {
                    selection = .general
                    shouldScrollToFastLLMConfiguration = true
                },
                secondaryButton: .cancel(Text(AppL10n.tr("取消")))
            )
        }
    }

    private var laboratoryPromptSection: some View {
        settingsSection(icon: "text.badge.plus", title: AppL10n.tr("Prompt 智能推荐")) {
            VStack(alignment: .leading, spacing: 10) {
                Toggle(isOn: laboratoryPromptRecommendationsBinding) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(AppL10n.tr("启用 Prompt 智能推荐"))
                            .font(.subheadline)
                        Text(AppL10n.tr("开启后，双击 B 显示最多 8 条动态 Prompt；关闭时双击 B 执行两次退格。"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)

                if promptRecommendationsEnabled {
                    Divider()
                    PromptTemplateSettingsSection()
                }
            }
        }
    }

    private var laboratoryInputAssistantSection: some View {
        settingsSection(icon: "wand.and.stars", title: AppL10n.tr("输入助理")) {
            VStack(alignment: .leading, spacing: 10) {
                Toggle(isOn: laboratoryInputAssistantBinding) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(AppL10n.tr("启用输入助理"))
                            .font(.subheadline)
                        Text(AppL10n.tr("开启后，双击 C 可读取并改写当前输入框；关闭时双击 C 执行两次 ESC。"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)

                Divider()
                InputAssistantSkillSettingsSection()
            }
        }
    }

    private var workBuddyApprovalSection: some View {
        settingsSection(icon: "checkmark.shield", title: AppL10n.tr("WorkBuddy 设备审批")) {
            VStack(alignment: .leading, spacing: 10) {
                Toggle(isOn: Binding(
                    get: { workBuddyApprovalEnabled },
                    set: updateWorkBuddyApproval
                )) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(AppL10n.tr("启用 WorkBuddy 设备审批"))
                            .font(.subheadline)
                        Text(AppL10n.tr("WorkBuddy 使用终端工具时，可在已连接设备上允许或拒绝；设备不可用时回到 WorkBuddy 原生流程。"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)
                if !workBuddyApprovalStatus.isEmpty {
                    Text(workBuddyApprovalStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func updateWorkBuddyApproval(_ enabled: Bool) {
        do {
            try WorkBuddyHookInstaller.reconcile(enabled: enabled)
            workBuddyApprovalEnabled = enabled
            workBuddyApprovalStatus = enabled
                ? AppL10n.tr("已安装。完全重启 WorkBuddy 后生效。")
                : AppL10n.tr("已关闭。完全重启 WorkBuddy 后停止设备审批。")
        } catch {
            workBuddyApprovalEnabled = false
            workBuddyApprovalStatus = AppL10n.format(
                "配置失败：%@", error.localizedDescription
            )
        }
    }

    private func syncLaboratoryFeatures() {
        QuickVibeHostApp.pushV5Config(ble: manager.bleManager)
    }

    private var laboratoryPromptRecommendationsBinding: Binding<Bool> {
        laboratoryFeatureBinding(value: promptRecommendationsEnabled, feature: .promptRecommendations) {
            promptRecommendationsEnabled = $0
        }
    }

    private var laboratoryInputAssistantBinding: Binding<Bool> {
        laboratoryFeatureBinding(value: inputAssistantEnabled, feature: .inputAssistant) {
            inputAssistantEnabled = $0
        }
    }

    private func laboratoryFeatureBinding(value: Bool, feature: LaboratoryLLMFeature,
                                          set: @escaping (Bool) -> Void) -> Binding<Bool> {
        Binding(get: { value }, set: { enabled in
            guard !enabled || FastLLMConfiguration.load().isConfigured else {
                missingFastLLMFeature = feature
                return
            }
            set(enabled)
            syncLaboratoryFeatures()
        })
    }

    private func scrollToFastLLMConfigurationIfNeeded(_ proxy: ScrollViewProxy) {
        guard shouldScrollToFastLLMConfiguration else { return }
        shouldScrollToFastLLMConfiguration = false
        DispatchQueue.main.async {
            withAnimation { proxy.scrollTo("fast-llm-configuration", anchor: .top) }
        }
    }

    private func settingsSection<Content: View>(
        icon: String,
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 18)
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
            }
            content()
                .settingsPanel()
        }
    }

    private var generalSection: some View {
        settingsSection(icon: "gearshape", title: AppL10n.tr("通用")) {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text(AppL10n.tr("开机自启"))
                        .font(.subheadline)
                    Spacer()
                    Toggle("", isOn: $launchAtLoginEnabled)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .onChange(of: launchAtLoginEnabled) { _, newValue in
                            Task { @MainActor in
                                if #available(macOS 13.0, *) {
                                    do {
                                        try newValue
                                            ? SMAppService.mainApp.register()
                                            : SMAppService.mainApp.unregister()
                                    } catch {
                                        print("[SettingsTab] launchAtLogin toggle failed: \(error)")
                                    }
                                }
                            }
                        }
                }
                .frame(minHeight: 30)

                Divider()
                    .padding(.vertical, 8)

                HStack(alignment: .top, spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(AppL10n.tr("界面语言"))
                            .font(.subheadline)
                        Text(AppL10n.tr("未选择时跟随 macOS。"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Spacer()
                    Picker("", selection: $languageSettings.selectedLanguage) {
                        ForEach(AppLanguage.allCases) { language in
                            Text(language.displayName).tag(language)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 170, alignment: .trailing)
                }

                Divider()
                    .padding(.vertical, 8)

                HStack(alignment: .top, spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(AppL10n.tr("发送匿名使用统计"))
                            .font(.subheadline)
                        Text(AppL10n.tr("发送匿名使用数据，帮助改进产品；不上传个人内容。"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle("", isOn: $analyticsEnabled)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .onChange(of: analyticsEnabled) { _, newValue in
                            AnalyticsClient.shared.setEnabled(newValue)
                        }
                }

                Divider()
                    .padding(.vertical, 8)

                HStack(alignment: .top, spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(AppL10n.tr("AI 助手用量统计"))
                            .font(.subheadline)
                        Text(AppL10n.tr("在状态页显示 Claude Code、Codex 会话与用量；关闭后停止记录。"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle("", isOn: $claudeIntegrationEnabled)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .onChange(of: claudeIntegrationEnabled) { _, newValue in
                            if newValue {
                                HookInstaller.installIfNeeded()
                                StatusLineInstaller.installIfNeeded()
                            } else {
                                HookInstaller.uninstall()
                                StatusLineInstaller.uninstall()
                            }
                        }
                }
            }
        }
    }

    private var restartFirstRunSetupSection: some View {
        settingsSection(icon: "sparkles.rectangle.stack", title: AppL10n.tr("首次设置")) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .center, spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(AppL10n.tr("重新打开首次设置"))
                            .font(.subheadline)
                        Text(AppL10n.tr("下次打开 VE 语音指挥棒时显示设备、权限、ASR 三步向导。"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(AppL10n.tr("重新打开")) {
                        hasSkippedFirstRunSetup = false
                        hasCompletedFirstRunSetup = false
                        toastCenter.show(message: AppL10n.tr("已设置。下次打开时会显示首次设置向导。"))
                    }
                    .controlSize(.small)
                }
            }
        }
    }

    private var fastLLMConfigurationSection: some View {
        settingsSection(icon: "bolt.horizontal.circle", title: AppL10n.tr("快速 LLM 配置")) {
            VStack(alignment: .leading, spacing: 10) {
                Text(AppL10n.tr("供 Prompt 智能推荐、输入助理和识别校对共用。使用相关高级功能前需要先完成配置。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                SecureField("API Key", text: $deepseekAPIKey)
                    .textFieldStyle(.roundedBorder)
                TextField("Base URL", text: $deepseekBaseURL)
                    .textFieldStyle(.roundedBorder)
                TextField("Model", text: $deepseekModel)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Text(AppL10n.tr("超时"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Slider(value: $deepseekTimeoutSeconds, in: 2...15, step: 1)
                    Text("\(Int(deepseekTimeoutSeconds))s")
                        .font(.caption.monospacedDigit())
                        .frame(width: 28, alignment: .trailing)
                }
                HStack(spacing: 10) {
                    Button(AppL10n.tr("保存")) { saveFastLLMConfiguration() }
                    Button(isTestingDeepSeekConnection ? AppL10n.tr("测试中...") : AppL10n.tr("测试连接")) {
                        testDeepSeekConnection()
                    }
                    .disabled(isTestingDeepSeekConnection || deepseekAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if !deepseekConnectionStatusText.isEmpty {
                        Text(deepseekConnectionStatusText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var floatingWindowSection: some View {
        settingsSection(icon: "macwindow", title: AppL10n.tr("悬浮窗")) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .center, spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(AppL10n.tr("输入方式"))
                            .font(.subheadline)
                        Text(AppL10n.tr("识别完成后的处理方式"))
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    Spacer()
                    overlayModeControl
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                HStack(alignment: .center, spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(AppL10n.tr("悬浮窗字号"))
                            .font(.subheadline)
                        Text(AppL10n.tr("影响胶囊和编辑框"))
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    Spacer()
                    overlayFontControl
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var overlayModeControl: some View {
        settingsSegmentedControl(
            [("capsule", AppL10n.tr("自动输入")), ("editor", AppL10n.tr("先行编辑"))],
            selection: $manager.overlayModeRaw
        )
    }

    private var overlayFontControl: some View {
        settingsSegmentedControl(
            [(1.0, AppL10n.tr("默认")), (2.0, AppL10n.tr("大")), (3.0, AppL10n.tr("超大"))],
            selection: $overlayFontScale
        )
    }

    private func settingsSegmentedControl<Value: Hashable>(
        _ options: [(Value, String)],
        selection: Binding<Value>,
        width: CGFloat = 228
    ) -> some View {
        HStack(spacing: 0) {
            ForEach(options, id: \.0) { value, label in
                ZStack {
                    Rectangle().fill(Color.clear)
                    Text(label)
                        .fontWeight(.medium)
                }
                .frame(maxWidth: .infinity)
                .frame(minHeight: 24)
                .contentShape(Rectangle())
                .onTapGesture {
                    selection.wrappedValue = value
                }
                .foregroundStyle(selection.wrappedValue == value ? Color.white : Color.primary)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(selection.wrappedValue == value ? Color.accentColor : Color.clear)
                )
                .accessibilityAddTraits(selection.wrappedValue == value ? .isSelected : [])
            }
        }
        .padding(2)
        .frame(width: width)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.primary.opacity(0.08))
        )
    }

    private func settingsSwitchRow(
        title: String,
        detail: String,
        isOn: Binding<Bool>
    ) -> some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Toggle("", isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var productUpdateSection: some View {
        VStack(spacing: 18) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .scaledToFit()
                .frame(width: 96, height: 96)
                .accessibilityHidden(true)

            VStack(spacing: 6) {
                Text(AppBrand.displayName)
                    .font(.system(size: 26, weight: .semibold))
                    .multilineTextAlignment(.center)

                Text(AppL10n.format("版本 %@", Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "-"))
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            VStack(alignment: .leading, spacing: 10) {
                appUpdateControls

                HStack {
                    HStack(spacing: 6) {
                        Image(systemName: "globe")
                            .foregroundStyle(.secondary)
                        Link("vibeeverything.cc", destination: URL(string: "https://vibeeverything.cc")!)
                    }
                    Spacer()
                }
            }
            .settingsPanel()
        }
        .frame(maxWidth: .infinity, alignment: .top)
    }

    @ViewBuilder
    private var appUpdateControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: "arrow.down.circle")
                    .foregroundStyle(.secondary)
                switch appUpdateManager.state {
                case .idle:
                    Text(AppL10n.tr("可检查新版本"))
                case .checking:
                    Text(AppL10n.tr("正在检查更新…"))
                    ProgressView()
                        .controlSize(.small)
                case .upToDate:
                    Text(AppL10n.tr("已是最新版本"))
                case .available(let version):
                    Text(AppL10n.format("发现新版本 %@", version.description))
                    Spacer()
                    Button(AppL10n.tr("下载更新")) {
                        appUpdateManager.downloadUpdate()
                    }
                case .downloading(let progress):
                    Text(AppL10n.tr("正在下载更新…"))
                    ProgressView(value: progress)
                        .frame(width: 120)
                    Text("\(Int(progress * 100))%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                case .verifying:
                    Text(AppL10n.tr("正在校验更新…"))
                    ProgressView()
                        .controlSize(.small)
                case .ready:
                    Text(AppL10n.tr("更新包已下载，安装包已打开"))
                    Spacer()
                    Button(AppL10n.tr("重新打开安装包")) {
                        _ = appUpdateManager.openReadyUpdate()
                    }
                case .failed(let message):
                    Text(message)
                        .foregroundStyle(.orange)
                    Spacer()
                    Button(AppL10n.tr("检查更新")) {
                        appUpdateManager.checkForUpdates(force: true)
                    }
                }

                if case .idle = appUpdateManager.state {
                    Spacer()
                    Button(AppL10n.tr("检查更新")) {
                        appUpdateManager.checkForUpdates(force: true)
                    }
                } else if case .upToDate = appUpdateManager.state {
                    Spacer()
                    Button(AppL10n.tr("再次检查")) {
                        appUpdateManager.checkForUpdates(force: true)
                    }
                }
            }

            Text(AppL10n.tr("下载完成后会打开 DMG。请先退出当前 App，再将新 App 拖入 Applications，最后重新打开本 App。"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var shortcutsSection: some View {
        settingsSection(icon: "keyboard", title: AppL10n.tr("快捷键")) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(AppL10n.tr("启用全局快捷键"))
                            .font(.subheadline)
                        Text(AppL10n.tr("关闭后不会响应系统全局快捷键。"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle("", isOn: $hotkeyManager.hotkeyEnabled)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                }

                HStack {
                    Text(AppL10n.tr("录音快捷键"))
                        .font(.subheadline)
                    Spacer()
                    Text(hotkeyManager.hotkeyDisplayName)
                        .font(.subheadline.weight(.medium))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(RoundedRectangle(cornerRadius: 5).fill(Color(.quaternaryLabelColor)))
                }

                if !hotkeyManager.isActive {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(AppL10n.tr("需要辅助功能权限，快捷键无法工作"))
                                .font(.caption)
                                .foregroundStyle(.orange)
                            Text(AppL10n.tr("系统设置 → 隐私与安全性 → 辅助功能 → 勾选 VE 语音指挥棒。授予后本 App 会自动生效，无需重启。"))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.orange.opacity(0.1)))
                }

                if AVCaptureDevice.default(for: .audio) == nil {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text(AppL10n.tr("未检测到麦克风，语音输入功能无法使用"))
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.orange.opacity(0.1)))
                }
            }
        }
    }

    // MARK: - Voice Settings

    private var voiceSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            voiceInputSection
            recognitionProcessingSection
            switch manager.asrEngine {
            case .doubao:
                doubaoEngineSection
            case .local:
                localEngineSection
            case .localEnglish:
                englishEngineSection
            }
        }
    }

    private var voiceInputSection: some View {
        settingsSection(icon: "mic", title: AppL10n.tr("语音输入")) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .center, spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(AppL10n.tr("ASR 引擎"))
                            .font(.subheadline)
                            .lineLimit(1)
                        Text(AppL10n.tr("本地或云端识别"))
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    Spacer()
                    asrEngineControl
                }
                .frame(maxWidth: .infinity, alignment: .leading)

            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var asrEngineControl: some View {
        settingsSegmentedControl(
            ASREngine.allCases.map { ($0, $0.displayName) },
            selection: Binding(
                get: { manager.asrEngine },
                set: { newValue in
                    // 延迟到下个 runloop:避免在视图更新周期内同步改 @AppStorage/@Published
                    // 触发 "Publishing changes from within view updates" fault。
                    DispatchQueue.main.async { manager.asrEngine = newValue }
                }
            )
        )
    }

    private var recognitionProcessingSection: some View {
        settingsSection(icon: "text.bubble", title: AppL10n.tr("识别结果处理")) {
            VStack(alignment: .leading, spacing: 12) {
                settingsSwitchRow(
                    title: AppL10n.tr("自动添加标点"),
                    detail: AppL10n.tr("控制识别结果是否自动补全标点。"),
                    isOn: $manager.enablePunctuation
                )

                settingsSwitchRow(
                    title: AppL10n.tr("定稿数字规范化"),
                    detail: AppL10n.tr("App 在最终文本阶段将“二零二六”等口语数字转为书面格式。"),
                    isOn: $manager.itnPostProcessEnabled
                )
                .help(AppL10n.tr("对识别定稿做逆文本规范化:读数串/日期/百分比/分数等转书面形态。本地 Paraformer 原生不支持 ITN,由 App 内置规则完成;豆包结果幂等不受影响。"))

                recognitionBoostRow

                deepseekPostprocessRow

                Divider()
                    .padding(.vertical, 2)

                customHotwordsField

                // REQ-015: 语音棒提示词管理已移至 设备 TAB(NewDeviceTab)
            }
        }
    }

    private var recognitionBoostRow: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(AppL10n.tr("识别增强"))
                    .font(.subheadline)
                Text(recognitionBoostDescriptionText)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            HStack(spacing: 10) {
                if hasRecognitionBoostData {
                    Button {
                        confirmClearRecognitionBoost()
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 12, weight: .semibold))
                            .frame(width: 22, height: 22)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.secondary)
                    .help(AppL10n.tr("清空学习数据"))
                    .accessibilityLabel(AppL10n.tr("清空识别增强学习数据"))
                }

                Toggle("", isOn: $recognitionBoostEnabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear {
            refreshRecognitionBoostSummary()
        }
        .onReceive(NotificationCenter.default.publisher(for: .dataFileDidChange)) { _ in
            refreshRecognitionBoostSummary()
        }
    }

    private var deepseekPostprocessRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            settingsSwitchRow(
                title: AppL10n.tr("识别校对"),
                detail: AppL10n.tr("使用快速 LLM 对识别后的文本修正错词和标点，失败保留原文。"),
                isOn: $deepseekPostprocessEnabled
            )

            if deepseekPostprocessEnabled && !currentFastLLMConfiguration.isConfigured {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(AppL10n.tr("需要先配置快速 LLM，配置完成后识别校对会自动生效。"))
                        .font(.caption).foregroundStyle(.orange)
                    Spacer()
                    Button(AppL10n.tr("前往配置")) { selection = .general }
                        .controlSize(.small)
                }
            }
        }
    }

    private var currentFastLLMConfiguration: FastLLMConfiguration {
        .init(apiKey: deepseekAPIKey, baseURL: deepseekBaseURL,
              model: deepseekModel, timeoutSeconds: deepseekTimeoutSeconds)
    }

    private func loadFastLLMConfiguration() {
        guard !fastLLMConfigurationLoaded else { return }
        let configuration = FastLLMConfiguration.load()
        deepseekAPIKey = configuration.apiKey
        deepseekBaseURL = configuration.baseURL
        deepseekModel = configuration.model
        deepseekTimeoutSeconds = configuration.timeoutSeconds
        fastLLMConfigurationLoaded = true
    }

    private func saveFastLLMConfiguration(showStatus: Bool = true) {
        let configuration = currentFastLLMConfiguration
        configuration.save()
        deepseekPostprocessEnabled = configuration.isConfigured
        if showStatus { deepseekConnectionStatusText = AppL10n.tr("已保存") }
    }

    private func testDeepSeekConnection() {
        let apiKey = deepseekAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty else {
            deepseekConnectionStatusText = AppL10n.tr("未配置 API Key")
            return
        }
        isTestingDeepSeekConnection = true
        deepseekConnectionStatusText = AppL10n.tr("检测中...")
        saveFastLLMConfiguration(showStatus: false)
        Task {
            do {
                let result = try await DeepSeekPostProcessor(
                    apiKey: apiKey,
                    baseURL: deepseekBaseURL,
                    model: deepseekModel,
                    timeoutSeconds: min(max(deepseekTimeoutSeconds, 2), 15)
                ).polish(AppL10n.tr("测试 QuickVibeHost DeepSeek 忠实校对连接。"))
                await MainActor.run {
                    deepseekConnectionStatusText = AppL10n.format("连接成功 %@ms", String(result.elapsedMs))
                    isTestingDeepSeekConnection = false
                }
            } catch {
                await MainActor.run {
                    deepseekConnectionStatusText = AppL10n.format("连接失败: %@", error.localizedDescription)
                    isTestingDeepSeekConnection = false
                }
            }
        }
    }

    private func refreshRecognitionBoostSummary() {
        hasRecognitionBoostData = RecognitionBoostStore.shared.hasDataFile()
        recognitionBoostCounts = RecognitionBoostStore.shared.counts()
    }

    private var shouldShowRecognitionBoostCounts: Bool {
        recognitionBoostEnabled && recognitionBoostCounts.active > 0
    }

    private var recognitionBoostDescriptionText: String {
        let base = AppL10n.tr("从你发送前的修改中学习常用专名和术语。")
        guard shouldShowRecognitionBoostCounts else { return base }
        return base + AppL10n.format("已学到 %@ 个热词", String(recognitionBoostCounts.active))
    }

    private func confirmClearRecognitionBoost() {
        let alert = NSAlert()
        alert.messageText = AppL10n.tr("清空识别增强数据？")
        alert.informativeText = AppL10n.tr("会删除本机学习到的专名和修改记录，不会删除识别历史。")
        alert.addButton(withTitle: AppL10n.tr("清空"))
        alert.addButton(withTitle: AppL10n.tr("取消"))
        alert.alertStyle = .warning
        if alert.runModal() == .alertFirstButtonReturn {
            RecognitionBoostStore.shared.clear()
        }
    }

    private var doubaoEngineSection: some View {
        settingsSection(icon: "cloud", title: AppL10n.tr("豆包云端")) {
            VStack(alignment: .leading, spacing: 12) {
                doubaoSubsection
            }
        }
    }

    private var localEngineSection: some View {
        settingsSection(icon: "cpu", title: AppL10n.tr("本地 Paraformer")) {
            VStack(alignment: .leading, spacing: 12) {
                if case .notDownloaded = modelManager.state {
                    FirstRunASRGuide()
                }
                localEngineSubsection
            }
        }
    }

    private var englishEngineSection: some View {
        settingsSection(icon: "waveform.and.mic", title: AppL10n.tr("本地英文 · Zipformer")) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    Circle().fill(englishEngineStateColor).frame(width: 8, height: 8)
                    Text(englishEngineStateText).font(.caption)
                    Spacer()
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(AppL10n.format(
                        "版本: %@",
                        englishModelManager.manifest?.version ?? EnglishASRModelManager.expectedVersion
                    ))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    Text(AppL10n.format(
                        "大小: %@",
                        englishModelManager.totalSize > 0
                            ? byteCount(englishModelManager.totalSize)
                            : AppL10n.tr("下载后获取")
                    ))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    if let directory = englishModelManager.installedDirectory() {
                        Text(AppL10n.format("路径: %@", directory.path))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Text(AppL10n.tr("用途: 英文实时识别、项目热词及英文标点恢复"))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Text(AppL10n.tr("音频仅在本机处理，不会发送到云端。"))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }

                if case .downloading(let progress) = englishModelManager.state {
                    ProgressView(value: progress).progressViewStyle(.linear)
                }
                if case .failed(let reason) = englishModelManager.state {
                    Text(reason).font(.caption).foregroundStyle(.red)
                }

                HStack(spacing: 8) {
                    switch englishModelManager.state {
                    case .ready:
                        Button(AppL10n.tr("重新下载")) {
                            Task {
                                await manager.sherpaEnglishEngine.unload()
                                await englishModelManager.deleteModels()
                                await englishModelManager.downloadModels()
                            }
                        }
                        .controlSize(.small)
                        Button(AppL10n.tr("删除模型")) {
                            Task {
                                await manager.sherpaEnglishEngine.unload()
                                await englishModelManager.deleteModels()
                            }
                        }
                        .controlSize(.small)
                        .foregroundStyle(isEnglishModelDeleteHovering ? Color.red : Color.secondary)
                        .onHover { isEnglishModelDeleteHovering = $0 }
                    case .downloading, .verifying:
                        EmptyView()
                    default:
                        Button(AppL10n.tr("下载模型")) {
                            Task { await englishModelManager.downloadModels() }
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                }
            }
        }
    }

    private var englishEngineStateColor: Color {
        switch englishModelManager.state {
        case .ready: .green
        case .downloading, .verifying: .orange
        case .failed: .red
        case .notDownloaded: .secondary
        }
    }

    private var englishEngineStateText: String {
        switch englishModelManager.state {
        case .notDownloaded: AppL10n.tr("英文模型未下载")
        case .downloading(let progress): AppL10n.format("英文模型下载中 %@%", String(Int(progress * 100)))
        case .verifying: AppL10n.tr("校验中…")
        case .ready: AppL10n.tr("英文流式模型已就绪")
        case .failed: AppL10n.tr("英文模型下载失败")
        }
    }

    private var customHotwordsField: some View {
        let customHotwordCount = ASRHotwordInputParser.parse(manager.customHotwords, limit: 20).count
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(AppL10n.tr("自定义热词"))
                    .font(.subheadline)
                Spacer()
                Text("\(customHotwordCount)/20")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(nsColor: .controlBackgroundColor))
                TextEditor(text: $manager.customHotwords)
                    .font(.body.monospaced())
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .scrollContentBackground(.hidden)
            }
                .frame(minHeight: 104)
                .scrollContentBackground(.hidden)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.secondary.opacity(0.22), lineWidth: 1)
                )
            Text(AppL10n.tr("每行一个热词，短语可包含空格。逗号会按换行处理。"))
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    private var doubaoSubsection: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text("App Key")
                    .font(.subheadline)
                TextField(AppL10n.tr("输入 App Key"), text: $manager.appKey)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Access Key")
                    .font(.subheadline)
                SecureField(AppL10n.tr("输入 Access Key"), text: $manager.accessKey)
                    .textFieldStyle(.roundedBorder)
            }

            doubaoConfigCheckRow
            doubaoPrivacyNote

            Divider()
                .padding(.vertical, 2)

            settingsSwitchRow(
                title: AppL10n.tr("语义顺滑"),
                detail: AppL10n.tr("去口水词和重复；命令、代码口述场景可能吞真实词句。"),
                isOn: $manager.doubaoEnableDDC
            )
            .help(AppL10n.tr("开启会删除口水词/重复,但实测可能吞掉真实内容(如命令口述)。命令/代码场景建议关。"))

            settingsSwitchRow(
                title: AppL10n.tr("豆包原生数字规范化"),
                detail: AppL10n.tr("由豆包云端在识别阶段将“十秒”等口语数字转为书面格式。"),
                isOn: $manager.doubaoEnableITN
            )
        }
    }

    private var doubaoPrivacyNote: some View {
        Text(AppL10n.tr("密钥和识别历史仅保存在本机；本应用不上传到自有服务器。使用豆包云端识别时，音频/文本会发送至豆包云服务处理。"))
            .font(.caption)
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var doubaoConfigCheckRow: some View {
        HStack(alignment: .center, spacing: 12) {
            HStack(spacing: 6) {
                Circle()
                    .fill(doubaoConfigStateColor)
                    .frame(width: 8, height: 8)
                Text(isCheckingDoubaoConfig ? AppL10n.tr("正在检测配置...") : manager.doubaoConfigCheckDisplayText)
                    .font(.caption)
                    .foregroundStyle(doubaoConfigTextColor)
                    .lineLimit(2)
            }
            Spacer()
            Button(manager.doubaoConfigCheckStatus == .unchecked ? AppL10n.tr("检测配置") : AppL10n.tr("重新检测")) {
                isCheckingDoubaoConfig = true
                Task { @MainActor in
                    await manager.validateDoubaoConfiguration()
                    isCheckingDoubaoConfig = false
                }
            }
            .controlSize(.small)
            .disabled(!manager.isDoubaoConfigComplete || isCheckingDoubaoConfig)
        }
        .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
    }

    private var doubaoConfigStateColor: Color {
        if isCheckingDoubaoConfig { return .orange }
        if !manager.isDoubaoConfigComplete { return .secondary.opacity(0.65) }
        if manager.isDoubaoConfigChangedSinceCheck { return .orange }
        switch manager.doubaoConfigCheckStatus {
        case .unchecked: return .secondary.opacity(0.65)
        case .success: return .green
        case .failed: return .red
        }
    }

    private var doubaoConfigTextColor: Color {
        if manager.doubaoConfigCheckStatus == .failed,
           !manager.isDoubaoConfigChangedSinceCheck,
           !isCheckingDoubaoConfig {
            return .red
        }
        return .secondary
    }

    private var localEngineSubsection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Circle()
                    .fill(localEngineStateColor)
                    .frame(width: 8, height: 8)
                Text(localEngineStateText)
                    .font(.caption)
                Spacer()
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(AppL10n.format("版本: %@", modelManager.manifest?.version ?? ASRModelManager.expectedModelVersion))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Text(AppL10n.format("大小: %@", modelManager.totalSize > 0 ? byteCount(modelManager.totalSize) : AppL10n.tr("下载后获取")))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                if let dir = modelManager.currentVersionDir() {
                    Text(AppL10n.format("路径: %@", dir.path))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else {
                    Text(AppL10n.tr("路径: 下载后显示"))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Text(AppL10n.tr("用途: 整段离线识别，作为本地 Paraformer 基础模型"))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            if case .downloading(let progress) = modelManager.state {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
            }

            if case .failed(let reason) = modelManager.state {
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack(spacing: 8) {
                if case .ready = modelManager.state {
                    Button(AppL10n.tr("重新下载")) {
                        Task {
                            await modelManager.deleteModels()
                            await modelManager.downloadModels()
                        }
                    }
                    .controlSize(.small)
                    Button(AppL10n.tr("删除模型")) {
                        Task { await modelManager.deleteModels() }
                    }
                    .controlSize(.small)
                    .foregroundStyle(isOfflineModelDeleteHovering ? Color.red : Color.secondary)
                    .onHover { isOfflineModelDeleteHovering = $0 }
                    .help(AppL10n.tr("删除离线模型"))
                } else if case .notDownloaded = modelManager.state {
                    EmptyView()
                } else if case .downloading = modelManager.state {
                    EmptyView()
                } else if case .verifying = modelManager.state {
                    EmptyView()
                } else {
                    Button(AppL10n.tr("下载模型")) {
                        Task { await modelManager.downloadModels() }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
            }

            Divider().padding(.vertical, 2)
            localStreamingSubsection
        }
    }

    /// 本地流式(2-pass)模型集:online+vad+punc(~525MB,ModelScope)。下载后本地引擎按 PTT 走实时流式。
    @ViewBuilder
    private var localStreamingSubsection: some View {
        HStack(spacing: 6) {
            Circle().fill(streamingStateColor).frame(width: 8, height: 8)
            Text(streamingStateText).font(.caption)
            Spacer()
        }
        if case .failed(let reason) = modelManager.streamingState {
            Text(reason).font(.caption).foregroundStyle(.red)
        }
        VStack(alignment: .leading, spacing: 2) {
            Text(AppL10n.format("版本: %@", ASRModelManager.streamingVersion))
                .font(.caption)
                .foregroundStyle(.tertiary)
            Text(AppL10n.format("大小: %@", byteCount(modelManager.streamingTotalSize)))
                .font(.caption)
                .foregroundStyle(.tertiary)
            if let dir = modelManager.streamingDir() {
                Text(AppL10n.format("路径: %@", dir.path))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            } else {
                Text(AppL10n.tr("路径: 下载后显示"))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Text(AppL10n.tr("用途: PTT 实时出字，松手出精确定稿"))
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        if case .downloading(let p) = modelManager.streamingState {
            ProgressView(value: p).progressViewStyle(.linear)
        }
        HStack(spacing: 8) {
            switch modelManager.streamingState {
            case .ready:
                Button(AppL10n.tr("重新下载")) {
                    Task {
                        await modelManager.deleteStreamingModels()
                        await modelManager.downloadStreamingModels()
                    }
                }
                .controlSize(.small)
                Button(AppL10n.tr("删除模型")) { Task { await modelManager.deleteStreamingModels() } }
                    .controlSize(.small)
                    .foregroundStyle(isStreamingModelDeleteHovering ? Color.red : Color.secondary)
                    .onHover { isStreamingModelDeleteHovering = $0 }
                    .help(AppL10n.tr("删除流式模型"))
            case .downloading, .verifying:
                EmptyView()
            default:
                Button(AppL10n.tr("下载模型")) { Task { await modelManager.downloadStreamingModels() } }
                    .buttonStyle(.borderedProminent).controlSize(.small)
            }
        }
    }

    private var streamingStateColor: Color {
        switch modelManager.streamingState {
        case .ready: .green
        case .downloading, .verifying: .orange
        case .failed: .red
        case .notDownloaded: .secondary
        }
    }
    private var streamingStateText: String {
        switch modelManager.streamingState {
        case .notDownloaded: AppL10n.tr("流式模型未下载(本地走整段)")
        case .downloading(let p): AppL10n.format("流式模型下载中 %@%", String(Int(p * 100)))
        case .verifying: AppL10n.tr("校验中…")
        case .ready: AppL10n.tr("流式模型已就绪")
        case .failed: AppL10n.tr("流式模型下载失败")
        }
    }

    private var localEngineStateColor: Color {
        switch modelManager.state {
        case .ready: .green
        case .downloading, .verifying: .orange
        case .failed: .red
        case .notDownloaded: .secondary
        }
    }

    private var localEngineStateText: String {
        switch modelManager.state {
        case .notDownloaded: AppL10n.tr("模型未下载")
        case .downloading(let p): AppL10n.format("离线模型下载中 %@%", String(Int(p * 100)))
        case .verifying: AppL10n.tr("校验中…")
        case .ready: AppL10n.tr("离线模型已就绪")
        case .failed(let reason): AppL10n.format("失败: %@", reason)
        }
    }

    private func byteCount(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    // MARK: - History

    private var historySection: some View {
        settingsSection(icon: "clock.arrow.circlepath", title: AppL10n.tr("历史记录")) {
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 4) {
                        Text(AppL10n.tr("记录上限"))
                            .font(.subheadline)
                        Button {
                            isHistoryLimitInfoPresented.toggle()
                        } label: {
                            Image(systemName: "info.circle")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .frame(width: 16, height: 16)
                        }
                        .buttonStyle(.plain)
                        .help(AppL10n.tr("记录上限说明"))
                        .popover(isPresented: $isHistoryLimitInfoPresented, arrowEdge: .top) {
                            historyLimitInfoPopover
                        }
                    }
                    Text(AppL10n.format("当前记录数: %@", String(historyManager.records.count)))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                maxRecordsControl
            }
        }
    }

    private var maxRecordsControl: some View {
        settingsSegmentedControl(
            [(50, "50"), (100, "100"), (200, "200"), (500, "500")],
            selection: $historyManager.maxRecords
        )
    }

    private var historyLimitInfoPopover: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(AppL10n.tr("记录上限只影响之后新增的历史记录。切换上限不会立即删除已有记录；下次录入新语句后，才会按当前上限保留最新记录。"))
            if historyManager.records.count > historyManager.maxRecords {
                Text(AppL10n.format("当前已有 %@ 条，超过上限 %@ 条。下次录入后会保留最新 %@ 条。", String(historyManager.records.count), String(historyManager.maxRecords), String(historyManager.maxRecords)))
                    .foregroundStyle(.secondary)
            }
        }
        .font(.caption)
        .frame(width: 260, alignment: .leading)
        .padding(12)
    }

    // MARK: - Permissions

    private var permissionsSection: some View {
        let _ = permissionRefreshTick
        return settingsSection(icon: "lock.shield", title: AppL10n.tr("权限")) {
            VStack(alignment: .leading, spacing: 10) {
            permissionRow(
                label: AppL10n.tr("辅助功能"),
                granted: KeyboardSimulator.hasAccessibilityPermission,
                scheme: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
            )

            permissionRow(
                label: AppL10n.tr("快捷键监听"),
                granted: CGPreflightListenEventAccess(),
                scheme: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"
            )

            permissionRow(
                label: AppL10n.tr("麦克风"),
                granted: AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
                scheme: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
            )

            permissionRow(
                label: AppL10n.tr("通知"),
                granted: notificationStatusGranted,
                scheme: "x-apple.systempreferences:com.apple.preference.notifications"
            )

            permissionRow(
                label: AppL10n.tr("蓝牙"),
                granted: CBManager.authorization == .allowedAlways,
                scheme: "x-apple.systempreferences:com.apple.preference.security?Privacy_Bluetooth"
            )
            }
        }
        .onAppear {
            refreshPermissionStatus()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshPermissionStatus()
        }
    }

    private func permissionRow(label: String, granted: Bool?, scheme: String) -> some View {
        HStack(spacing: 12) {
            Circle()
                .fill(permissionStatusColor(granted))
                .frame(width: 8, height: 8)
            Text(label)
                .font(.subheadline)
            Spacer()
            Text(permissionStatusText(granted))
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 58, alignment: .trailing)
            Button(AppL10n.tr("在系统设置打开")) {
                if let url = URL(string: scheme) {
                    NSWorkspace.shared.open(url)
                }
            }
            .controlSize(.small)
        }
        .frame(minHeight: 34)
    }

    private func permissionStatusColor(_ granted: Bool?) -> Color {
        guard let granted = granted else { return .secondary }
        return granted ? .green : .red
    }

    private func permissionStatusText(_ granted: Bool?) -> String {
        guard let granted = granted else { return AppL10n.tr("系统管理") }
        return granted ? AppL10n.tr("已授权") : AppL10n.tr("未授权")
    }

    private func refreshPermissionStatus() {
        permissionRefreshTick &+= 1
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            DispatchQueue.main.async {
                notificationStatusGranted = settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
            }
        }
    }
}

private extension View {
    func settingsPanel() -> some View {
        self
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.primary.opacity(0.045))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.primary.opacity(0.09), lineWidth: 1)
            )
    }
}

// MARK: - MicPad 自定义提示词(REQ-011)

/// VE 语音棒自定义提示词管理:最多 8 条(标题 ≤8 字,正文 ≤1024 字)。
/// 存 UserDefaults "micpadPrompts" = [[title:, body:]];变更即重推 v5 config。
/// 设备端列表第 0 条为内置「AI推荐(→+回车)」,此处只管自定义条目。
struct MicPadPromptSettingsSection: View {
    @EnvironmentObject var bleManager: BLEManager
    var onCountChange: (Int) -> Void = { _ in }
    @State private var prompts: [[String: String]] =
        (UserDefaults.standard.array(forKey: "micpadPrompts") as? [[String: String]]) ?? []
    @State private var editorShown = false
    @State private var editingIndex: Int? = nil   // nil = 新增
    @State private var draftTitle = ""
    @State private var draftBody = ""
    @State private var draftTouched = false
    @State private var copiedPromptIndices: Set<Int> = []
    @State private var copyFailedPromptIndices: Set<Int> = []
    @State private var copyHoverPromptIndex: Int? = nil
    @State private var hoveredPromptDeleteIndex: Int? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(AppL10n.tr("双击设备 B 键打开列表，旋钮选择，点按发送到光标处。"))
                Text(AppL10n.tr("第 1 条为「AI 推荐」；标题最多 8 字，正文最多 1024 字。"))
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.bottom, 2)

            if prompts.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "text.badge.plus")
                    Text(AppL10n.tr("还没有自定义提示词"))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
            } else {
                ForEach(prompts.indices, id: \.self) { i in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Text(prompts[i]["title"] ?? "")
                                .fontWeight(.medium)
                                .lineLimit(1)
                            Spacer()
                            Button {
                                copyPromptBody(at: i)
                            } label: {
                                Image(systemName: copyPromptIcon(for: i))
                                    .font(.system(size: 14, weight: .medium))
                                    .frame(width: 22, height: 22)
                            }
                            .buttonStyle(.borderless)
                            .foregroundStyle(copyPromptColor(for: i))
                            .onHover { hovering in
                                copyHoverPromptIndex = hovering ? i : nil
                            }
                            .help(copyFailedPromptIndices.contains(i) ? AppL10n.tr("复制失败") : AppL10n.tr("复制提示词正文"))
                            .accessibilityLabel(AppL10n.tr("复制提示词正文"))
                            Button {
                                editingIndex = i
                                draftTitle = prompts[i]["title"] ?? ""
                                draftBody = prompts[i]["body"] ?? ""
                                draftTouched = false
                                editorShown = true
                            } label: {
                                Image(systemName: "pencil")
                                    .font(.system(size: 14, weight: .medium))
                                    .frame(width: 22, height: 22)
                            }
                            .buttonStyle(.borderless)
                            .help(AppL10n.tr("编辑"))
                            .accessibilityLabel(AppL10n.tr("编辑提示词"))
                            Button {
                                prompts.remove(at: i)
                                persist()
                            } label: {
                                Image(systemName: "trash")
                                    .font(.system(size: 14, weight: .medium))
                                    .frame(width: 22, height: 22)
                            }
                            .buttonStyle(.borderless)
                            .foregroundStyle(hoveredPromptDeleteIndex == i ? Color.red : Color.secondary)
                            .onHover { hovering in
                                if hovering {
                                    hoveredPromptDeleteIndex = i
                                } else if hoveredPromptDeleteIndex == i {
                                    hoveredPromptDeleteIndex = nil
                                }
                            }
                            .help(AppL10n.tr("删除"))
                            .accessibilityLabel(AppL10n.tr("删除提示词"))
                        }
                        Text(prompts[i]["body"] ?? "")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .padding(8)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.primary.opacity(0.04))
                    )
                }
            }

            if prompts.count < 8 {
                Button {
                    editingIndex = nil
                    draftTitle = ""
                    draftBody = ""
                    draftTouched = false
                    editorShown = true
                } label: {
                    Label(AppL10n.tr("添加提示词"), systemImage: "plus")
                }
                .controlSize(.small)
            }
        }
        .onAppear { onCountChange(prompts.count) }
        .sheet(isPresented: $editorShown) {
            VStack(alignment: .leading, spacing: 12) {
                Text(editingIndex == nil ? AppL10n.tr("添加提示词") : AppL10n.tr("编辑提示词"))
                    .font(.headline)

                HStack {
                    Text(AppL10n.tr("标题"))
                    Spacer()
                    Text("\(draftTitle.count)/8")
                        .foregroundStyle(draftTitle.count > 8 ? Color.red : Color.secondary)
                }
                .font(.caption)
                TextField(AppL10n.tr("显示在设备列表中"), text: $draftTitle)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: draftTitle) { draftTouched = true }

                HStack {
                    Text(AppL10n.tr("正文"))
                    Spacer()
                    Text("\(draftBody.count)/1024")
                        .foregroundStyle(draftBody.count > 1024 ? Color.red : Color.secondary)
                }
                .font(.caption)
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color(nsColor: .textBackgroundColor))
                    MicPadPromptTextEditor(text: $draftBody) {
                        draftTouched = true
                    }
                    if draftBody.isEmpty {
                        Text(AppL10n.tr("发送时会注入到当前光标处"))
                            .font(.body)
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .allowsHitTesting(false)
                    }
                }
                .frame(height: 180)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.3)))

                HStack {
                    if draftShouldShowValidation {
                        Text(draftValidationMessage)
                            .foregroundStyle(Color.red)
                    }
                    Spacer()
                    Button(AppL10n.tr("取消")) { editorShown = false }
                    Button(AppL10n.tr("保存")) {
                        let entry = ["title": draftTitle.trimmingCharacters(in: .whitespacesAndNewlines),
                                     "body": draftBody]
                        if let i = editingIndex { prompts[i] = entry }
                        else { prompts.append(entry) }
                        persist()
                        editorShown = false
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!draftCanSave)
                }
                .font(.caption2)
                .frame(minHeight: 28)
            }
            .padding(20)
            .frame(width: 420)
        }
    }

    private var draftCanSave: Bool {
        !draftTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !draftBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        draftTitle.count <= 8 &&
        draftBody.count <= 1024
    }

    private var draftShouldShowValidation: Bool {
        (draftTouched && !draftCanSave) || draftTitle.count > 8 || draftBody.count > 1024
    }

    private var draftValidationMessage: String {
        if draftTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return AppL10n.tr("填写标题后可保存") }
        if draftBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return AppL10n.tr("填写正文后可保存") }
        if draftTitle.count > 8 { return AppL10n.tr("标题最多 8 字") }
        if draftBody.count > 1024 { return AppL10n.tr("正文最多 1024 字") }
        return AppL10n.tr("发送时不自动回车")
    }

    private func copyPromptBody(at i: Int) {
        copyFailedPromptIndices.remove(i)
        NSPasteboard.general.clearContents()
        if NSPasteboard.general.setString(prompts[i]["body"] ?? "", forType: .string) {
            copiedPromptIndices.insert(i)
            Task {
                try? await Task.sleep(for: .seconds(1))
                copiedPromptIndices.remove(i)
            }
        } else {
            copyFailedPromptIndices.insert(i)
            Task {
                try? await Task.sleep(for: .seconds(1))
                copyFailedPromptIndices.remove(i)
            }
        }
    }

    private func copyPromptIcon(for i: Int) -> String {
        if copiedPromptIndices.contains(i) { return "checkmark" }
        if copyFailedPromptIndices.contains(i) { return "exclamationmark.triangle" }
        return "doc.on.doc"
    }

    private func copyPromptColor(for i: Int) -> Color {
        if copiedPromptIndices.contains(i) { return .green }
        if copyFailedPromptIndices.contains(i) { return .red }
        if copyHoverPromptIndex == i { return .secondary }
        return Color.secondary.opacity(0.55)
    }

    private func persist() {
        UserDefaults.standard.set(prompts, forKey: "micpadPrompts")
        onCountChange(prompts.count)
        QuickVibeHostApp.pushV5Config(ble: bleManager)
    }
}

private struct MicPadPromptTextEditor: NSViewRepresentable {
    @Binding var text: String
    var onChange: () -> Void

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true

        let textView = NSTextView()
        textView.delegate = context.coordinator
        textView.string = text
        textView.font = .systemFont(ofSize: NSFont.systemFontSize)
        textView.textColor = .labelColor
        textView.drawsBackground = false
        textView.isRichText = false
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainerInset = NSSize(width: 10, height: 8)
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true

        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        if textView.string != text && !textView.hasMarkedText() {
            textView.string = text
        }
        textView.font = .systemFont(ofSize: NSFont.systemFontSize)
        textView.textColor = .labelColor
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, onChange: onChange)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        @Binding var text: String
        var onChange: () -> Void

        init(text: Binding<String>, onChange: @escaping () -> Void) {
            _text = text
            self.onChange = onChange
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            text = textView.string
            onChange()
        }
    }
}
