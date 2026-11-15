import Foundation
import AppKit
import Darwin
import os
import ApprovalKit   // REQ-022:ApprovalResolveReason

private let logger = Logger(subsystem: "com.vibeeverything.QuickVibeHost", category: "CodexApproval")

// MARK: - 审批 server(REQ-021 路径②:hook 阻塞回传)

/// 接收 codex PermissionRequest hook(quickvibehost-codex-hook.py)的挂起连接,
/// UI/设备端 Allow/Deny 后写回 {"decision":...} 放行 hook。
///
/// 与 CC 的 HookSocketServer 分开:那边事件流会喂 ClaudeHookSessionStore 建会话,
/// codex 的会话状态源是 rollout(CodexSessionMonitor),这里只承担审批应答一件事。
@MainActor
final class CodexApprovalServer: ObservableObject {
    nonisolated static let socketPath = "/tmp/vibepanel-codex.sock"
    static let deviceOnlineWindowSeconds = 60
    static let deviceOfflineWindowSeconds = 10
    /// hook 最长等待 60s；此处只为异常/旧 hook 留出收尾余量。
    private static let maximumPendingLifetime: TimeInterval = 75

    struct Pending {
        let sessionKey: String          // "codex-cli:<uuid>"
        let context: PermissionContext
        /// hook 给出的 rollout 路径。Desktop 续接时 UUID 可能变化，路径是卡片映射的兜底。
        let transcriptPath: String?
        let clientSocket: Int32
        let receivedAt: Date
    }

    /// key = sessionKey。codex TUI 同一会话同时只挂一个审批,一会话一挂起足够;
    /// 同 key 再来(理论不发生)时旧 fd 直接关闭失效。
    @Published private(set) var pending: [String: Pending] = [:]
    /// key → 断连监视源(hook 进程被杀/超时退出时 fd EOF → 即清 pending,防死条目吃掉应答)
    private var eofSources: [String: DispatchSourceRead] = [:]

    /// 新挂起/应答后回调(app 侧接 CodexSessionMonitor.rescan() 即时刷新会话相)
    var onPendingChanged: (() -> Void)?

    /// REQ-022:会话显示名解析(app 注入,查 CodexSessionMonitor;入参 = rollout uuid)。
    /// 返回 nil 时用 "Codex" 兜底。
    var sessionNameProvider: ((String) -> String?)?
    /// 必须同时已连接、且审批特征值已就绪，设备才可在窗口内处理请求。
    var isDeviceReadyForApproval: (() -> Bool)?
    /// UserPromptSubmit 是真实用户活动信号；由 App 注入以刷新 rollout 会话的排序时间。
    var onUserPromptSubmitted: ((String, String?, String?) -> Void)?

    /// REQ-022 C5:originator 适配 —— server pending key 恒为 "codex-cli:<uuid>"
    /// (hook payload 无 originator),而 CodexSessionMonitor 的会话 id 可能是
    /// "codex-desktop:<uuid>" / "codex-vscode:<uuid>"(originator 实测值
    /// "Codex Desktop" / "codex_work_desktop" / "codex-tui" 归类所得)。
    /// 统一按 uuid 尾段匹配,Desktop/VSCode 会话也能命中 hook 挂起。
    func pendingKey(forSessionId sessionId: String) -> String? {
        guard let uuid = sessionId.split(separator: ":", maxSplits: 1).last.map(String.init),
              !uuid.isEmpty else { return nil }
        if pending["codex-cli:\(uuid)"] != nil { return "codex-cli:\(uuid)" }
        // 防御:未来 key 前缀变化时按尾段兜底
        return pending.keys.first { $0.hasSuffix(":\(uuid)") }
    }

    /// 以 rollout 路径为主键匹配审批。Codex Desktop 续接时 hook 的 session_id
    /// 与 rollout 元数据 UUID 不保证一致；路径才是两端共同携带的稳定身份。
    /// UUID 只为旧 hook（未传 transcript_path）保留兼容回退。
    func pendingKey(sessionId: String, transcriptPath: String?) -> String? {
        if let transcriptPath, !transcriptPath.isEmpty {
            let normalized = Self.normalizePath(transcriptPath)
            if let pathKey = pending.first(where: { _, entry in
                guard let pendingPath = entry.transcriptPath, !pendingPath.isEmpty else { return false }
                return Self.normalizePath(pendingPath) == normalized
            })?.key {
                return pathKey
            }
        }
        return pendingKey(forSessionId: sessionId)
    }

