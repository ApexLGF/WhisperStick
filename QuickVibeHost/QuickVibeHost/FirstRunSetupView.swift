import AppKit
import SwiftUI

struct FirstRunSetupView: View {
    @EnvironmentObject var manager: VoiceInputManager
    @EnvironmentObject var modelManager: ASRModelManager
    @EnvironmentObject var englishModelManager: EnglishASRModelManager
    @EnvironmentObject var bleManager: BLEManager
    @EnvironmentObject var languageSettings: AppLanguageSettings

    @AppStorage(FirstRunSetupState.hasCompletedKey) private var hasCompletedFirstRunSetup = false
    @AppStorage(FirstRunSetupState.hasSkippedKey) private var hasSkippedFirstRunSetup = false
    @AppStorage("deepseekPostprocessEnabled") private var deepseekPostprocessEnabled = false
    @State private var page = 0
    @State private var accessibilityGranted = FirstRunSetupState.accessibilityGranted
    @State private var deepseekAPIKey = ""
    @State private var deepseekBaseURL = "https://api.deepseek.com"
    @State private var deepseekModel = "deepseek-v4-flash"
    @State private var deepseekTimeoutSeconds: Double = 6
    @State private var isTestingFastLLM = false
    @State private var fastLLMStatusText = ""

    var onFinish: () -> Void

    private var pages: [String] {
        [AppL10n.tr("辅助功能"), AppL10n.tr("添加设备"), AppL10n.tr("语音识别"), AppL10n.tr("AI 增强")]
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            HStack(spacing: 32) {
                leftPane
                    .frame(width: 320, alignment: .topLeading)
                rightPane
                    .frame(width: 520, height: 430, alignment: .topLeading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            footer
        }
        .padding(28)
        .frame(minWidth: 860, minHeight: 560)
        .background(Color(nsColor: .windowBackgroundColor))
        .id(languageSettings.revision)
        .onAppear {
            refreshPermissions()
            loadFastLLMConfiguration()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshPermissions()
        }
    }

    private var header: some View {
        HStack {
            Text(AppBrand.displayName)
                .font(.system(size: 18, weight: .semibold))
            Spacer()
            Text("\(page + 1) / \(pages.count)")
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
    }

    @ViewBuilder
    private var leftPane: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(pages[page])
                .font(.system(size: 32, weight: .semibold))
            switch page {
            case 0: permissionsStep
            case 1: deviceStep
            case 2: asrStep
            default: fastLLMStep
            }
        }
    }

