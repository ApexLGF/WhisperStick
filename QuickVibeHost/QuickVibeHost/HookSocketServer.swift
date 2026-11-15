import Foundation
import os.log

private let logger = Logger(subsystem: "com.vibeeverything.QuickVibeHost", category: "HookSocket")

// MARK: - Models

struct HookEvent: Codable, Sendable {
    let hookSchema: Int
    let sessionId: String
    let cwd: String
    let event: String
    let status: String
    let pid: Int?
    let tty: String?
    let tool: String?
    let toolInput: [String: AnyCodable]?
    let toolUseId: String?
    let notificationType: String?
    let message: String?
    let transcriptPath: String?
    let prompt: String?
    let permissionMode: String?
    let agentId: String?
    let agentType: String?
    /// REQ-022 后续批:StopFailure/PostToolUseFailure 的错误短码(如 invalid_request / Exit code 1)
    let error: String?
    let terminalApp: String?
    let terminalSessionId: String?
    let terminalPaneId: String?
    let tmuxTarget: String?

    enum CodingKeys: String, CodingKey {
        case hookSchema = "hook_schema"
        case sessionId = "session_id"
        case cwd, event, status, pid, tty, tool
        case toolInput = "tool_input"
        case toolUseId = "tool_use_id"
        case notificationType = "notification_type"
        case message, prompt
        case transcriptPath = "transcript_path"
        case permissionMode = "permission_mode"
        case agentId = "agent_id"
        case agentType = "agent_type"
        case error
        case terminalApp = "terminal_app"
        case terminalSessionId = "terminal_session_id"
        case terminalPaneId = "terminal_pane_id"
        case tmuxTarget = "tmux_target"
    }

    init(
        hookSchema: Int = 2, sessionId: String, cwd: String, event: String, status: String,
        pid: Int?, tty: String?, tool: String?, toolInput: [String: AnyCodable]?,
        toolUseId: String?, notificationType: String?, message: String?,
        transcriptPath: String? = nil, prompt: String? = nil, permissionMode: String? = nil,
        agentId: String? = nil, agentType: String? = nil, error: String? = nil,
        terminalApp: String? = nil, terminalSessionId: String? = nil,
        terminalPaneId: String? = nil, tmuxTarget: String? = nil
    ) {
        self.hookSchema = hookSchema
        self.sessionId = sessionId
        self.cwd = cwd
        self.event = event
        self.status = status
        self.pid = pid
        self.tty = tty
        self.tool = tool
        self.toolInput = toolInput
        self.toolUseId = toolUseId
        self.notificationType = notificationType
        self.message = message
        self.transcriptPath = transcriptPath
        self.prompt = prompt
        self.permissionMode = permissionMode
        self.agentId = agentId
        self.agentType = agentType
        self.error = error
        self.terminalApp = terminalApp
        self.terminalSessionId = terminalSessionId
        self.terminalPaneId = terminalPaneId
        self.tmuxTarget = tmuxTarget
    }

    var expectsResponse: Bool {
        event == "PermissionRequest" && status == "waiting_for_approval"
    }
}

struct HookResponse: Codable {
    let decision: String
    let reason: String?
    /// REQ-022 C2:always_allow 时透传给 hook 脚本的会话级规则
    /// (vibepanel-hook.py 把它并进 hookSpecificOutput.decision.updatedPermissions)
    var updatedPermissions: [PermissionRuleUpdate]? = nil
}

struct PendingPermission: Sendable {
    let sessionId: String
    let toolUseId: String
    let clientSocket: Int32
    let event: HookEvent
    let receivedAt: Date
}

// MARK: - Socket Server

class HookSocketServer {
    static let shared = HookSocketServer()
    static let socketPath = "/tmp/vibepanel-claude.sock"

    private var serverSocket: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var eventHandler: (@Sendable (HookEvent) -> Void)?
    private let queue = DispatchQueue(label: "com.vibeeverything.socket", qos: .userInitiated)

    private var pendingPermissions: [String: PendingPermission] = [:]
    private let permissionsLock = NSLock()

    /// Cache tool_use_id from PreToolUse → PermissionRequest correlation
    /// Key: "sessionId:toolName:serializedInput" → FIFO queue of tool_use_ids
    private var toolUseIdCache: [String: [String]] = [:]
    private let cacheLock = NSLock()