    func pendingEntry(sessionId: String, transcriptPath: String?) -> Pending? {
        pendingKey(sessionId: sessionId, transcriptPath: transcriptPath).flatMap { pending[$0] }
    }

    /// UI 已由 monitor 写入 waitingForApproval 相位；用审批上下文反查应答连接，
    /// 不再从 View 重新按会话身份匹配 pending。
    func pendingKey(for context: PermissionContext) -> String? {
        pending.first { $0.value.context.toolUseId == context.toolUseId }?.key
    }

    /// 所有带 rollout 路径的挂起项都必须被 monitor 纳入候选集，即使其 mtime 超过常规窗口。
    var pendingTranscriptPaths: Set<String> {
        Set(pending.values.compactMap { entry in
            guard let path = entry.transcriptPath, !path.isEmpty else { return nil }
            return Self.normalizePath(path)
        })
    }

    /// pendingKey 适配版的条目查询(CodexSessionMonitor 会话相位映射用)
    func pendingEntry(forSessionId sessionId: String) -> Pending? {
        pendingKey(forSessionId: sessionId).flatMap { pending[$0] }
    }

    private var serverSocket: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private let queue = DispatchQueue(label: "com.vibeeverything.codex-approval", qos: .userInitiated)
    private var pruneTimer: Timer?

