import SwiftUI

struct StatusTab: View {
    @EnvironmentObject var manager: VoiceInputManager
    @EnvironmentObject var historyManager: RecognitionHistoryManager
    @EnvironmentObject var usageManager: ClaudeUsageManager

    @EnvironmentObject var bleManager: BLEManager
    @EnvironmentObject var hookStore: ClaudeHookSessionStore
    @EnvironmentObject var sessionManager: ClaudeCodeSessionManager
    @EnvironmentObject var selectionStore: SessionSelectionStore
    @EnvironmentObject var toastCenter: FallbackToastCenter
    @EnvironmentObject var codexMonitor: CodexSessionMonitor
    @EnvironmentObject var codexApprovalServer: CodexApprovalServer
    @EnvironmentObject var chatGPTConversationMonitor: ChatGPTConversationMonitor
    @EnvironmentObject var workBuddyMonitor: WorkBuddySessionMonitor
    @EnvironmentObject var workBuddyApprovalServer: WorkBuddyApprovalServer
    @EnvironmentObject var localAIUsageManager: LocalAIUsageManager


    @Binding var selectedTab: Int
    @Binding var settingsCategory: SettingsCategory?

    /// mock Codex provider 开关(验证多 agent 扩展性);ui-smoke 用 launch flag 强制开。
    @AppStorage("mockCodexEnabled") private var mockCodexEnabled = false

    /// REQ-018: 会话色可读性调整需要感知浅色/深色模式
    @Environment(\.colorScheme) private var colorScheme

    /// 非活跃会话分组展开态;不持久化,每次启动回到折叠
    @State private var showInactiveSessions = false
    @State private var showSevenDayUsageInfo = false