    private init() {}

    func start(onEvent: @escaping @Sendable (HookEvent) -> Void) {
        queue.async { [weak self] in
            self?.startServer(onEvent: onEvent)
        }
    }

    private func startServer(onEvent: @escaping @Sendable (HookEvent) -> Void) {
        guard serverSocket < 0 else { return }
        eventHandler = onEvent

        unlink(Self.socketPath)

        serverSocket = socket(AF_UNIX, SOCK_STREAM, 0)
        guard serverSocket >= 0 else {
            logger.error("Failed to create socket: \(errno)")
            return
        }

        let flags = fcntl(serverSocket, F_GETFL)
        _ = fcntl(serverSocket, F_SETFL, flags | O_NONBLOCK)

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        Self.socketPath.withCString { ptr in
            withUnsafeMutablePointer(to: &addr.sun_path) { pathPtr in
                let buf = UnsafeMutableRawPointer(pathPtr).assumingMemoryBound(to: CChar.self)
                strcpy(buf, ptr)
            }
        }

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                bind(serverSocket, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }

        guard bindResult == 0 else {
            logger.error("Failed to bind: \(errno)")
            close(serverSocket)
            serverSocket = -1
            return
        }

        chmod(Self.socketPath, 0o700)

        guard listen(serverSocket, 10) == 0 else {
            logger.error("Failed to listen: \(errno)")
            close(serverSocket)
            serverSocket = -1
            return
        }

        logger.info("Listening on \(Self.socketPath, privacy: .public)")

        acceptSource = DispatchSource.makeReadSource(fileDescriptor: serverSocket, queue: queue)
        acceptSource?.setEventHandler { [weak self] in self?.acceptConnection() }
        acceptSource?.setCancelHandler { [weak self] in
            if let fd = self?.serverSocket, fd >= 0 {
                close(fd)
                self?.serverSocket = -1
            }
        }
        acceptSource?.resume()
    }

    /// Check if socket is healthy; restart if socket file missing or server not listening
    func ensureRunning() {
        queue.async { [weak self] in
            guard let self, let handler = self.eventHandler else { return }
            let socketExists = FileManager.default.fileExists(atPath: Self.socketPath)
            let serverAlive = self.serverSocket >= 0 && self.acceptSource != nil

            if !socketExists || !serverAlive {
                logger.warning("Socket health check failed: exists=\(socketExists) alive=\(serverAlive) — restarting")
                ClaudeCodeSessionManager.log("[Socket] Health check failed, restarting server")
                // Clean up old state
                self.acceptSource?.cancel()
                self.acceptSource = nil
                if self.serverSocket >= 0 {
                    close(self.serverSocket)
                    self.serverSocket = -1
                }
                // Restart
                self.startServer(onEvent: handler)
            }
        }
    }

    func stop() {
        acceptSource?.cancel()
        acceptSource = nil
        unlink(Self.socketPath)

        permissionsLock.lock()
        for (_, pending) in pendingPermissions { close(pending.clientSocket) }
        pendingPermissions.removeAll()
        permissionsLock.unlock()
    }

    // MARK: - Permission Response

    func respondToPermission(toolUseId: String, decision: String, reason: String? = nil,
                             updatedPermissions: [PermissionRuleUpdate]? = nil) {
        queue.async { [weak self] in
            self?.sendResponse(toolUseId: toolUseId, decision: decision, reason: reason,
                               updatedPermissions: updatedPermissions)
        }
    }