    func start() {
        queue.async { [weak self] in self?.startServer() }
        let t = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pruneExpired() }
        }
        RunLoop.main.add(t, forMode: .common)
        pruneTimer = t
    }

    nonisolated private func startServer() {
        unlink(Self.socketPath)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            logger.error("socket() failed errno=\(errno)")
            return
        }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        Self.socketPath.withCString { ptr in
            withUnsafeMutablePointer(to: &addr.sun_path) { pathPtr in
                let buf = UnsafeMutableRawPointer(pathPtr).assumingMemoryBound(to: CChar.self)
                strcpy(buf, ptr)
            }
        }
        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                bind(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0, listen(fd, 8) == 0 else {
            logger.error("bind/listen failed errno=\(errno)")
            close(fd)
            return
        }
        chmod(Self.socketPath, 0o700)

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptOne(server: fd) }
        source.setCancelHandler { close(fd) }
        source.resume()

        Task { @MainActor [weak self] in
            self?.serverSocket = fd
            self?.acceptSource = source
        }
        logger.info("codex approval server listening at \(Self.socketPath, privacy: .public)")
    }

    nonisolated private func acceptOne(server: Int32) {
        let client = accept(server, nil, nil)
        guard client >= 0 else { return }

        // hook 连上后立刻写完整 payload;阻塞读到换行为止(2s 上限)
        var tv = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var buf = Data()
        var chunk = [UInt8](repeating: 0, count: 8192)
        while !buf.contains(0x0A) && buf.count < 256 * 1024 {
            let n = recv(client, &chunk, chunk.count, 0)
            guard n > 0 else { break }
            buf.append(contentsOf: chunk[0..<n])
        }
        guard let nl = buf.firstIndex(of: 0x0A),
              let obj = try? JSONSerialization.jsonObject(with: buf[buf.startIndex..<nl]) as? [String: Any],
              (obj["hook_schema"] as? Int) == 2,
              let uuid = obj["session_id"] as? String, !uuid.isEmpty else {
            logger.warning("invalid approval payload — closing")
            close(client)
            return
        }
        let sessionKey = Self.codexSessionKey(for: uuid)
        Task { @MainActor in
            SessionNavigationService.recordCodexHook(sessionId: sessionKey, payload: obj)
        }

        let event = (obj["event"] as? String) ?? (obj["hook_event_name"] as? String)
        if event == "UserPromptSubmit" {
            let prompt = obj["prompt"] as? String
            let transcriptPath = obj["transcript_path"] as? String
            let turnID = obj["turn_id"] as? String
            if prompt == nil, let keys = obj["payload_keys"] as? [String] {
                logger.info("codex UserPromptSubmit missing prompt keys=\(keys.joined(separator: ","), privacy: .public)")
            }
            close(client)
            Task { @MainActor in
                self.onUserPromptSubmitted?(sessionKey, transcriptPath, turnID)
                InputRouter.handleAgentHookPromptSubmit(sessionId: sessionKey, prompt: prompt)
            }
            return
        }

        var input: [String: AnyCodable] = [:]
        if let toolInput = obj["tool_input"] as? [String: Any] {
            for key in ["command", "description", "justification", "cwd", "path"] {
                guard let v = toolInput[key] else { continue }
                if let arr = v as? [Any] {
                    input[key] = AnyCodable(arr.map { "\($0)" }.joined(separator: " "))
                } else {
                    input[key] = AnyCodable(v)
                }
            }
        }
        let ctx = PermissionContext(
            toolUseId: (obj["turn_id"] as? String) ?? uuid,
            toolName: (obj["tool_name"] as? String) ?? "?",
            toolInput: input.isEmpty ? nil : input,
            receivedAt: Date()
        )
        let key = sessionKey

        Task { @MainActor [weak self] in
            guard let self else { close(client); return }
            if self.pending[key] != nil {
                // 同 key 重复挂起:旧 fd 经 eofSource cancel handler 关闭
                self.eofSources.removeValue(forKey: key)?.cancel()
            }
            self.pending[key] = Pending(sessionKey: key, context: ctx,
                                        transcriptPath: obj["transcript_path"] as? String,
                                        clientSocket: client, receivedAt: Date())
            // hook 进程消亡(被杀/自身超时)→ fd 可读且 read=0(EOF)→ 即清死条目
            let src = DispatchSource.makeReadSource(fileDescriptor: client, queue: self.queue)
            src.setEventHandler { [weak self] in
                var probe = [UInt8](repeating: 0, count: 1)
                let n = recv(client, &probe, 1, Int32(MSG_PEEK))
                if n <= 0 {
                    Task { @MainActor [weak self] in self?.dropDeadPending(key: key) }
                }
            }
            src.setCancelHandler { close(client) }
            src.resume()
            self.eofSources[key] = src
            // hook 收到这条确认后才开始计时；未确认一律 fail-open，不能长时间遮住原生审批。
            let waitSeconds = self.isDeviceReadyForApproval?() == true
                ? Self.deviceOnlineWindowSeconds : Self.deviceOfflineWindowSeconds
            Self.sendJSONLine(["kind": "pending", "wait_seconds": waitSeconds], to: client)
            logger.info("pending approval for \(key.prefix(20), privacy: .public) tool=\(ctx.toolName, privacy: .public)")
            // REQ-022:注册进 ApprovalRegistry → 0x55 推设备(reqId 精确匹配)
            let sessionName = self.sessionNameProvider?(Self.codexSessionUUID(from: uuid)) ?? "Codex"
            ApprovalCoordinator.shared.registerCodex(
                pendingKey: key,
                toolUseId: ctx.toolUseId,
                toolName: ctx.toolName,
                sessionName: sessionName,
                toolInput: ctx.toolInput,
                expiresInSec: UInt16(waitSeconds)
            )
            self.onPendingChanged?()
        }
    }

    /// hook 侧断连:清条目(fd 由 eofSource cancel handler 关)
    private func dropDeadPending(key: String) {
        guard pending[key] != nil else { return }
        pending.removeValue(forKey: key)
        eofSources.removeValue(forKey: key)?.cancel()
        logger.info("pending dropped (hook disconnected) \(key.prefix(20), privacy: .public)")
        // REQ-022:hook EOF(进程被杀/超时退出)→ 0x56(2) 撤销设备条目
        ApprovalCoordinator.shared.resolveCodex(pendingKey: key, reason: .hookEOF)
        onPendingChanged?()
    }

    private nonisolated static func codexSessionKey(for raw: String) -> String {
        raw.hasPrefix("codex-") ? raw : "codex-cli:\(raw)"
    }

    private nonisolated static func codexSessionUUID(from raw: String) -> String {
        raw.split(separator: ":", maxSplits: 1).last.map(String.init) ?? raw
    }

    private nonisolated static func normalizePath(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }

    /// Allow/Deny 应答:写回 hook 并释放挂起(fd 由 eofSource cancel handler 关闭)。
    func respond(sessionKey: String, decision: String, reason: String? = nil) {
        guard let p = pending.removeValue(forKey: sessionKey) else {
            logger.warning("respond: no pending for \(sessionKey.prefix(20), privacy: .public)")
            return
        }
        let fd = p.clientSocket
        let src = eofSources.removeValue(forKey: sessionKey)
        let payload: [String: Any] = reason.map { ["decision": decision, "reason": $0] }
            ?? ["decision": decision]
        queue.async {
            Self.sendJSONLine(payload, to: fd)
            if let src { src.cancel() } else { close(fd) }
        }
        logger.info("responded \(decision, privacy: .public) to \(sessionKey.prefix(20), privacy: .public)")
        // REQ-022:判决已发生(Mac UI 或设备经 Coordinator 转发)→ 通知 Registry 终态化。
        // 设备路径下 Registry 已先终态,此调用为幂等 no-op;Mac UI 路径下触发 0x56(2)。
        ApprovalCoordinator.shared.resolveCodex(pendingKey: sessionKey, reason: .macUI)
        onPendingChanged?()
    }

    /// 不输出 allow/deny，主动关闭 hook 连接，使 Codex 立即进入原生审批。
    /// 仅供 Codex 审批使用；Claude 的 dismiss 保持“只关闭设备卡”原语义。
    func abandon(sessionKey: String) {
        guard let p = pending.removeValue(forKey: sessionKey) else { return }
        let src = eofSources.removeValue(forKey: sessionKey)
        queue.async {
            if let src { src.cancel() } else { close(p.clientSocket) }
        }
        logger.info("abandoned to native Codex approval \(sessionKey.prefix(20), privacy: .public)")
        ApprovalCoordinator.shared.resolveCodex(pendingKey: sessionKey, reason: .macUI)
        onPendingChanged?()
    }

    /// hook 会在 10/60 秒窗口 EOF；这里仅兜底异常/旧 hook 连接。
    private func pruneExpired() {
        let cutoff = Date().addingTimeInterval(-Self.maximumPendingLifetime)
        let expired = pending.filter { $0.value.receivedAt < cutoff }
        guard !expired.isEmpty else { return }
        for (key, _) in expired {
            pending.removeValue(forKey: key)
            eofSources.removeValue(forKey: key)?.cancel()
            logger.info("pruned expired approval \(key.prefix(20), privacy: .public)")
            // REQ-022:server 侧 prune(hook 将 fail-open)→ 0x56(2) 撤销设备条目
            // Registry 也按相同的 10/60s 窗口过期；两者幂等。
            ApprovalCoordinator.shared.resolveCodex(pendingKey: key, reason: .hookEOF)
        }
        onPendingChanged?()
    }

    nonisolated private static func sendJSONLine(_ payload: [String: Any], to fd: Int32) {
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        data.withUnsafeBytes { raw in _ = send(fd, raw.baseAddress, raw.count, 0) }
        _ = "\n".withCString { send(fd, $0, 1, 0) }
    }
}