    private var permissionsStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            permissionAction(title: AppL10n.tr("辅助功能"), granted: accessibilityGranted) {
                KeyboardSimulator.requestAccessibilityPermission()
            }
            if !accessibilityGranted {
                Button(AppL10n.tr("打开辅助功能设置")) {
                    openSystemSettings("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
                }
                .controlSize(.small)
            }
        }
    }

    private var deviceStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            if bleManager.hasMemorizedDevice {
                VStack(alignment: .leading, spacing: 10) {
                    Text(AppL10n.tr("已记忆设备"))
                        .font(.headline)
                    statusLine(
                        title: bleManager.memorizedDeviceName ?? AppL10n.tr("已添加设备"),
                        ok: true
                    )
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
            } else {
                statusLine(title: AppL10n.tr("未添加设备"), ok: false)
                DeviceDiscoveryContent(width: 320, onSelect: nil)
            }
        }
    }

    private var asrStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            Picker(AppL10n.tr("识别方式"), selection: $manager.asrEngine) {
                ForEach(ASREngine.allCases, id: \.self) { engine in
                    Text(engine.displayName).tag(engine)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 320)

            if manager.asrEngine == .local {
                statusLine(title: localModelStatusText, ok: manager.localASRAvailable || modelManager.state == .ready)
                if case .downloading(let progress) = modelManager.state {
                    ProgressView(value: progress)
                        .progressViewStyle(.linear)
                    Text(AppL10n.format("下载中 %@%", String(Int(progress * 100))))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if case .verifying = modelManager.state {
                    ProgressView()
                        .controlSize(.small)
                    Text(AppL10n.tr("正在校验模型"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if case .failed(let reason) = modelManager.state {
                    Text(reason)
                        .font(.caption)
                        .foregroundStyle(.red)
                    Button(AppL10n.tr("重新下载")) {
                        Task { await modelManager.downloadModels() }
                    }
                } else if !manager.localASRAvailable && modelManager.state != .ready {
                    Button(AppL10n.tr("下载模型")) {
                        Task { await modelManager.downloadModels() }
                    }
                    .disabled(isModelBusy)
                }
            } else if manager.asrEngine == .localEnglish {
                statusLine(
                    title: englishModelStatusText,
                    ok: englishModelManager.state == .ready
                )
                if case .downloading(let progress) = englishModelManager.state {
                    ProgressView(value: progress)
                        .progressViewStyle(.linear)
                    Text(AppL10n.format("下载中 %@%", String(Int(progress * 100))))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if case .verifying = englishModelManager.state {
                    ProgressView()
                        .controlSize(.small)
                    Text(AppL10n.tr("正在校验模型"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if case .failed(let reason) = englishModelManager.state {
                    Text(reason)
                        .font(.caption)
                        .foregroundStyle(.red)
                    Button(AppL10n.tr("重新下载")) {
                        Task { await englishModelManager.downloadModels() }
                    }
                } else if englishModelManager.state != .ready {
                    Button(AppL10n.tr("下载模型")) {
                        Task { await englishModelManager.downloadModels() }
                    }
                    .disabled(isModelBusy)
                }
            } else {
                TextField("App Key", text: $manager.appKey)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 320)
                SecureField("Access Key", text: $manager.accessKey)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 320)
                statusLine(title: manager.isConfigured ? AppL10n.tr("豆包配置已填写") : AppL10n.tr("需要 App Key 和 Access Key"), ok: manager.isConfigured)
            }
        }
        .frame(height: 188, alignment: .topLeading)
    }

    private var fastLLMStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(AppL10n.tr("配置 DeepSeek API Key 后，可使用快速 LLM 修正识别文本中的错词和标点，并使用 Prompt 智能推荐、输入助理等高级功能。处理失败时保留原文。"))
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
                    .disabled(!currentFastLLMConfiguration.isConfigured)
                Button(isTestingFastLLM ? AppL10n.tr("测试中...") : AppL10n.tr("测试连接")) {
                    testFastLLMConnection()
                }
                .disabled(isTestingFastLLM || !currentFastLLMConfiguration.isConfigured)
            }
            if !fastLLMStatusText.isEmpty {
                Text(fastLLMStatusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .frame(height: 300, alignment: .topLeading)
    }

    private var rightPane: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(helpTitle)
                .font(.headline)
            Text(helpText)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            setupImage
            Spacer()
        }
        .padding(18)
    }

    private var footer: some View {
        HStack {
            if page > 0 {
                Button(AppL10n.tr("上一步")) { page -= 1 }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
            Button(page == pages.count - 1 ? AppL10n.tr("暂不配置") : AppL10n.tr("稍后设置")) {
                if page == pages.count - 1 {
                    finishSetup(saveFastLLM: false)
                } else {
                    hasCompletedFirstRunSetup = false
                    hasSkippedFirstRunSetup = true
                    onFinish()
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .disabled(page == pages.count - 1 && !canComplete)
            Spacer()
            Button {
                if page < pages.count - 1 {
                    page += 1
                } else {
                    finishSetup(saveFastLLM: true)
                }
            } label: {
                Text(primaryButtonTitle)
                    .font(.system(size: 16, weight: .semibold))
                    .frame(width: 104, height: 36)
            }
            .buttonStyle(.borderedProminent)
            .disabled(page == pages.count - 1 && !canComplete)
        }
    }

    private var canComplete: Bool {
        FirstRunSetupState.isComplete(
            accessibilityGranted: accessibilityGranted,
            asrConfigured: manager.isConfigured
        )
    }

    private var primaryButtonTitle: String {
        page == pages.count - 1 ? AppL10n.tr("完成设置") : AppL10n.tr("下一步")
    }

    private var isModelBusy: Bool {
        if case .downloading = modelManager.state { return true }
        if case .verifying = modelManager.state { return true }
        if case .downloading = englishModelManager.state { return true }
        if case .verifying = englishModelManager.state { return true }
        return false
    }

    private var localModelStatusText: String {
        switch modelManager.state {
        case .downloading:
            return AppL10n.tr("本地模型下载中")
        case .verifying:
            return AppL10n.tr("本地模型校验中")
        case .ready:
            return AppL10n.tr("本地模型已就绪")
        case .failed:
            return AppL10n.tr("本地模型下载失败")
        case .notDownloaded:
            return manager.localASRAvailable ? AppL10n.tr("本地模型已就绪") : AppL10n.tr("本地模型未就绪")
        }
    }

    private var englishModelStatusText: String {
        switch englishModelManager.state {
        case .downloading:
            return AppL10n.tr("英文模型下载中")
        case .verifying:
            return AppL10n.tr("英文模型校验中")
        case .ready:
            return AppL10n.tr("英文流式模型已就绪")
        case .failed:
            return AppL10n.tr("英文模型下载失败")
        case .notDownloaded:
            return AppL10n.tr("英文模型未下载")
        }
    }

    private var helpTitle: String {
        switch page {
        case 0: AppL10n.tr("先开启输入权限")
        case 1: AppL10n.tr("设备可稍后添加")
        case 2: AppL10n.tr("选择识别方式")
        default: AppL10n.tr("可选的 AI 增强")
        }
    }

    private var helpText: String {
        switch page {
        case 0: AppL10n.tr("辅助功能权限用于将语音识别结果输入当前应用，是语音转文字输入正常工作的必要条件。")
        case 1: AppL10n.tr("有 QuickVibe 硬件时可先连接；没有设备也能用 Mac 麦克风完成设置。")
        case 2: AppL10n.tr("本地模型就绪，或豆包 App Key / Access Key 已填写后，即可完成首次设置。")
        default: AppL10n.tr("填写 API Key 后会自动开启识别校对。Prompt 智能推荐和输入助理仍需在高级功能中主动开启。")
        }
    }

    @ViewBuilder
    private var setupImage: some View {
        if page == 0 {
            Image(systemName: "hand.raised.circle.fill")
                .resizable()
                .scaledToFit()
                .foregroundStyle(Color.accentColor.gradient)
                .padding(60)
                .accessibilityHidden(true)
                .frame(maxWidth: .infinity)
                .frame(height: 300)
        } else if page == 3 {
            Image(systemName: "bolt.horizontal.circle.fill")
                .resizable()
                .scaledToFit()
                .foregroundStyle(Color.accentColor.gradient)
                .padding(60)
                .accessibilityHidden(true)
                .frame(maxWidth: .infinity)
                .frame(height: 300)
        } else {
            Image(page == 1 ? "FirstRunDevice" : "FirstRunASR")
                .resizable()
                .scaledToFit()
                .accessibilityHidden(true)
                .frame(maxWidth: .infinity)
                .frame(height: 300)
        }
    }

    private func statusLine(title: String, ok: Bool) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(ok ? Color.green : Color.secondary)
                .frame(width: 8, height: 8)
            Text(title)
                .font(.headline)
        }
    }

    private func permissionAction(title: String, granted: Bool, action: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            statusLine(title: title, ok: granted)
            Spacer()
            Button {
                action()
            } label: {
                Text(granted ? AppL10n.tr("已开启") : AppL10n.tr("开启"))
                    .frame(width: 88, height: 34)
            }
                .disabled(granted)
        }
    }

    private func openSystemSettings(_ scheme: String) {
        guard let url = URL(string: scheme) else { return }
        NSWorkspace.shared.open(url)
    }

    private func refreshPermissions() {
        accessibilityGranted = FirstRunSetupState.accessibilityGranted
    }

    private var currentFastLLMConfiguration: FastLLMConfiguration {
        .init(apiKey: deepseekAPIKey, baseURL: deepseekBaseURL,
              model: deepseekModel, timeoutSeconds: deepseekTimeoutSeconds)
    }

    private func loadFastLLMConfiguration() {
        let configuration = FastLLMConfiguration.load()
        deepseekAPIKey = configuration.apiKey
        deepseekBaseURL = configuration.baseURL
        deepseekModel = configuration.model
        deepseekTimeoutSeconds = configuration.timeoutSeconds
    }

    private func saveFastLLMConfiguration(showStatus: Bool = true) {
        let configuration = currentFastLLMConfiguration
        configuration.save()
        deepseekPostprocessEnabled = configuration.isConfigured
        if showStatus {
            fastLLMStatusText = AppL10n.tr("已保存并开启识别校对")
        }
    }

    private func testFastLLMConnection() {
        let configuration = currentFastLLMConfiguration
        guard configuration.isConfigured else { return }
        saveFastLLMConfiguration(showStatus: false)
        isTestingFastLLM = true
        fastLLMStatusText = AppL10n.tr("检测中...")
        Task {
            do {
                let result = try await DeepSeekPostProcessor(
                    apiKey: configuration.apiKey,
                    baseURL: configuration.baseURL,
                    model: configuration.model,
                    timeoutSeconds: configuration.timeoutSeconds
                ).polish(AppL10n.tr("测试 QuickVibeHost DeepSeek 忠实校对连接。"))
                await MainActor.run {
                    fastLLMStatusText = AppL10n.format("连接成功 %@ms", String(result.elapsedMs))
                    isTestingFastLLM = false
                }
            } catch {
                await MainActor.run {
                    fastLLMStatusText = AppL10n.format("连接失败: %@", error.localizedDescription)
                    isTestingFastLLM = false
                }
            }
        }
    }

    private func finishSetup(saveFastLLM: Bool) {
        if saveFastLLM && currentFastLLMConfiguration.isConfigured {
            saveFastLLMConfiguration(showStatus: false)
        }
        hasCompletedFirstRunSetup = true
        hasSkippedFirstRunSetup = false
        onFinish()
    }
}

struct AccessibilityRepairView: View {
    @EnvironmentObject var languageSettings: AppLanguageSettings

    @State private var accessibilityGranted = FirstRunSetupState.accessibilityGranted
    @State private var hasReturnedFromSystemSettings = false

    var onFinish: () -> Void

    private var isInstalledInApplications: Bool {
        Bundle.main.bundleURL.path.hasPrefix("/Applications/")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack {
                Text(AppBrand.displayName)
                    .font(.system(size: 18, weight: .semibold))
                Spacer()
            }

            HStack(alignment: .top, spacing: 28) {
                Image(systemName: accessibilityGranted ? "checkmark.shield.fill" : "hand.raised.slash.fill")
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(accessibilityGranted ? Color.green.gradient : Color.orange.gradient)
                    .frame(width: 150, height: 150)
                    .padding(.top, 16)

                VStack(alignment: .leading, spacing: 14) {
                    Text(accessibilityGranted ? AppL10n.tr("辅助功能已恢复") : AppL10n.tr("需要修复辅助功能权限"))
                        .font(.system(size: 28, weight: .semibold))
                    Text(AppL10n.tr("VE 语音指挥棒需要辅助功能权限，才能把识别结果输入当前应用。"))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    if !isInstalledInApplications {
                        Label(AppL10n.tr("请先将 App 移到“应用程序”文件夹，再从那里重新打开。"), systemImage: "exclamationmark.triangle.fill")
                            .font(.callout)
                            .foregroundStyle(.orange)
                    }

                    if hasReturnedFromSystemSettings && !accessibilityGranted {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(AppL10n.tr("如果系统设置中已经开启但仍未生效："))
                                .font(.headline)
                            Text(AppL10n.tr("1. 在辅助功能列表中选中旧的“VE 语音指挥棒”，点击减号删除。\n2. 点击加号，重新添加 /Applications/QuickVibeHost.app。\n3. 开启权限后返回本 App。"))
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(12)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.08)))
                    }

                    HStack(spacing: 10) {
                        if accessibilityGranted {
                            Button(AppL10n.tr("继续")) { onFinish() }
                                .buttonStyle(.borderedProminent)
                        } else {
                            Button(AppL10n.tr("请求权限")) {
                                ClaudeCodeSessionManager.log("[permission] accessibility-requested")
                                KeyboardSimulator.requestAccessibilityPermission()
                            }
                            .buttonStyle(.borderedProminent)
                            Button(AppL10n.tr("打开辅助功能设置")) {
                                hasReturnedFromSystemSettings = true
                                ClaudeCodeSessionManager.log("[permission] accessibility-settings-opened")
                                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                                    NSWorkspace.shared.open(url)
                                }
                            }
                        }
                    }
                }
            }

            Spacer()
            HStack {
                Button(AppL10n.tr("稍后处理")) { onFinish() }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
        .padding(32)
        .frame(minWidth: 760, minHeight: 480)
        .background(Color(nsColor: .windowBackgroundColor))
        .id(languageSettings.revision)
        .onAppear(perform: refreshPermission)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            hasReturnedFromSystemSettings = true
            refreshPermission()
        }
    }

    private func refreshPermission() {
        let granted = FirstRunSetupState.accessibilityGranted
        guard granted != accessibilityGranted else { return }
        accessibilityGranted = granted
        ClaudeCodeSessionManager.log("[permission] accessibility-restored ax=\(granted ? "Y" : "N")")
        if granted {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { onFinish() }
        }
    }
}