    /// Remove the oldest pending permission for a session and send the response.
    /// Removal is synchronous (so callers can immediately check pendingPermissionCount),
    /// socket write is dispatched async (to avoid blocking MainActor).
    /// - Returns: 实际应答的 toolUseId(无挂起时 nil)。REQ-022:调用方用它通知
    ///   ApprovalCoordinator.resolveClaude(reqId 精确撤销 → 0x56 下发)。
    @discardableResult
    func respondToPermissionBySession(sessionId: String, decision: String, reason: String? = nil) -> String? {
        // Step 1: Synchronously remove from pendingPermissions
        permissionsLock.lock()
        let allForSession = pendingPermissions.values.filter { $0.sessionId == sessionId }
        let match = allForSession.sorted { $0.receivedAt < $1.receivedAt }.first
        if let pending = match {
            pendingPermissions.removeValue(forKey: pending.toolUseId)
        }
        let totalPending = pendingPermissions.count
        permissionsLock.unlock()

        guard let pending = match else {
            ClaudeCodeSessionManager.log("[Socket] ⚠️ No pending permission found for session \(sessionId.prefix(8))!")
            logger.warning("No pending permission for session \(sessionId.prefix(8), privacy: .public)")
            return nil
        }

        ClaudeCodeSessionManager.log("[Socket] respondToPermissionBySession: session=\(sessionId.prefix(8)) decision=\(decision) toolUseId=\(pending.toolUseId.prefix(12)) remainingTotal=\(totalPending)")

        // Step 2: Async send response via socket (non-blocking)
        queue.async { [weak self] in
            self?.sendResponseToSocket(pending: pending, decision: decision, reason: reason)
        }
        return pending.toolUseId
    }

    func cancelPendingPermissions(sessionId: String) {
        queue.async { [weak self] in
            self?.permissionsLock.lock()
            let matching = self?.pendingPermissions.filter { $0.value.sessionId == sessionId } ?? [:]
            for (id, pending) in matching {
                close(pending.clientSocket)
                self?.pendingPermissions.removeValue(forKey: id)
            }
            self?.permissionsLock.unlock()
        }
    }

    func cancelPendingPermission(toolUseId: String) {
        queue.async { [weak self] in
            self?.permissionsLock.lock()
            if let pending = self?.pendingPermissions.removeValue(forKey: toolUseId) {
                close(pending.clientSocket)
            }
            self?.permissionsLock.unlock()
        }
    }

    func hasPendingPermission(sessionId: String) -> Bool {
        permissionsLock.lock()
        defer { permissionsLock.unlock() }
        return pendingPermissions.values.contains { $0.sessionId == sessionId }
    }

    // MARK: - Tool Use ID Cache