// MARK: - Hook 安装器

/// 把 quickvibehost-codex-hook.py 装到 ~/.codex/hooks/ 并 merge 进 ~/.codex/hooks.json
/// 的 PermissionRequest(保留 Otty 等已有 handler,幂等)。
///
/// 信任机制:codex 对新 hooks.json 内容要求用户在下一次 TUI 启动时确认信任一次
/// (persisted hook trust);未信任前 hook 不执行,审批卡自动降级为只读(rollout 检测)。
struct CodexHookInstaller {
    private static let scriptName = "quickvibehost-codex-hook.py"

    static func installIfNeeded() {
        guard CodexSessionMonitor.isCLIInstalled else { return }
        let codexDir = CodexSessionMonitor.dataDir
        let hooksDir = codexDir.appendingPathComponent("hooks")
        let script = hooksDir.appendingPathComponent(scriptName)
        let hooksJSON = codexDir.appendingPathComponent("hooks.json")

        try? FileManager.default.createDirectory(at: hooksDir, withIntermediateDirectories: true)

        guard let bundled = Bundle.main.url(forResource: "quickvibehost-codex-hook", withExtension: "py") else {
            logger.error("codex hook script missing from bundle")
            return
        }
        do {
            try Data(contentsOf: bundled).write(to: script, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        } catch {
            logger.error("failed to update codex hook script: \(error.localizedDescription, privacy: .public)")
            return
        }

        mergeHooksJSON(at: hooksJSON, scriptPath: script.path)
    }

    private static func mergeHooksJSON(at url: URL, scriptPath: String) {
        var json: [String: Any] = [:]
        if let data = try? Data(contentsOf: url),
           let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            json = existing
        }
        var hooks = json["hooks"] as? [String: Any] ?? [:]
        var entries = hooks["PermissionRequest"] as? [[String: Any]] ?? []

        var already = false
        for index in entries.indices {
            guard var handlers = entries[index]["hooks"] as? [[String: Any]] else { continue }
            for handlerIndex in handlers.indices where (handlers[handlerIndex]["command"] as? String ?? "").contains(scriptName) {
                // 设备在线窗口 60s，留 10s 进程调度与 socket 收尾余量。
                handlers[handlerIndex]["timeout"] = 70
                already = true
            }
            entries[index]["hooks"] = handlers
        }
        if !already {
            entries.append([
                "hooks": [[
                    "type": "command",
                    "command": "python3 '\(scriptPath)'",
                    "timeout": 70,
                ]]
            ])
        }
        hooks["PermissionRequest"] = entries
        var promptEntries = hooks["UserPromptSubmit"] as? [[String: Any]] ?? []
        let hasPromptHook = promptEntries.contains { entry in
            ((entry["hooks"] as? [[String: Any]]) ?? []).contains {
                ($0["command"] as? String ?? "").contains(scriptName)
            }
        }
        if !hasPromptHook {
            promptEntries.append([
                "hooks": [[
                    "type": "command",
                    "command": "python3 '\(scriptPath)'",
                    "timeout": 1,
                ]]
            ])
        }
        hooks["UserPromptSubmit"] = promptEntries
        json["hooks"] = hooks

        if let data = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: url)
            logger.info("merged PermissionRequest hook into \(url.path, privacy: .public)")
        }
    }
}