    /// 参与首页展示的 agent 列表:Claude Code / Codex 检测到安装后追加真实 provider。
    /// mock 仅剩 ui-smoke flag 用途(无 Codex 环境的布局回归)。
    /// 值在 get 现算不缓存 —— 各 provider 直接 observe @EnvironmentObject 的 manager,保 @Published 反应性。
    private var providers: [AgentProvider] {
        var list: [AgentProvider] = []
        let claudeProvider = ClaudeCodeProvider(usage: usageManager, store: hookStore, selection: selectionStore)
        if claudeProvider.isInstalled {
            list.append(claudeProvider)
        }
        if CodexSessionMonitor.isInstalled {
            list.append(CodexProvider(monitor: codexMonitor, selectionStore: selectionStore))
        } else if mockCodexEnabled || UITestFlags.mockCodex {
            list.append(MockCodexProvider())
        } else if UITestFlags.mockTiers {
            list.append(MockTierProvider())
        } else if UITestFlags.mockBgSession {
            list.append(MockBgSessionProvider())
        }
        return list
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                deviceStatusSection
                aiUsageSection
                    .padding(.top, 20)
                sessionCardsSection
                    .padding(.top, 20)
                chatGPTConversationsSection
                    .padding(.top, 20)
            }
            .padding(.horizontal, 8)   // 370 窗口下容纳 350 固定宽卡片
            .padding(.vertical, 12)
        }
    }

    // MARK: - ChatGPT Conversations

    private var chatGPTConversationsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "bubble.left")
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 18)
                Text(AppL10n.tr("ChatGPT 聊天"))
                    .font(.headline)
                Spacer()
                if chatGPTConversationMonitor.isScanning {
                    ProgressView()
                        .controlSize(.small)
                }
                Text(AppL10n.format("可见：%@", String(chatGPTConversationMonitor.conversations.count)))
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.primary.opacity(0.08)))
                Button {
                    chatGPTConversationMonitor.rescan()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(AppL10n.tr("重新读取 ChatGPT 侧栏"))
            }

            Text(AppL10n.tr("读取 ChatGPT 侧栏中已经加载的普通聊天；Codex 工作任务仍显示在上方。"))
                .font(.caption)
                .foregroundStyle(.secondary)

            switch chatGPTConversationMonitor.availability {
            case .ready:
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 350), spacing: 12, alignment: .top)],
                    spacing: 12
                ) {
                    ForEach(chatGPTConversationMonitor.conversations) { conversation in
                        chatGPTConversationRow(conversation)
                    }
                }
            case .appNotRunning:
                chatGPTConversationHint(AppL10n.tr("ChatGPT 未运行，打开 ChatGPT 后会自动读取。"), icon: "app.dashed")
            case .accessibilityDenied:
                chatGPTConversationHint(AppL10n.tr("需要辅助功能权限才能读取 ChatGPT 侧栏。"), icon: "hand.raised")
            case .sidebarUnavailable:
                chatGPTConversationHint(AppL10n.tr("未读取到普通聊天。请展开 ChatGPT 侧栏，并确认当前处于 ChatGPT 模式。"), icon: "sidebar.left")
            case .scanFailed:
                chatGPTConversationHint(AppL10n.tr("暂时无法读取 ChatGPT 窗口，稍后会自动重试。"), icon: "exclamationmark.triangle")
            }
        }
    }

    private func chatGPTConversationRow(_ conversation: ChatGPTConversation) -> some View {
        HStack(spacing: 10) {
            Circle()
                .fill(conversation.isSelected ? Color.green : Color.secondary.opacity(0.45))
                .frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 4) {
                Text(conversation.title)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(2)
                    .truncationMode(.tail)
                Text(conversation.isSelected ? AppL10n.tr("当前聊天") : AppL10n.tr("状态不可用"))
                    .font(.caption)
                    .foregroundStyle(conversation.isSelected ? Color.green : Color.secondary)
            }
            Spacer(minLength: 8)
            Button {
                chatGPTConversationMonitor.open(conversation)
            } label: {
                Label(AppL10n.tr("打开"), systemImage: "arrow.up.forward.app")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 68, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(conversation.isSelected ? Color.green.opacity(0.08) : Color.primary.opacity(0.055))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(conversation.isSelected ? Color.green.opacity(0.28) : Color.primary.opacity(0.12), lineWidth: 1)
        )
    }

    private func chatGPTConversationHint(_ text: String, icon: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.045)))
    }

    // MARK: - Device Status (Read-only)

    private struct CurrentDeviceInfo {
        let name: String
        let icon: String
        let isOnline: Bool
        let hasMemory: Bool
    }

    /// 当前展示的设备：优先级 在线 Stick/MicPad > 记忆的 Stick/MicPad > 无。
    /// 单设备约束（NewDeviceTab 替换确认）保证大部分时间只有一条记忆，优先级只影响替换过渡态。
    private var currentDevice: CurrentDeviceInfo {
        if case .memorizedConnected = bleManager.deviceLifecycle {
            return .init(name: bleManager.connectedDeviceName ?? "Stick S3",
                         icon: "antenna.radiowaves.left.and.right",
                         isOnline: true, hasMemory: true)
        }
        if case .noMemory = bleManager.deviceLifecycle {
            return .init(name: AppL10n.tr("未连接设备"), icon: "questionmark.circle",
                         isOnline: false, hasMemory: false)
        }
        return .init(name: bleManager.memorizedDeviceName ?? "Stick S3",
                     icon: "antenna.radiowaves.left.and.right",
                     isOnline: false, hasMemory: true)
    }

    private var deviceStatusSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: currentDevice.icon)
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                Text(AppL10n.tr("设备"))
                    .foregroundStyle(.secondary)
                Text(currentDevice.name)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                Spacer()
                if currentDevice.isOnline {
                    HStack(spacing: 4) {
                        Circle().fill(.green).frame(width: 8, height: 8)
                        Text(AppL10n.tr("已连接"))
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Button(AppL10n.tr("连接设备")) { selectedTab = 1 }
                        .font(.caption)
                        .fontWeight(.semibold)
                        .buttonStyle(.plain)
                        .padding(.horizontal, 12)
                        .frame(height: 26)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color.primary.opacity(0.08))
                        )
                }
            }

            HStack(spacing: 8) {
                Image(systemName: manager.asrEngine == .local ? "cpu" : "cloud")
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                Text("ASR")
                    .foregroundStyle(.secondary)
                Text(manager.asrEngine.displayName)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                Spacer()
                HStack(spacing: 4) {
                    Circle()
                        .fill(asrStateColor)
                        .frame(width: 8, height: 8)
                    if asrUnconfigured {
                        Button(AppL10n.tr("未配置")) {
                            settingsCategory = .voice
                            selectedTab = 4
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .underline()
                    } else {
                        Text(asrStateText)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .font(.subheadline)
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.primary.opacity(0.055))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.primary.opacity(0.12), lineWidth: 1)
        )
    }

    /// 未配置态仅在空闲时呈现;录音/识别/出错沿用各自状态展示。
    private var asrUnconfigured: Bool {
        if case .idle = manager.state { return !manager.isConfigured }
        return false
    }

    private var asrStateColor: Color {
        switch manager.state {
        case .recording: .red
        case .processing: .orange
        case .error: .red
        case .idle: manager.isConfigured ? .green : Color.secondary
        }
    }

    private var asrStateText: String {
        switch manager.state {
        case .idle: AppL10n.tr("已就绪")
        case .recording: AppL10n.tr("录音中")
        case .processing: AppL10n.tr("识别中")
        case .error: AppL10n.tr("出错")
        }
    }

    // MARK: - Hook Sessions

    /// 会话卡片排序(纯函数,可单测):阻塞组(等待审批/等待输入)置顶,组内外时间倒序。
    static func sortForCards(_ sessions: [HookSession]) -> [HookSession] {
        func blocked(_ s: HookSession) -> Bool {
            s.phase.isWaitingForApproval || s.phase == .waitingForInput
        }
        return sessions.sorted { a, b in
            if blocked(a) != blocked(b) { return blocked(a) }        // 阻塞组置顶
            return a.lastActivity > b.lastActivity                   // 组内外时间倒序
        }
    }

    private var sessionCardsSection: some View {
        // 跨 agent 混排 + 阻塞组置顶
        let sessions = Self.sortForCards(providers.flatMap(\.activeSessions) + workBuddyMonitor.activeSessions)
        let inactive = (providers.flatMap(\.inactiveSessions) + workBuddyMonitor.inactiveSessions)
            .sorted { $0.lastActivity > $1.lastActivity }
            .prefix(SessionLivenessParams.appInactiveCap)      // REQ-028 §4:App 端 50 条
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "bubble.left.and.bubble.right")
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 18)
                Text(AppL10n.tr("AI 会话"))
                    .font(.headline)
                Spacer()
                ForEach(providers.indices, id: \.self) { i in
                    let provider = providers[i]
                    Text("\(provider.shortName):\(provider.activeSessions.count + provider.inactiveSessions.count)")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(
                            Capsule().fill(Color.primary.opacity(0.08))
                        )
                }
                if WorkBuddySessionMonitor.isInstalled {
                    Text("WB:\(workBuddyMonitor.activeSessions.count + workBuddyMonitor.inactiveSessions.count)")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color.primary.opacity(0.08)))
                }
            }

            Text(AppL10n.format("活跃 %@", String(sessions.count)))
                .font(.caption).fontWeight(.semibold).foregroundStyle(.secondary)

            if sessions.isEmpty {
                Text(AppL10n.tr("暂无活跃会话"))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 350), spacing: 12, alignment: .top)], spacing: 12) {
                    ForEach(sessions) { session in
                        hookSessionRow(session)
                            .padding(12)
                            .frame(maxWidth: .infinity, minHeight: 78, alignment: .topLeading)
                            .background(
                                RoundedRectangle(cornerRadius: 10)
                                    .fill(sessionCardFill(session))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 10)
                                    .stroke(Color.primary.opacity(0.12), lineWidth: 1)
                            )
                    }
                }
            }

            // 非活跃分组:idle + 进程存活 + transcript 30min 无更新;默认折叠,transcript 有新写入自动回活跃区
            if !inactive.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Button {
                        showInactiveSessions.toggle()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: showInactiveSessions ? "chevron.down" : "chevron.right")
                                .font(.caption2)
                            Text(AppL10n.format("非活跃 %@", String(inactive.count)))
                                .font(.caption)
                        }
                        .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)

                    if showInactiveSessions {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 350), spacing: 12, alignment: .top)], spacing: 12) {
                            ForEach(Array(inactive)) { session in
                                hookSessionRow(session)
                                    .padding(12)
                                    .frame(maxWidth: .infinity, minHeight: 78, alignment: .topLeading)
                                    .background(
                                        RoundedRectangle(cornerRadius: 10)
                                            .fill(sessionCardFill(session))
                                    )
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 10)
                                            .stroke(Color.primary.opacity(0.12), lineWidth: 1)
                                    )
                                    .opacity(0.65)
                            }
                        }
                    }
                }
            }
        }
    }

    private func sessionCardFill(_ session: HookSession) -> Color {
        if selectionStore.isSelected(session.id) {
            let sessionColor = SessionColorManager.readableColor(
                for: SessionColorManager.shared.colorForSession(session.id, pid: session.pid),
                in: colorScheme
            )
            return sessionColor.opacity(0.10)
        }
        return Color.primary.opacity(0.06)
    }

    private func hookSessionRow(_ session: HookSession) -> some View {
        // REQ-018: 浅色模式下弱对比会话色(yellow/cyan/遗留 white)压暗保可读;
        // 作用于竖条填充/选中 tint/审批框(本函数内 sessionColor 的全部用途)
        let sessionColor = SessionColorManager.readableColor(
            for: SessionColorManager.shared.colorForSession(session.id, pid: session.pid),
            in: colorScheme
        )
        let isSelected = selectionStore.isSelected(session.id)

        let contextPercent = usageManager.contextUsedPercent(sessionId: session.id)
            ?? snapshotCtxPercent(session)
        let hasInfoLine = Self.hasCompactSessionInfo(session)

        return HStack(spacing: 0) {
            // REQ-017: 左侧竖条 1.5×宽 + 细边框,自底向上填充 = context 已用%
            // CC 走 statusLine capture;Codex 无 capture,回退 transcriptSnapshot 的 token 比值
            ContextUsageBar(
                color: sessionColor,
                usedPercent: contextPercent
            )
            .padding(.vertical, 2)

            VStack(alignment: .leading, spacing: hasInfoLine ? 7 : 12) {
            HStack(spacing: 6) {
                if isWorkBuddySession(session) {
                    Image("WorkBuddyIcon")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 16, height: 16)
                }
                Text(session.projectName)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(1)
                if !session.backgroundTasks.isEmpty {
                    BackgroundTaskBadge(tasks: session.backgroundTasks)
                }
                Spacer()
                HStack(spacing: 4) {
                    // REQ-022 后续批:StopFailure 标记的 error 会话给红色标识,
                    // 与设备侧 SDS_BLOCKED(红快闪 + TASK_ERROR 音)对齐;下一次会话活动自动消失。
                    // 已结束 + error = 宽限期(60s)展示「已结束(出错)」,替代 phase 文案避免重复
                    if session.hasError {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(.red)
                        Text(session.phase == .ended ? AppL10n.tr("已结束(出错)") : AppL10n.tr("错误"))
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.red)
                            .lineLimit(1)
                            .help(session.lastError ?? AppL10n.tr("turn 因 API 错误结束"))
                    }
                    if shouldShowPhaseDot(session.phase) {
                        Circle()
                            .fill(hookPhaseColor(session.phase))
                            .frame(width: 6, height: 6)
                    }
                    if !(session.hasError && session.phase == .ended) {
                        Text(phaseText(session))
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(hookPhaseColor(session.phase))
                            .lineLimit(1)
                    }
                }
                .fixedSize(horizontal: true, vertical: false)
                // 直通入口:CC 与 Codex CLI 可选;Codex Desktop/VSCode 无 PTY 通道不可直通
                if !isAppHostedCodexSession(session) && !isWorkBuddySession(session) {
                    let canInject = exclusiveAvailable(session)
                    Button {
                        requestToggleExclusive(session: session)
                    } label: {
                        Image(systemName: isSelected ? "target" : "scope")
                            .font(.system(size: 15, weight: .medium))
                            .frame(width: 18, height: 22)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(isSelected ? Color.orange : (canInject ? Color.accentColor : Color.secondary.opacity(0.4)))
                    .disabled(!isSelected && !canInject)
                    .help(isSelected ? AppL10n.tr("取消直通")
                          : (canInject ? AppL10n.tr("选为直通") : FallbackReason.vibeptyUnavailable.toastMessage))
                }
                // 会话跳转与直通选择分离：优先定位精确窗口/tab，失败时才激活宿主 App。
                Button {
                    if isWorkBuddySession(session) {
                        _ = workBuddyMonitor.openConversation(id: session.id)
                    } else {
                        SessionNavigationService.open(session: session, sessionManager: sessionManager)
                    }
                } label: {
                    Image(systemName: "arrow.up.forward.app")
                        .font(.system(size: 15, weight: .medium))
                        .frame(width: 18, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(AppL10n.tr("打开窗口"))
                SessionDetailsButton(rows: sessionDetailRows(session))
            }

            if hasInfoLine {
                compactSessionInfoLine(session)
            }
            compactSessionMetaLine(session, contextPercent: contextPercent)

            // Approval toast — 单一状态源：monitor 将 hook pending 映射为 session.phase，
            // View 不再自行查询 server.pending，避免两条状态管线产生不同显示结果。
            if case .waitingForApproval(let ctx) = session.phase {
                HStack(alignment: .center, spacing: 10) {
                    // 工具名恒显 + 参数摘要(无参数时显式提示,杜绝空白审批框:
                    // 2026-07-23 实例 mcp__kicad__list_projects 无参数 → 框内全空)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 4) {
                            Text(prettyToolName(ctx.toolName))
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.primary)
                            if ctx.toolName.hasPrefix("mcp__") {
                                Text("MCP")
                                    .font(.system(size: 9, weight: .bold))
                                    .padding(.horizontal, 4).padding(.vertical, 1)
                                    .background(Color.orange.opacity(0.2), in: Capsule())
                                    .foregroundStyle(.orange)
                            }
                        }
                        Text(ctx.formattedInput ?? AppL10n.tr("(无参数)"))
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    // 应答通道(REQ-022 C5):hook pending 存在即可判决,不再按
                    // originator 假设"Desktop/VSCode 无应答通道"。
                    // CC → hook socket;Codex(任意形态,hook 挂起,pendingKey 做
                    // originator/uuid 适配)→ CodexApprovalServer;
                    // 仅当确无 hook 挂起(未装/未信任,rollout 只读检测)时,
                    // Desktop/VSCode 才显示仅激活宿主的普通入口。
                    if isWorkBuddySession(session),
                       let requestKey = workBuddyApprovalServer.pendingKey(for: ctx) {
                        approvalButtons(
                            allow: {
                                workBuddyApprovalServer.respond(
                                    requestKey: requestKey, decision: "allow"
                                )
                            },
                            deny: {
                                workBuddyApprovalServer.respond(
                                    requestKey: requestKey, decision: "deny",
                                    reason: "Denied by user via QuickVibeHost"
                                )
                            },
                            handoff: {
                                workBuddyApprovalServer.abandon(requestKey: requestKey)
                                _ = workBuddyMonitor.openConversation(id: session.id)
                            }
                        )
                    } else if !isCodexSession(session) {
                        approvalButtons(
                            allow: { hookStore.approvePermission(sessionId: session.id) },
                            deny: { hookStore.denyPermission(sessionId: session.id) }
                        )
                    } else if let pendingKey = codexApprovalServer.pendingKey(for: ctx) {
                        approvalButtons(
                            allow: { codexApprovalServer.respond(sessionKey: pendingKey, decision: "allow") },
                            deny: { codexApprovalServer.respond(sessionKey: pendingKey, decision: "deny") },
                            handoff: { handOffCodexApproval(session, pendingKey: pendingKey) }
                        )
                    } else if isAppHostedCodexSession(session) {
                        goHandleButton(session)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 7)
                        .fill(Color.orange.opacity(0.08))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 7)
                        .stroke(Color.orange.opacity(0.24), lineWidth: 1)
                )
            }

            }
            .padding(.leading, 14)
            .padding(.vertical, 2)
            .frame(maxHeight: .infinity, alignment: hasInfoLine ? .topLeading : .leading)
        }
    }

    // MARK: - Session Cell Groups

    private static func hasCompactSessionInfo(_ session: HookSession) -> Bool {
        let snap = session.transcriptSnapshot
        return snap?.model != nil
            || sessionDuration(snap) != nil
            || session.lastTool != nil
            || snap?.activeSubagent?.lastToolName != nil
    }

    @ViewBuilder
    private func compactSessionInfoLine(_ session: HookSession) -> some View {
        let snap = session.transcriptSnapshot
        let lastSubTool = snap?.activeSubagent?.lastToolName

        HStack(spacing: 10) {
            HStack(spacing: 6) {
                if let model = snap?.model {
                    Text(Self.shortModel(model))
                        .font(.caption2)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Self.modelColor(model).opacity(0.16)))
                        .foregroundStyle(Self.modelColor(model))
                }

                if let dur = Self.sessionDuration(snap) {
                    Text(AppL10n.format("已进行 %@", dur))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            .layoutPriority(1)

            Spacer(minLength: 8)

            if let tool = session.lastTool ?? lastSubTool {
                HStack(spacing: 0) {
                    Text(AppL10n.tr("最近："))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(localizedToolName(tool))
                        .font(.caption2)
                        .fontWeight(.medium)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
    }

    @ViewBuilder
    private func compactSessionMetaLine(_ session: HookSession, contextPercent: Int?) -> some View {
        let snap = session.transcriptSnapshot

        HStack(spacing: 8) {
            Text(shortCwd(session.cwd))
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)

            if let branch = snap?.gitBranch {
                HStack(spacing: 3) {
                    Image(systemName: "arrow.triangle.branch")
                    Text(branch)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                    .font(.caption2)
                    .fontWeight(branch == "main" ? .regular : .medium)
                    .foregroundStyle(branch == "main" ? .tertiary : .secondary)
                    .fixedSize(horizontal: true, vertical: false)
            }

            Spacer(minLength: 0)

            if let contextPercent {
                Text(Self.contextSummaryText(contextPercent))
                    .font(.caption2)
                    .fontWeight(contextPercent >= 70 ? .medium : .regular)
                    .foregroundStyle(Self.contextPercentColor(Double(contextPercent)))
                    .monospacedDigit()
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
        }
    }

    static func contextSummaryText(_ contextPercent: Int) -> String {
        AppL10n.format("上下文 %@%", String(contextPercent))
    }

    private func sessionDetailRows(_ session: HookSession) -> [(String, String)] {
        var rows: [(String, String)] = [
            (AppL10n.tr("路径"), session.cwd)
        ]
        if let snap = session.transcriptSnapshot {
            if let branch = snap.gitBranch { rows.append((AppL10n.tr("分支"), branch)) }
            if snap.turnCount > 0 { rows.append((AppL10n.tr("轮次"), "\(snap.turnCount)")) }
            if let cost = snap.totalCostUSD { rows.append((AppL10n.tr("费用"), String(format: "$%.2f", cost))) }
            if let ratio = snap.cacheHitRatio { rows.append((AppL10n.tr("缓存"), "\(Int(ratio * 100))%")) }
            let input = snap.totalInputTokens ?? 0
            let create = snap.totalCacheCreationTokens ?? 0
            let read = snap.totalCacheReadTokens ?? 0
            let output = snap.totalOutputTokens ?? 0
            if input > 0 || create > 0 || read > 0 || output > 0 {
                rows.append(("Token", AppL10n.format("输入 %@ / 写缓存 %@ / 读缓存 %@ / 输出 %@", Self.formatTokens(input), Self.formatTokens(create), Self.formatTokens(read), Self.formatTokens(output))))
            }
        }
        if let pid = session.pid { rows.append((AppL10n.tr("进程"), "\(pid)")) }
        if let tty = session.tty { rows.append((AppL10n.tr("终端"), tty)) }
        return rows
    }

    private func shortCwd(_ cwd: String) -> String {
        let home = NSHomeDirectory()
        if cwd == home { return "~" }
        if cwd.hasPrefix(home + "/") {
            return "~/" + cwd.dropFirst(home.count + 1)
        }
        return cwd
    }

    private func localizedToolName(_ tool: String) -> String {
        switch tool {
        case "exec_command", "bash", "shell": AppL10n.tr("执行命令")
        case "apply_patch": AppL10n.tr("修改文件")
        case "read_file", "Read": AppL10n.tr("读取文件")
        case "write_file", "Write": AppL10n.tr("写入文件")
        case "edit_file", "Edit", "MultiEdit": AppL10n.tr("编辑文件")
        case "grep", "search", "rg", "Glob": AppL10n.tr("搜索文件")
        case "ls", "list_dir": AppL10n.tr("查看目录")
        case "web_search", "search_query": AppL10n.tr("网页搜索")
        case "web_fetch", "open": AppL10n.tr("打开网页")
        case "todo_write", "TodoWrite": AppL10n.tr("更新任务")
        default: tool.replacingOccurrences(of: "_", with: " ")
        }
    }

    // MARK: - Exclusive mode gating

    /// 直通模式准入：任一已记忆外接设备当前在线即允许。
    /// - 有设备在线 → 进入直通
    /// - 有记忆但都不在线 → toast 提示并拒绝
    /// - 无任何记忆 → toast + 跳转到"设备" TAB
    /// - 已经是直通状态时允许无条件取消
    private func requestToggleExclusive(session: HookSession) {
        if selectionStore.isSelected(session.id) {
            selectionStore.clear()
            return
        }
        // codex CLI 无 pid 映射(未经 vibepty 启动)→ 选了也注入不了,选择时即拦截提示
        if isCodexSession(session), session.pid == nil {
            toastCenter.show(reason: .codexNotWrapped)
            return
        }
        if anyDeviceOnline {
            // BUG-005:选中不再激活目标窗口——直通注入是 PTY 直写不依赖前台焦点,
            // 激活徒增 2-3s 主线程阻塞(高负载机)+ 夺当前 app 焦点;要看窗口用
            // 会话卡的「打开窗口」按钮(04-13 原设计的"观察目标"价值已被 PhaseGate/
            // 会话色标/打开窗口按钮替代,知情推翻,考据见 BUG-005 文档)
            selectionStore.select(session.id)
        } else if anyDeviceMemorized {
            toastCenter.show(reason: .exclusiveDeviceOffline)
        } else {
            toastCenter.show(reason: .exclusiveRequiresDevice)
            selectedTab = 1  // 跳到设备 TAB，用户直接连一下
        }
    }

    /// 是否存在任一在线的外接设备（Stick S3 / MicPad）。
    private var anyDeviceOnline: Bool {
        if case .memorizedConnected = bleManager.deviceLifecycle { return true }
        return false
    }

    /// 是否至少记忆了一台外接设备（不论在线与否）。
    private var anyDeviceMemorized: Bool {
        if case .noMemory = bleManager.deviceLifecycle {
            return false
        }
        return true
    }

    // MARK: - Formatting helpers

    private static func shortModel(_ model: String) -> String {
        if model.contains("opus-4")   { return "opus-4.6" }
        if model.contains("sonnet-4") { return "sonnet-4.6" }
        if model.contains("haiku-4")  { return "haiku-4.5" }
        return model
    }

    private static func modelColor(_ model: String) -> Color {
        if model.contains("opus")   { return .purple }
        if model.contains("sonnet") { return .blue }
        if model.contains("haiku")  { return .green }
        return .secondary
    }

    private static func permModeColor(_ mode: String) -> Color {
        switch mode {
        case "plan":              return .orange
        case "bypassPermissions": return .red
        case "acceptEdits":       return .teal
        default:                  return .secondary
        }
    }

    private static func contextPercentColor(_ pct: Double) -> Color {
        if pct >= 90 { return .red }
        if pct >= 75 { return .orange }
        if pct >= 50 { return .primary }
        return .secondary
    }

    private static func formatTokens(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.2fM", Double(n) / 1_000_000) }
        if n >= 1_000     { return String(format: "%.1fk", Double(n) / 1_000) }
        return "\(n)"
    }

    private static func sessionDuration(_ snap: TranscriptSnapshot?) -> String? {
        guard let snap, let first = snap.firstTimestamp, let last = snap.lastTimestamp else { return nil }
        let s = Int(last.timeIntervalSince(first))
        guard s > 0 else { return nil }
        if s < 60  { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m" }
        return String(format: "%dh%dm", s / 3600, (s % 3600) / 60)
    }

    /// transcriptSnapshot 的 context 已用%(Codex 会话:token_count 推导;CC 无 capture 时也可兜底)
    private func snapshotCtxPercent(_ session: HookSession) -> Int? {
        guard let snap = session.transcriptSnapshot,
              let used = snap.contextPromptTokens,
              let limit = snap.contextLimitTokens, limit > 0 else { return nil }
        return min(100, Int(Double(used) / Double(limit) * 100))
    }

    /// Codex 会话(id 带 codex- 前缀)
    private func isCodexSession(_ session: HookSession) -> Bool {
        session.id.hasPrefix("codex-")
    }

    private func isWorkBuddySession(_ session: HookSession) -> Bool {
        session.id.hasPrefix("workbuddy:")
    }

    /// Codex Desktop 会话:无 PTY 注入通道,不可直通(REQ-019 定案)
    private func isCodexDesktopSession(_ session: HookSession) -> Bool {
        session.id.hasPrefix("codex-desktop:")
    }

    private func isVSCodeHostedCodexSession(_ session: HookSession) -> Bool {
        session.id.hasPrefix("codex-vscode:")
    }

    private func isAppHostedCodexSession(_ session: HookSession) -> Bool {
        isCodexDesktopSession(session) || isVSCodeHostedCodexSession(session)
    }

    /// 直通按钮可用性:孤儿 bg 永不可直通;其余按 vibepty socket 存在性。
    /// Codex 会话沿用旧路径(pid 有则可,选中时二次拦截),不受本门槛影响。
    private func exclusiveAvailable(_ session: HookSession) -> Bool {
        if session.isBackgroundOrphan { return false }
        if isCodexSession(session) { return session.pid != nil }
        guard let pid = session.pid else { return false }
        return VibeptyClient.isChannelAvailable(pid: pid)
    }

    /// codex 会话 id("codex-desktop:<uuid>" 等)→ thread uuid;非 codex 返回 nil
    private func codexThreadId(_ session: HookSession) -> String? {
        guard session.id.hasPrefix("codex-") else { return nil }
        guard let uuid = session.id.split(separator: ":").last, !uuid.isEmpty else { return nil }
        return String(uuid)
    }

    /// MCP 工具名美化:mcp__kicad__list_projects → kicad · list_projects;其余原样
    private func prettyToolName(_ name: String) -> String {
        guard name.hasPrefix("mcp__") else { return name }
        // mcp__server__tool → server · tool
        let segs = name.components(separatedBy: "__").filter { !$0.isEmpty }
        if segs.count >= 3 { return segs[1...].joined(separator: " · ") }
        return name
    }

    /// 将 QuickVibe 挂起的 Codex 审批交还原生端。
    /// CLI 不可使用 deep link（会创建会话副本），只关闭 hook，原终端会立即显示审批；
    /// Desktop 才按 thread 精确 deep link，VSCode 仅激活宿主。
    private func handOffCodexApproval(_ session: HookSession, pendingKey: String) {
        codexApprovalServer.abandon(sessionKey: pendingKey)
        if isCodexDesktopSession(session) {
            CodexDesktopActivator.bringToFront(threadId: codexThreadId(session))
        } else if isVSCodeHostedCodexSession(session) {
            CodexVSCodeActivator.bringToFront()
        }
    }

    /// 无 QuickVibe hook 挂起时的普通入口：只激活 Codex 宿主，不尝试处理审批。
    @ViewBuilder
    private func goHandleButton(_ session: HookSession) -> some View {
        Button {
            if isVSCodeHostedCodexSession(session) {
                CodexVSCodeActivator.bringToFront()
            } else {
                CodexDesktopActivator.bringToFront(threadId: codexThreadId(session))
            }
        } label: {
            Label(AppL10n.tr("打开会话"), systemImage: "arrow.up.forward.app")
                .font(.caption)
                .foregroundColor(.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
    }

    /// 审批卡 Allow/Deny 按钮对(CC 与 Codex 共用外观,仅应答通道不同)
    @ViewBuilder
    private func approvalButtons(allow: @escaping () -> Void, deny: @escaping () -> Void,
                                 handoff: (() -> Void)? = nil) -> some View {
        HStack(spacing: 6) {
            Button(action: allow) {
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .bold))
                    .frame(width: 22, height: 22)
                    .foregroundColor(.accentColor)
                    .background(Color.accentColor.opacity(0.16), in: Circle())
            }
            .buttonStyle(.plain)
            .help("Allow")

            Button(action: deny) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .frame(width: 22, height: 22)
                    .foregroundColor(.red)
                    .background(Color.red.opacity(0.12), in: Circle())
            }
            .buttonStyle(.plain)
            .help("Deny")

            if let handoff {
                Button(AppL10n.tr("前往处理"), action: handoff)
                    .font(.system(size: 11, weight: .medium))
                    .buttonStyle(.plain)
                    .help(AppL10n.tr("关闭 QuickVibe 审批并交回 Codex 原生审批"))
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    /// REQ-022 后续批:processing + modelInferring →「思考中」(设备侧 SDS_THINKING 蓝呼吸对齐)。
    /// 圆点/文字颜色不变 — hookPhaseColor(.processing) 本就是蓝,thinking 与 active 同色系,
    /// 由文案区分;设备端才用呼吸动画区分。
    private func phaseText(_ session: HookSession) -> String {
        if session.phase == .processing, session.modelInferring { return AppL10n.tr("思考中") }
        return session.phase.displayName
    }

    private func hookPhaseColor(_ phase: SessionPhase) -> Color {
        switch phase {
        case .idle: .secondary
        case .processing: .blue
        case .waitingForInput: .green
        case .waitingForApproval: .orange
        case .compacting: .purple
        case .ended: .secondary
        }
    }

    private func shouldShowPhaseDot(_ phase: SessionPhase) -> Bool {
        switch phase {
        case .waitingForInput, .waitingForApproval, .compacting: true
        case .idle, .processing, .ended: false
        }
    }

    // MARK: - AI Usage

    /// 「AI 用量」区：单卡铺满,多卡按 350 最小列宽自适应分栏。
    private var aiUsageSection: some View {
        AIUsageOverviewSection(
            providers: providers.map(providerCardPresentation) + workBuddyCardPresentations,
            localUsage: localAIUsageManager,
            onRefreshProviders: { workBuddyMonitor.refresh() }
        )
    }

    private var workBuddyCardPresentations: [AIProviderCardPresentation] {
        guard WorkBuddySessionMonitor.isInstalled else { return [] }
        return [AIProviderCardPresentation(
            id: "workbuddy",
            displayName: "WorkBuddy",
            iconAssetName: "WorkBuddyIcon",
            usesSystemIcon: false,
            badge: nil,
            badgeHelp: nil,
            activeSessionCount: workBuddyMonitor.activeSessions.count,
            totalSessionCount: workBuddyMonitor.activeSessions.count + workBuddyMonitor.inactiveSessions.count,
            billingMode: .unknown,
            windows: [],
            apiUsage: nil,
            creditUsage: AICreditUsagePresentation(
                today: workBuddyMonitor.credits.todayCredits,
                historical: workBuddyMonitor.credits.historicalCredits,
                updatedAt: workBuddyMonitor.credits.updatedAt
            ),
            sevenDayPeaks: nil,
            lastUpdated: workBuddyMonitor.credits.updatedAt,
            exclusiveName: nil,
            awaitingFirstData: workBuddyMonitor.isRefreshing && workBuddyMonitor.sessions.isEmpty
        )]
    }

    private func providerCardPresentation(_ provider: AgentProvider) -> AIProviderCardPresentation {
        let usage = provider.usage
        let billingMode = provider.billingMode
        var windows: [AIQuotaWindowPresentation] = []
        if let short = usage.todayPercent {
            windows.append(.init(
                id: "\(provider.shortName)-short",
                label: usage.todayLabel,
                usedPercent: short,
                resetsAt: usage.todayResetsAt
            ))
        }
        if let long = usage.weekPercent {
            windows.append(.init(
                id: "\(provider.shortName)-long",
                label: usage.weekLabel,
                usedPercent: long,
                resetsAt: usage.weekResetsAt
            ))
        }
        return AIProviderCardPresentation(
            id: provider.shortName.lowercased(),
            displayName: provider.displayName,
            iconAssetName: provider.iconAssetName,
            usesSystemIcon: provider is MockCodexProvider,
            badge: provider.identityBadge,
            badgeHelp: provider.identityBadgeHelp,
            activeSessionCount: provider.activeSessions.count,
            totalSessionCount: provider.activeSessions.count + provider.inactiveSessions.count,
            billingMode: billingMode,
            windows: windows,
            apiUsage: apiUsagePresentation(for: provider, billingMode: billingMode),
            creditUsage: nil,
            sevenDayPeaks: usage.sevenDayPeaks,
            lastUpdated: usage.lastUpdated,
            exclusiveName: usage.exclusiveName,
            awaitingFirstData: billingMode.isAPI ? apiUsageAwaitingFirstData : usage.awaitingFirstData
        )
    }

    private var apiUsageAwaitingFirstData: Bool {
        guard localAIUsageManager.snapshot == nil else { return false }
        switch localAIUsageManager.state {
        case .idle, .loading: return true
        case .available, .empty, .failed: return false
        }
    }

    private func apiUsagePresentation(
        for provider: AgentProvider,
        billingMode: AgentBillingMode
    ) -> AIAPIUsagePresentation? {
        guard billingMode.isAPI, let snapshot = localAIUsageManager.snapshot else { return nil }
        let id = provider.shortName.lowercased() == "cc" ? "claude" : provider.shortName.lowercased()
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: Date()) ?? Date()
        return AIAPIUsagePresentation(
            today: apiPeriod(snapshot.totals(agentID: id, days: 1)),
            yesterday: apiPeriod(snapshot.totals(agentID: id, endingAt: yesterday, days: 1)),
            thirtyDays: apiPeriod(snapshot.totals(agentID: id, days: 30)),
            updatedAt: snapshot.capturedAt
        )
    }

    private func apiPeriod(_ totals: LocalAIUsageSnapshot.AgentTotals) -> AIAPIUsagePeriodPresentation {
        .init(
            inputTokens: totals.inputTokens,
            outputTokens: totals.outputTokens,
            cacheCreationTokens: totals.cacheCreationTokens,
            cacheReadTokens: totals.cacheReadTokens,
            estimatedCost: totals.estimatedCost,
            unpricedModels: totals.unpricedModels
        )
    }

    // MARK: - Helpers

    private var bleStatusColor: Color {
        switch bleManager.connectionState {
        case .connected: .green
        case .disconnected: .secondary
        default: .orange
        }
    }

}

private struct BackgroundTaskBadge: View {
    let tasks: [BackgroundTaskInfo]
    @State private var expanded = false
    var body: some View {
        Button { expanded.toggle() } label: {
            HStack(spacing: 3) {
                Image(systemName: "arrow.triangle.branch").font(.system(size: 10))
                Text(AppL10n.format("后台任务 ×%@", String(tasks.count))).font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(Color.secondary.opacity(0.15)))
        }
        .buttonStyle(.plain)
        .popover(isPresented: $expanded, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(tasks) { t in
                    HStack(spacing: 6) {
                        Text(t.displayName).font(.system(size: 12, weight: .medium))
                        if let s = t.status {
                            Text(s).font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .padding(10)
        }
    }
}

private struct SessionDetailsButton: View {
    let rows: [(String, String)]
    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            Image(systemName: "info.circle")
                .font(.system(size: 15, weight: .medium))
                .frame(width: 18, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(AppL10n.tr("会话详情"))
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                Text(AppL10n.tr("会话详情"))
                    .font(.headline)
                Divider()
                ForEach(rows.indices, id: \.self) { i in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(rows[i].0)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(width: 54, alignment: .leading)
                        Text(rows[i].1)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.primary)
                            .textSelection(.enabled)
                            .lineLimit(2)
                    }
                }
            }
            .padding(12)
            .frame(width: 360, alignment: .leading)
        }
    }
}

/// 左侧竖条:宽 6(1.5×原 4)+ 细边框,自底向上填充比例 = context 已用%
/// nil(无 capture 数据)时仅显示空轨道
struct ContextUsageBar: View {
    let color: Color
    let usedPercent: Int?

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .bottom) {
                // REQ-018: 轨道与边框用语义色 — 百分比是功能性信息,
                // 结构可读性不依赖会话色与背景的对比度(白/黄等弱色兜底)
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.secondary.opacity(0.15))
                if let pct = usedPercent {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(color)
                        .frame(height: geo.size.height * CGFloat(min(max(pct, 0), 100)) / 100)
                }
            }
        }
        .frame(width: 6)
        .overlay(
            RoundedRectangle(cornerRadius: 2)
                .stroke(Color.secondary.opacity(0.5), lineWidth: 0.75)
        )
        .help(usedPercent.map { AppL10n.format("context 已用 %@%", String($0)) } ?? AppL10n.tr("context 用量未知"))
    }
}