    private static let sortedEncoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = .sortedKeys
        return e
    }()

    private func cacheKey(sessionId: String, toolName: String?, toolInput: [String: AnyCodable]?) -> String {
        let inputStr: String
        if let input = toolInput,
           let data = try? Self.sortedEncoder.encode(input),
           let str = String(data: data, encoding: .utf8) {
            inputStr = str
        } else {
            inputStr = "{}"
        }
        return "\(sessionId):\(toolName ?? "unknown"):\(inputStr)"
    }

    private func cacheToolUseId(event: HookEvent) {
        guard let toolUseId = event.toolUseId else { return }
        let key = cacheKey(sessionId: event.sessionId, toolName: event.tool, toolInput: event.toolInput)
        cacheLock.lock()
        toolUseIdCache[key, default: []].append(toolUseId)
        cacheLock.unlock()
        logger.debug("Cached tool_use_id \(toolUseId.prefix(12), privacy: .public) for \(event.tool ?? "?", privacy: .public)")
    }

    private func popCachedToolUseId(event: HookEvent) -> String? {
        let key = cacheKey(sessionId: event.sessionId, toolName: event.tool, toolInput: event.toolInput)
        cacheLock.lock()
        defer { cacheLock.unlock() }
        guard var queue = toolUseIdCache[key], !queue.isEmpty else { return nil }
        let id = queue.removeFirst()
        if queue.isEmpty { toolUseIdCache.removeValue(forKey: key) } else { toolUseIdCache[key] = queue }
        return id
    }

    private func cleanupCache(sessionId: String) {
        cacheLock.lock()
        let keys = toolUseIdCache.keys.filter { $0.hasPrefix("\(sessionId):") }
        for key in keys { toolUseIdCache.removeValue(forKey: key) }
        cacheLock.unlock()
    }

    // MARK: - Connection Handling

    private func acceptConnection() {
        let clientSocket = accept(serverSocket, nil, nil)
        guard clientSocket >= 0 else { return }
        var nosigpipe: Int32 = 1
        setsockopt(clientSocket, SOL_SOCKET, SO_NOSIGPIPE, &nosigpipe, socklen_t(MemoryLayout<Int32>.size))
        handleClient(clientSocket)
    }

    private func handleClient(_ clientSocket: Int32) {
        let flags = fcntl(clientSocket, F_GETFL)
        _ = fcntl(clientSocket, F_SETFL, flags | O_NONBLOCK)

        var allData = Data()
        var buffer = [UInt8](repeating: 0, count: 131072)
        var pollFd = pollfd(fd: clientSocket, events: Int16(POLLIN), revents: 0)

        let startTime = Date()
        while Date().timeIntervalSince(startTime) < 0.5 {
            let result = poll(&pollFd, 1, 50)
            if result > 0 && (pollFd.revents & Int16(POLLIN)) != 0 {
                let n = read(clientSocket, &buffer, buffer.count)
                if n > 0 { allData.append(contentsOf: buffer[0..<n]) }
                else if n == 0 { break }
                else if errno != EAGAIN && errno != EWOULDBLOCK { break }
            } else if result == 0 {
                if !allData.isEmpty { break }
            } else { break }
        }

        guard !allData.isEmpty else { close(clientSocket); return }

        guard let event = try? JSONDecoder().decode(HookEvent.self, from: allData) else {
            logger.warning("Failed to parse event")
            close(clientSocket)
            return
        }
        guard event.hookSchema == 2 else {
            logger.warning("Rejecting stale hook schema \(event.hookSchema)")
            close(clientSocket)
            return
        }

        logger.debug("Event: \(event.event, privacy: .public) session:\(event.sessionId.prefix(8), privacy: .public)")

        if event.event == "PreToolUse" { cacheToolUseId(event: event) }
        if event.event == "SessionEnd" { cleanupCache(sessionId: event.sessionId) }

        if event.expectsResponse {
            let toolUseId = event.toolUseId ?? popCachedToolUseId(event: event) ?? ""
            ClaudeCodeSessionManager.log("[Socket] PermissionRequest received: session=\(event.sessionId.prefix(8)) tool=\(event.tool ?? "?") toolUseId=\(toolUseId.prefix(12)) fromEvent=\(event.toolUseId != nil)")

            if toolUseId.isEmpty {
                ClaudeCodeSessionManager.log("[Socket] ⚠️ Empty toolUseId — dropping permission request")
                logger.warning("Permission request missing tool_use_id, session=\(event.sessionId.prefix(8), privacy: .public) — not showing in UI")
                close(clientSocket)
                return
            }

            let updated = HookEvent(
                hookSchema: event.hookSchema,
                sessionId: event.sessionId, cwd: event.cwd, event: event.event,
                status: event.status, pid: event.pid, tty: event.tty,
                tool: event.tool, toolInput: event.toolInput, toolUseId: toolUseId,
                notificationType: event.notificationType, message: event.message,
                transcriptPath: event.transcriptPath, prompt: event.prompt, permissionMode: event.permissionMode,
                agentId: event.agentId, agentType: event.agentType,
                terminalApp: event.terminalApp, terminalSessionId: event.terminalSessionId,
                terminalPaneId: event.terminalPaneId, tmuxTarget: event.tmuxTarget
            )

            let pending = PendingPermission(
                sessionId: event.sessionId, toolUseId: toolUseId,
                clientSocket: clientSocket, event: updated, receivedAt: Date()
            )
            permissionsLock.lock()
            pendingPermissions[toolUseId] = pending
            let totalPending = pendingPermissions.count
            permissionsLock.unlock()

            ClaudeCodeSessionManager.log("[Socket] PendingPermission created: toolUseId=\(toolUseId.prefix(12)) fd=\(clientSocket) totalPending=\(totalPending)")
            eventHandler?(updated)
            return
        }

        close(clientSocket)
        eventHandler?(event)
    }

    // MARK: - Send Response

    private func sendResponse(toolUseId: String, decision: String, reason: String?,
                              updatedPermissions: [PermissionRuleUpdate]? = nil) {
        permissionsLock.lock()
        guard let pending = pendingPermissions.removeValue(forKey: toolUseId) else {
            permissionsLock.unlock()
            return
        }
        permissionsLock.unlock()

        let response = HookResponse(decision: decision, reason: reason,
                                    updatedPermissions: updatedPermissions)
        guard let data = try? JSONEncoder().encode(response) else {
            close(pending.clientSocket)
            return
        }

        logger.info("Response: \(decision, privacy: .public) for \(pending.sessionId.prefix(8), privacy: .public)")

        data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            _ = write(pending.clientSocket, base, data.count)
        }
        close(pending.clientSocket)
    }

    /// Send response to a previously removed pending permission via socket.
    /// Called on the socket queue — does not touch pendingPermissions.
    private func sendResponseToSocket(pending: PendingPermission, decision: String, reason: String?) {
        let response = HookResponse(decision: decision, reason: reason)
        guard let data = try? JSONEncoder().encode(response) else {
            ClaudeCodeSessionManager.log("[Socket] ⚠️ Failed to encode response JSON")
            close(pending.clientSocket)
            return
        }

        ClaudeCodeSessionManager.log("[Socket] Sending \(decision) to fd=\(pending.clientSocket) toolUseId=\(pending.toolUseId.prefix(12))")

        // Check socket is still valid before writing
        var error: Int32 = 0
        var errorLen = socklen_t(MemoryLayout<Int32>.size)
        let sockOK = getsockopt(pending.clientSocket, SOL_SOCKET, SO_ERROR, &error, &errorLen) == 0 && error == 0

        if sockOK {
            var written: Int = 0
            data.withUnsafeBytes { bytes in
                guard let base = bytes.baseAddress else { return }
                written = write(pending.clientSocket, base, data.count)
            }
            ClaudeCodeSessionManager.log("[Socket] ✅ Written \(written) bytes to fd=\(pending.clientSocket)")
        } else {
            ClaudeCodeSessionManager.log("[Socket] ❌ Socket invalid (error=\(error)) for fd=\(pending.clientSocket), skipping write")
            logger.warning("Socket invalid for toolUseId \(pending.toolUseId.prefix(12), privacy: .public), skipping write")
        }
        close(pending.clientSocket)
    }

    /// Get the count of pending permissions for a session
    func pendingPermissionCount(sessionId: String) -> Int {
        permissionsLock.lock()
        defer { permissionsLock.unlock() }
        return pendingPermissions.values.filter { $0.sessionId == sessionId }.count
    }

    /// Get the oldest pending permission event for a session (for display)
    func oldestPendingPermission(sessionId: String) -> HookEvent? {
        permissionsLock.lock()
        defer { permissionsLock.unlock() }
        return pendingPermissions.values
            .filter { $0.sessionId == sessionId }
            .sorted { $0.receivedAt < $1.receivedAt }
            .first?.event
    }

    /// Prune permissions whose sockets have timed out (hook.py timeout = 300s)
    func pruneExpiredPermissions() -> [String] {
        let timeout: TimeInterval = 290
        let now = Date()
        permissionsLock.lock()
        var expiredSessionIds: [String] = []
        for (id, pending) in pendingPermissions where now.timeIntervalSince(pending.receivedAt) > timeout {
            close(pending.clientSocket)
            pendingPermissions.removeValue(forKey: id)
            expiredSessionIds.append(pending.sessionId)
            logger.warning("Pruned expired permission: \(id.prefix(12), privacy: .public)")
        }
        permissionsLock.unlock()
        return expiredSessionIds
    }
}

// MARK: - AnyCodable

struct AnyCodable: Codable, @unchecked Sendable {
    nonisolated(unsafe) let value: Any

    init(_ value: Any) { self.value = value }

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { value = NSNull() }
        else if let v = try? c.decode(Bool.self) { value = v }
        else if let v = try? c.decode(Int.self) { value = v }
        else if let v = try? c.decode(Double.self) { value = v }
        else if let v = try? c.decode(String.self) { value = v }
        else if let v = try? c.decode([AnyCodable].self) { value = v.map { $0.value } }
        else if let v = try? c.decode([String: AnyCodable].self) { value = v.mapValues { $0.value } }
        else { throw DecodingError.dataCorruptedError(in: c, debugDescription: "Cannot decode") }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch value {
        case is NSNull: try c.encodeNil()
        case let v as Bool: try c.encode(v)
        case let v as Int: try c.encode(v)
        case let v as Double: try c.encode(v)
        case let v as String: try c.encode(v)
        case let v as [Any]: try c.encode(v.map { AnyCodable($0) })
        case let v as [String: Any]: try c.encode(v.mapValues { AnyCodable($0) })
        default: throw EncodingError.invalidValue(value, .init(codingPath: [], debugDescription: "Cannot encode"))
        }
    }
}