// MARK: - Codex Desktop 激活(审批卡「前往处理」)

enum CodexDesktopActivator {
    /// Codex Desktop 的两种宿主:独立 Codex.app,或 ChatGPT.app 内嵌(实测 2026-07-10,
    /// 用户的 desktop codex 进程父进程是 /Applications/ChatGPT.app)
    static let bundleIds = ["com.openai.codex", "com.openai.chat"]

    /// threadId 非空时走 codex://threads/<id> deep link 直达具体会话
    /// (2026-07-23 双会话切换实测:scheme 由 ChatGPT.app 注册,按 threadId 精确路由);
    /// 无 threadId 或 open 失败回落 app 级激活。
    static func bringToFront(threadId: String? = nil) {
        if let tid = threadId, !tid.isEmpty,
           let url = URL(string: "codex://threads/\(tid)"),
           NSWorkspace.shared.open(url) {
            // NSWorkspace.open 只保证 URL 已交给处理程序，并不保证处理程序成为前台。
            // 从设备选择会话时用户同时明确要求“激活应用”，因此 deep link 成功后也要
            // 主动置前；再延迟重试一次，覆盖 Codex 正在恢复窗口/切换 thread 的竞态。
            _ = activateRunningHost()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                _ = activateRunningHost()
            }
            return
        }
        // 优先激活正在运行的宿主
        if activateRunningHost() { return }
        // 都没跑 → 启动装了的那个
        for bid in bundleIds {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bid) {
                NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
                return
            }
        }
    }

    @discardableResult
    private static func activateRunningHost() -> Bool {
        for bid in bundleIds {
            if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bid).first {
                if app.isHidden { app.unhide() }
                // QuickVibeHost 是菜单栏后台应用；只用 activateAllWindows 时，macOS
                // 可能保留当前前台应用。设备确认会话属于明确的用户操作，允许抢前台。
                let activated = app.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
                ClaudeCodeSessionManager.log("[Codex Desktop] activate bundle=\(bid) success=\(activated)")
                if activated { return true }
                // Electron 的自定义主窗口在部分版本里会让公开 API 返回 false。
                // 仅在这个失败分支使用旧版 Process Manager 动态符号兜底；符号不存在
                // 时安静退化，不把已废弃 API 作为编译期依赖。
                let forced = LegacyForegroundActivator.forceFront(pid: app.processIdentifier)
                ClaudeCodeSessionManager.log("[Codex Desktop] force-front bundle=\(bid) success=\(forced)")
                if forced { return true }
            }
        }
        return false
    }
}

/// macOS 10.9 后头文件将 Process Manager 标成 unavailable，但当前系统仍保留 ABI。
/// 这里是 NSRunningApplication 对 Electron 自定义窗口返回 false 时的窄范围兼容层。
private enum LegacyForegroundActivator {
    private struct ProcessSerialNumber {
        var high: UInt32 = 0
        var low: UInt32 = 0
    }

    private typealias GetProcessForPIDFn = @convention(c)
        (pid_t, UnsafeMutableRawPointer) -> Int32
    private typealias SetFrontProcessWithOptionsFn = @convention(c)
        (UnsafeRawPointer, UInt32) -> Int32

    private static let symbols: (GetProcessForPIDFn, SetFrontProcessWithOptionsFn)? = {
        guard let handle = dlopen(
            "/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices",
            RTLD_LAZY
        ),
        let getSymbol = dlsym(handle, "GetProcessForPID"),
        let setSymbol = dlsym(handle, "SetFrontProcessWithOptions") else { return nil }
        return (
            unsafeBitCast(getSymbol, to: GetProcessForPIDFn.self),
            unsafeBitCast(setSymbol, to: SetFrontProcessWithOptionsFn.self)
        )
    }()

    static func forceFront(pid: pid_t) -> Bool {
        guard let (getProcessForPID, setFrontProcess) = symbols else { return false }
        var psn = ProcessSerialNumber()
        let lookupStatus = withUnsafeMutablePointer(to: &psn) {
            getProcessForPID(pid, UnsafeMutableRawPointer($0))
        }
        guard lookupStatus == 0 else { return false }
        // kSetFrontProcessFrontWindowOnly = 1. Avoid importing the unavailable
        // declaration while preserving the stable Carbon ABI value.
        let activationStatus = withUnsafePointer(to: &psn) {
            setFrontProcess(UnsafeRawPointer($0), 1)
        }
        return activationStatus == 0
    }
}

/// Claude Desktop 直达指定 CC 会话。已存在的 Desktop 会话使用内部
/// epitaxy 路由聚焦，避免 claude://resume 重复导入并改写 transcript。
/// 只有未找到 Desktop 映射时才使用 resume 完成首次导入。
enum ClaudeDesktopActivator {
    static let bundleId = "com.anthropic.claudefordesktop"

    static func resume(sessionId: String) {
        // 复制陷阱防护(2026-07-24 实测):claude://resume 对"Desktop 原生会话包裹的
        // cli id"会导入出重复 tab(去重键=local_<cliId>,原生会话 id 独立必 miss)。
        // 先查 Desktop 会话存储映射:已被原生会话包裹 → 只激活 app;
        // 无包裹(headless/-p/终端已死)→ resume 导入(重复调用命中去重键会聚焦,安全)。
        let base = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Claude/claude-code-sessions")
        if let mapping = ClaudeDesktopSessionResolver.mapping(cliSessionId: sessionId, baseURL: base) {
            let encoded = mapping.desktopSessionId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
            if let encoded,
               let url = URL(string: "claude://claude.ai/epitaxy/\(encoded)"),
               NSWorkspace.shared.open(url) {
                return
            }
            // 映射已存在时不得回落到 resume：它可能复制会话并改写源 transcript。
            activateApp()
            return
        }
        if let url = URL(string: "claude://resume?session=\(sessionId)"),
           NSWorkspace.shared.open(url) {
            return
        }
        activateApp()
    }

    private static func activateApp() {
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).first {
            if app.isHidden { app.unhide() }
            app.activate(options: [.activateAllWindows])
        } else if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        }
    }

}

enum CodexVSCodeActivator {
    static let bundleIds = ["com.microsoft.VSCode", "com.microsoft.VSCodeInsiders"]

    static func bringToFront() {
        for bid in bundleIds {
            if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bid).first {
                if app.isHidden { app.unhide() }
                app.activate(options: [.activateAllWindows])
                return
            }
        }
        for bid in bundleIds {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bid) {
                NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
                return
            }
        }
    }
}
