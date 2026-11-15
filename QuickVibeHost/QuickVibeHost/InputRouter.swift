import Foundation
import os

/// Routes ASR-produced text to either the keyboard simulator (free mode) or
/// a PTY writer targeting a specific claude session (exclusive mode).
///
/// Step 3 behavior:
/// - free: `KeyboardSimulator.typeText` (unchanged).
/// - exclusive: try `PTYInjector.inject` → on `.success`, done. On `.denied`:
///   clear selection if the reason is terminal (ended/reused), toast the
///   reason, then fall back to free with just-in-time activation so the user
///   still gets their text somewhere visible.
///
/// PTY injection writes to `session.tty` directly and does not depend on
/// frontmost-app focus, which is what breaks KeyboardSimulator for Ghostty
/// same-app multi-tab, iTerm2 multi-window, background Spaces, etc.
enum InputRouter {
    private static let logger = Logger(subsystem: "com.vibeeverything.QuickVibeHost", category: "InputRouter")

    private struct VibeptyRecognitionPending {
        var sid: String
        var pid: Int
        var transcriptPath: String
        var transcriptSizeBefore: UInt64
        var segments: [RecognitionBoostSegment]
        var createdAt: Date
    }

    private struct AgentHookRecognitionPending {
        let id: UUID
        let sessionId: String
        let target: AgentHookTarget
        var segments: [RecognitionBoostSegment]
        let createdAt: Date
    }

    private struct FreeASRRecognitionPending {
        let id: UUID
        var segments: [RecognitionBoostSegment]
        let createdAt: Date
    }

    private struct FreeASRRecognitionMatch {
        var pending: FreeASRRecognitionPending
        var score: Double
        var mode: String
        var pairs: Int
    }

    private enum AgentHookTarget {
        case codex
        case claudeCode
    }

    static let selectedSessionIdKey = "exclusiveSelectedSessionId"

    /// Resolves a session id to a `HookSession` snapshot. Set once from the
    /// app entry point. Nil resolver forces exclusive → free-with-warning.
    nonisolated(unsafe) static var sessionResolver: ((String) -> HookSession?)?
    /// Resolves the most active session for free-mode ASR project hotwords.
    nonisolated(unsafe) static var activeSessionResolver: (() -> HookSession?)?
    /// Brings the host App of a session to the front (Step 2 AppleScript +
    /// NSRunningApplication path). Used for free-fallback JIT activation.
    nonisolated(unsafe) static var activator: ((HookSession) -> Void)?
    /// Clears the persisted exclusive selection. Invoked when a fallback
    /// reason says the target is permanently unusable (`sessionEnded` /
    /// `ttyReused`).
    nonisolated(unsafe) static var clearSelection: (() -> Void)?
    /// Presents the fallback reason to the user (toast / log). Swift-UI
    /// banner lands in M6; for Step 3 this can be a logger shim.
    nonisolated(unsafe) static var toast: ((FallbackReason) -> Void)?
    nonisolated(unsafe) private static var pendingVibeptyRevision: VibeptyRecognitionPending?
    nonisolated(unsafe) private static var pendingAgentHookRevisions: [String: AgentHookRecognitionPending] = [:]
    nonisolated(unsafe) private static var recentFreeASRRevisions: [FreeASRRecognitionPending] = []
    nonisolated(unsafe) private static var recentAgentHookDedupe: [String: Date] = [:]
    private static let freeASRRevisionTTL: TimeInterval = 120
    private static let freeASRMergeWindow: TimeInterval = 30
    private static let freeASRPendingLimit = 5
    private static let freeASRMinCharacters = 6
    private static let freeASRMatchThreshold = 0.70
    private static let freeASRMatchMargin = 0.08

    private enum VibeptySubmitEnterOutcome {
        case handled
        case fallback
    }

    static func currentMode() -> InputRoutingMode {
        // REQ-013 ②改:直通开关移除,恒可用——模式仅由"是否选中会话"决定:
        // 选中 = 直通;未选 = 自由。
        let rawSid = UserDefaults.standard.string(forKey: selectedSessionIdKey) ?? ""
        guard !rawSid.isEmpty else {
            return .free
        }
        return .exclusive(sessionId: rawSid)
    }

    /// Snapshot of the two UserDefaults keys that drive mode routing. Logged
    /// next to every `route` / `routeControl` entry so we can diagnose cases
    /// where `currentMode()` and the rest of the call read UD at slightly
    /// different times (rare but observed in mode-free-vs-UI-exclusive reports).
    private static func userDefaultsModeSnapshot() -> String {
        let sid = UserDefaults.standard.string(forKey: selectedSessionIdKey) ?? ""
        let sidPart = sid.isEmpty ? "<empty>" : String(sid.prefix(8))
        return "udSid=\(sidPart)"
    }

    /// Route recognized text. Blocking call on the caller's queue;
    /// KeyboardSimulator handles its own thread safety.
    static func route(text: String, source: InputSource) {
        guard !text.isEmpty else { return }
        let mode = currentMode()
        let udSnap = userDefaultsModeSnapshot()
        logger.info("route source=\(source.rawValue, privacy: .public) mode=\(mode.debugDescription, privacy: .public) chars=\(text.count) \(udSnap, privacy: .public)")

        switch mode {
        case .free:
            KeyboardSimulator.typeText(text)
            AnalyticsClient.shared.captureInjectionResult(
                inputMode: "free",
                targetKind: "other",
                result: KeyboardSimulator.hasAccessibilityPermission ? "success" : "failure",
                errorKind: KeyboardSimulator.hasAccessibilityPermission ? "none" : "permission_denied",
                textLength: text.count,
                source: source.rawValue
            )
        case .exclusive(let sid):
            injectOrFallback(text: text, sid: sid)
        }
    }

    static func routeASRText(_ text: String, learningText: String? = nil, source: InputSource) {
        guard !text.isEmpty else { return }
        let learningText = learningText ?? text
        let mode = currentMode()
        let udSnap = userDefaultsModeSnapshot()
        logger.info("routeASR source=\(source.rawValue, privacy: .public) mode=\(mode.debugDescription, privacy: .public) chars=\(text.count) \(udSnap, privacy: .public)")

        switch mode {
        case .free:
            if (source == .bleButtonA || source == .hotkey), RecognitionBoostSettings.enabled {
                appendFreeASRRecognitionSegment(learningText)
            }
            KeyboardSimulator.typeText(text)
            AnalyticsClient.shared.captureInjectionResult(
                inputMode: "free",
                targetKind: "other",
                result: KeyboardSimulator.hasAccessibilityPermission ? "success" : "failure",
                errorKind: KeyboardSimulator.hasAccessibilityPermission ? "none" : "permission_denied",
                textLength: text.count,
                source: "asr"
            )
        case .exclusive(let sid):
            injectASROrFallback(text: text, learningText: learningText, sid: sid, source: source)
        }
    }

    /// Route user-authored prompt text. Exclusive sessions keep the PTY path;
    /// free/fallback paths use paste semantics so multi-line prompts survive.
    static func routePromptText(_ text: String, source: InputSource) {
        guard !text.isEmpty else { return }
        let mode = currentMode()
        let udSnap = userDefaultsModeSnapshot()
        logger.info("routePrompt source=\(source.rawValue, privacy: .public) mode=\(mode.debugDescription, privacy: .public) chars=\(text.count) \(udSnap, privacy: .public)")

        switch mode {
        case .free:
            KeyboardSimulator.typePromptText(text)
        case .exclusive(let sid):
            injectPromptOrFallback(text: text, sid: sid)
        }
    }

    /// Route a control key (Enter / ESC×2 from BLE short-press) to the
    /// selected exclusive session via PTY, or fall back to keyboard simulation
    /// in free mode / on PTY failure. Unlike text routing, we don't drop on
    /// `.waitingForApproval` — Enter/ESC are precisely the meaningful actions
    /// there.
    static func routeControl(_ key: ControlKey, source: InputSource) {
        let mode = currentMode()
        let udSnap = userDefaultsModeSnapshot()
        logger.info("routeControl key=\(key.logName, privacy: .public) source=\(source.rawValue, privacy: .public) mode=\(mode.debugDescription, privacy: .public) \(udSnap, privacy: .public)")

        switch mode {
        case .free:
            key.simulateKeyboard()
        case .exclusive(let sid):
            injectControlOrFallback(key: key, sid: sid)
        }
    }

    private static func injectControlOrFallback(key: ControlKey, sid: String) {
        guard let session = resolveSession(sid: sid) else {
            logger.warning("control sid=\(sid.prefix(8), privacy: .public) not in store — keyboard fallback")
            runOnMain { toast?(.sessionInvalid) }
            key.simulateKeyboard()
            return
        }

        if key == .enter {
            switch submitVibeptyRecognitionRevisionAndEnter(session: session, sid: sid) {
            case .handled:
                logger.info("control transcript submit ok sid=\(sid.prefix(8), privacy: .public) key=\(key.logName, privacy: .public)")
                ClaudeCodeSessionManager.log("[Router] control transcript submit ok sid=\(sid.prefix(8)) key=\(key.logName)")
                return
            case .fallback:
                break
            }
        }

        let outcome = PTYInjector.injectControl(bytes: key.payload, session: session, label: key.logName)
        switch outcome {
        case .success:
            logger.info("control inject ok sid=\(sid.prefix(8), privacy: .public) key=\(key.logName, privacy: .public)")
            ClaudeCodeSessionManager.log("[Router] control inject ok sid=\(sid.prefix(8)) key=\(key.logName)")
        case .denied(let reason):
            logger.warning("control inject denied sid=\(sid.prefix(8), privacy: .public) key=\(key.logName, privacy: .public) reason=\(reason.logDescription, privacy: .public) — keyboard fallback")
            ClaudeCodeSessionManager.log("[Router] control inject denied sid=\(sid.prefix(8)) key=\(key.logName) reason=\(reason.logDescription) clear=\(reason.shouldClearSelection)")
            runOnMain {
                toast?(reason)
                if reason.shouldClearSelection { clearSelection?() }
            }
            // Control keys always have a safe keyboard fallback — Enter/ESC
            // landing on the user's current focus is the same behavior as
            // free mode, and the toast tells the user the target was lost.
            key.simulateKeyboard()
        }
    }

    private static func injectASROrFallback(text: String, learningText: String, sid: String, source: InputSource) {
        let canLearn = (source == .bleButtonA || source == .hotkey) && RecognitionBoostSettings.enabled
        guard let session = resolveSession(sid: sid) else {
            logger.warning("asr exclusive sid=\(sid.prefix(8), privacy: .public) not in store — fallback free+JIT")
            AnalyticsClient.shared.captureInjectionResult(
                inputMode: "exclusive",
                targetKind: AnalyticsSupport.targetKind(sessionId: sid),
                result: KeyboardSimulator.hasAccessibilityPermission ? "success" : "failure",
                errorKind: KeyboardSimulator.hasAccessibilityPermission ? "none" : "permission_denied",
                fallbackUsed: "keyboard",
                textLength: text.count,
                source: "asr"
            )
            fallbackToFree(text: text, sid: sid, reason: .sessionInvalid, clear: false, recordFreeASR: canLearn, learningText: learningText)
            return
        }

        if canLearn {
            prepareAgentHookRecognitionPending(session: session, sid: sid)
            prepareVibeptyRecognitionRevision(session: session, sid: sid)
        }

        let outcome = canLearn
            ? PTYInjector.injectASRSpan(text: text, session: session)
            : {
                switch PTYInjector.inject(text: text, session: session) {
                case .success: return PTYInjector.ASROutcome.success(spanId: nil)
                case .denied(let reason): return PTYInjector.ASROutcome.denied(reason)
                }
            }()

        switch outcome {
        case .success(let spanId):
            if canLearn {
                appendAgentHookRecognitionSegment(learningText, sid: sid)
                appendVibeptyRecognitionSegment(learningText, session: session, sid: sid, spanId: spanId)
            }
            logger.info("asr exclusive inject ok sid=\(sid.prefix(8), privacy: .public) chars=\(text.count)")
            ClaudeCodeSessionManager.log("[Router] asr exclusive inject ok sid=\(sid.prefix(8)) chars=\(text.count)")
            AnalyticsClient.shared.captureInjectionResult(
                inputMode: "exclusive",
                targetKind: AnalyticsSupport.targetKind(sessionId: sid),
                result: "success",
                errorKind: "none",
                textLength: text.count,
                source: "asr"
            )
        case .denied(let reason):
            if canLearn {
                pendingAgentHookRevisions.removeValue(forKey: sid)
                pendingVibeptyRevision = nil
            }
            logger.warning("asr exclusive inject denied sid=\(sid.prefix(8), privacy: .public) reason=\(reason.logDescription, privacy: .public) — fallback free+JIT")
            ClaudeCodeSessionManager.log("[Router] asr exclusive inject denied sid=\(sid.prefix(8)) reason=\(reason.logDescription) clear=\(reason.shouldClearSelection)")
            let fallbackOk = reason.shouldFallbackToFreeTyping && KeyboardSimulator.hasAccessibilityPermission
            AnalyticsClient.shared.captureInjectionResult(
                inputMode: "exclusive",
                targetKind: AnalyticsSupport.targetKind(sessionId: sid),
                result: fallbackOk ? "success" : "failure",
                errorKind: fallbackOk ? "none" : "injection_denied",
                fallbackUsed: reason.shouldFallbackToFreeTyping ? "keyboard" : "none",
                textLength: text.count,
                source: "asr"
            )
            fallbackToFree(text: text, sid: sid, reason: reason, clear: reason.shouldClearSelection, recordFreeASR: canLearn, learningText: learningText)
        }
    }

    private static func prepareVibeptyRecognitionRevision(session: HookSession, sid: String) {
        guard let pid = session.pid else {
            ClaudeCodeSessionManager.log("[RecognitionBoost] transcript pending skipped reason=no-pid sid=\(sid.prefix(8))")
            return
        }
        guard let transcriptPath = recognitionTranscriptPath(for: session), !transcriptPath.isEmpty else {
            ClaudeCodeSessionManager.log("[RecognitionBoost] transcript pending skipped reason=no-transcript sid=\(sid.prefix(8)) pid=\(pid)")
            return
        }
        let snapshot: VibeptyClient.VibeptyLineSnapshot
        do {
            snapshot = try VibeptyClient.snapshotLine(pid: pid)
        } catch {
            ClaudeCodeSessionManager.log("[RecognitionBoost] transcript pending skipped reason=snapshot-failed sid=\(sid.prefix(8)) pid=\(pid) error=\(error.localizedDescription)")
            return
        }
        expireVibeptyRecognitionRevision()
        if let pending = pendingVibeptyRevision,
           pending.sid == sid,
           pending.pid == pid,
           pending.transcriptPath == transcriptPath {
            if transcriptAlreadyHasPrompt(path: pending.transcriptPath, offset: pending.transcriptSizeBefore) {
                ClaudeCodeSessionManager.log("[RecognitionBoost] transcript pending dropped reason=stale-before-reuse sid=\(sid.prefix(8)) pid=\(pid)")
                pendingVibeptyRevision = nil
            } else {
                ClaudeCodeSessionManager.log("[RecognitionBoost] transcript pending reuse sid=\(sid.prefix(8)) pid=\(pid) segments=\(pending.segments.count)")
                return
            }
        }
        guard snapshot.line.isEmpty else {
            ClaudeCodeSessionManager.log("[RecognitionBoost] transcript pending skipped reason=line-not-empty sid=\(sid.prefix(8)) pid=\(pid) chars=\(snapshot.line.count)")
            return
        }
        let size = transcriptFileSize(path: transcriptPath)
        pendingVibeptyRevision = .init(
            sid: sid,
            pid: pid,
            transcriptPath: transcriptPath,
            transcriptSizeBefore: size,
            segments: [],
            createdAt: Date()
        )
        ClaudeCodeSessionManager.log("[RecognitionBoost] transcript pending created sid=\(sid.prefix(8)) pid=\(pid) size=\(size)")
    }

    private static func appendFreeASRRecognitionSegment(_ text: String) {
        expireAgentHookRecognitionRevisions()
        let now = Date()
        if var pending = recentFreeASRRevisions.last,
           now.timeIntervalSince(pending.createdAt) <= freeASRMergeWindow {
            pending.segments.append(.init(id: UUID(), asrText: text, createdAt: now))
            recentFreeASRRevisions[recentFreeASRRevisions.count - 1] = pending
            trimFreeASRRevisions()
            ClaudeCodeSessionManager.log("[RecognitionBoost] free pending append segments=\(pending.segments.count)")
            return
        }
        recentFreeASRRevisions.append(.init(
            id: UUID(),
            segments: [.init(id: UUID(), asrText: text, createdAt: now)],
            createdAt: now
        ))
        trimFreeASRRevisions()
        ClaudeCodeSessionManager.log("[RecognitionBoost] free pending created")
    }

    private static func prepareAgentHookRecognitionPending(session: HookSession, sid: String) {
        guard let target = agentHookTarget(for: session) else {
            ClaudeCodeSessionManager.log("[RecognitionBoost] hook pending skipped reason=unsupported-surface sid=\(sid.prefix(8))")
            return
        }
        expireAgentHookRecognitionRevisions()
        if pendingAgentHookRevisions[sid] != nil {
            ClaudeCodeSessionManager.log("[RecognitionBoost] hook pending reuse sid=\(sid.prefix(8))")
            return
        }
        pendingAgentHookRevisions[sid] = .init(
            id: UUID(),
            sessionId: sid,
            target: target,
            segments: [],
            createdAt: Date()
        )
        ClaudeCodeSessionManager.log("[RecognitionBoost] hook pending created sid=\(sid.prefix(8))")
    }

    private static func appendAgentHookRecognitionSegment(_ text: String, sid: String) {
        guard var pending = pendingAgentHookRevisions[sid] else {
            ClaudeCodeSessionManager.log("[RecognitionBoost] hook segment skipped reason=no-pending sid=\(sid.prefix(8))")
            return
        }
        pending.segments.append(.init(id: UUID(), asrText: text, createdAt: Date()))
        pendingAgentHookRevisions[sid] = pending
        ClaudeCodeSessionManager.log("[RecognitionBoost] hook segment append sid=\(sid.prefix(8)) segments=\(pending.segments.count)")
    }

    private static func agentHookTarget(for session: HookSession) -> AgentHookTarget? {
        if session.id.hasPrefix("codex-") { return .codex }
        return .claudeCode
    }

    private static func appendVibeptyRecognitionSegment(_ text: String, session: HookSession, sid: String, spanId: String?) {
        guard let pid = session.pid else {
            ClaudeCodeSessionManager.log("[RecognitionBoost] transcript segment skipped reason=no-pid sid=\(sid.prefix(8))")
            return
        }
        guard var pending = pendingVibeptyRevision else {
            ClaudeCodeSessionManager.log("[RecognitionBoost] transcript segment skipped reason=no-pending sid=\(sid.prefix(8)) pid=\(pid)")
            return
        }
        guard pending.pid == pid, pending.sid == sid else {
            ClaudeCodeSessionManager.log("[RecognitionBoost] transcript segment skipped reason=pending-mismatch sid=\(sid.prefix(8)) pid=\(pid) pendingSid=\(pending.sid.prefix(8)) pendingPid=\(pending.pid)")
            return
        }
        pending.segments.append(.init(id: UUID(), asrText: text, createdAt: Date()))
        pendingVibeptyRevision = pending
        let suffix = spanId.map { " spanId=\($0.prefix(8))" } ?? ""
        ClaudeCodeSessionManager.log("[RecognitionBoost] transcript segment append sid=\(sid.prefix(8)) pid=\(pid) segments=\(pending.segments.count)\(suffix)")
    }

    private static func submitVibeptyRecognitionRevisionAndEnter(session: HookSession, sid: String) -> VibeptySubmitEnterOutcome {
        guard RecognitionBoostSettings.enabled else {
            pendingVibeptyRevision = nil
            ClaudeCodeSessionManager.log("[RecognitionBoost] transcript submit skipped reason=disabled")
            return .fallback
        }
        expireVibeptyRecognitionRevision()
        guard let pending = pendingVibeptyRevision else {
            ClaudeCodeSessionManager.log("[RecognitionBoost] transcript submit skipped reason=no-pending sid=\(sid.prefix(8))")
            return .fallback
        }
        guard pending.sid == sid,
              let pid = session.pid,
              pending.pid == pid,
              recognitionTranscriptPath(for: session) == pending.transcriptPath else {
            ClaudeCodeSessionManager.log("[RecognitionBoost] transcript submit skipped reason=pending-mismatch sid=\(sid.prefix(8)) sessionPid=\(session.pid.map(String.init) ?? "<nil>") pendingSid=\(pending.sid.prefix(8)) pendingPid=\(pending.pid)")
            pendingVibeptyRevision = nil
            return .fallback
        }
        if transcriptAlreadyHasPrompt(path: pending.transcriptPath, offset: pending.transcriptSizeBefore) {
            ClaudeCodeSessionManager.log("[RecognitionBoost] transcript submit skipped reason=stale-pending sid=\(sid.prefix(8)) pid=\(pid)")
            pendingVibeptyRevision = nil
            return .fallback
        }
        let outcome = PTYInjector.injectControl(bytes: ControlKey.enter.payload, session: session, label: ControlKey.enter.logName)
        guard case .success = outcome else {
            pendingVibeptyRevision = nil
            pendingAgentHookRevisions.removeValue(forKey: sid)
            ClaudeCodeSessionManager.log("[RecognitionBoost] transcript submit unavailable")
            return .fallback
        }
        if pendingAgentHookRevisions[sid] != nil {
            pendingVibeptyRevision = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                guard pendingAgentHookRevisions[sid] != nil else {
                    ClaudeCodeSessionManager.log("[RecognitionBoost] hook handled before transcript fallback sid=\(sid.prefix(8))")
                    return
                }
                pendingAgentHookRevisions.removeValue(forKey: sid)
                ClaudeCodeSessionManager.log("[RecognitionBoost] hook wait expired; transcript fallback sid=\(sid.prefix(8))")
                learnVibeptyRecognitionFromTranscript(pending)
            }
            return .handled
        }
        pendingVibeptyRevision = nil
        learnVibeptyRecognitionFromTranscript(pending)
        return .handled
    }

    private static func clearVibeptyRecognitionRevision(sessionId: String) {
        guard pendingVibeptyRevision?.sid == sessionId else { return }
        pendingVibeptyRevision = nil
        ClaudeCodeSessionManager.log("[RecognitionBoost] transcript pending cleared by hook sid=\(sessionId.prefix(8))")
    }

    private static func expireVibeptyRecognitionRevision() {
        guard let pending = pendingVibeptyRevision,
              Date().timeIntervalSince(pending.createdAt) > 600 else { return }
        pendingVibeptyRevision = nil
        ClaudeCodeSessionManager.log("[RecognitionBoost] transcript pending expired")
    }

    private static func expireAgentHookRecognitionRevisions() {
        let cutoff = Date().addingTimeInterval(-600)
        pendingAgentHookRevisions = pendingAgentHookRevisions.filter { $0.value.createdAt >= cutoff }
        recentAgentHookDedupe = recentAgentHookDedupe.filter { $0.value >= cutoff }
        let freeCutoff = Date().addingTimeInterval(-freeASRRevisionTTL)
        recentFreeASRRevisions = recentFreeASRRevisions.filter { $0.createdAt >= freeCutoff }
        trimFreeASRRevisions()
    }

    private static func trimFreeASRRevisions() {
        if recentFreeASRRevisions.count > freeASRPendingLimit {
            recentFreeASRRevisions = Array(recentFreeASRRevisions.suffix(freeASRPendingLimit))
        }
    }

    private static func recognitionTranscriptPath(for session: HookSession) -> String? {
        if session.id.hasPrefix("codex-") {
            guard let path = session.transcriptPath, !path.isEmpty else { return nil }
            return path
        }
        return session.resolvedTranscriptPath
    }

    private static func transcriptFileSize(path: String) -> UInt64 {
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        if let size = attrs?[.size] as? UInt64 { return size }
        if let size = attrs?[.size] as? NSNumber { return size.uint64Value }
        return 0
    }

    private static func learnVibeptyRecognitionFromTranscript(_ pending: VibeptyRecognitionPending) {
        DispatchQueue.global(qos: .utility).async {
            guard let prompt = pollTranscriptPrompt(path: pending.transcriptPath, offset: pending.transcriptSizeBefore) else {
                ClaudeCodeSessionManager.log("[RecognitionBoost] transcript skipped reason=timeout sid=\(pending.sid.prefix(8)) pid=\(pending.pid)")
                return
            }
            learnRecognitionRevision(
                id: UUID(),
                segments: pending.segments,
                createdAt: pending.createdAt,
                revisedText: prompt,
                sid: pending.sid,
                source: "transcript"
            )
        }
    }

    static func handleAgentHookPromptSubmit(sessionId rawSessionId: String, prompt: String?) {
        guard RecognitionBoostSettings.enabled else { return }
        expireAgentHookRecognitionRevisions()
        let sessionId = matchingAgentHookPendingKey(for: rawSessionId) ?? rawSessionId
        if sessionId != rawSessionId {
            ClaudeCodeSessionManager.log("[RecognitionBoost] hook sid matched raw=\(rawSessionId.prefix(16)) pending=\(sessionId.prefix(16))")
        }
        guard let prompt, !prompt.isEmpty else {
            ClaudeCodeSessionManager.log("[RecognitionBoost] hook skipped reason=empty-prompt sid=\(sessionId.prefix(8))")
            return
        }

        if let pending = pendingAgentHookRevisions.removeValue(forKey: sessionId) {
            clearVibeptyRecognitionRevision(sessionId: sessionId)
            learnRecognitionRevision(
                id: pending.id,
                segments: pending.segments,
                createdAt: pending.createdAt,
                revisedText: prompt,
                sid: sessionId,
                source: "hook"
            )
            return
        }

        guard let free = bestFreeASRRecognitionMatch(for: prompt, sid: sessionId) else {
            ClaudeCodeSessionManager.log("[RecognitionBoost] hook skipped reason=no-pending sid=\(sessionId.prefix(8))")
            return
        }

        recentFreeASRRevisions.removeAll { $0.id == free.pending.id }
        learnRecognitionRevision(
            id: free.pending.id,
            segments: free.pending.segments,
            createdAt: free.pending.createdAt,
            revisedText: prompt,
            sid: sessionId,
            source: "free-hook"
        )
    }

    private static func matchingAgentHookPendingKey(for sessionId: String) -> String? {
        if pendingAgentHookRevisions[sessionId] != nil { return sessionId }
        guard sessionId.hasPrefix("codex-"),
              let uuid = sessionId.split(separator: ":", maxSplits: 1).last,
              !uuid.isEmpty else { return nil }
        return pendingAgentHookRevisions.keys.first { $0.hasPrefix("codex-") && $0.hasSuffix(":\(uuid)") }
    }

    private static func sentenceRevisionPairs(asr: String, revised prompt: String, sid: String, source: String) -> [RecognitionSentencePair] {
        let asrSentences = RecognitionBoostSentenceMatcher.split(asr)
        let promptSentences = RecognitionBoostSentenceMatcher.split(prompt)
        guard asrSentences.count * promptSentences.count <= RecognitionBoostSentenceMatcher.sentenceComparisonLimit else {
            ClaudeCodeSessionManager.log("[RecognitionBoost] sentence fallback skipped reason=too-many-comparisons sid=\(sid.prefix(8)) source=\(source) asrSentences=\(asrSentences.count) promptSentences=\(promptSentences.count)")
            return []
        }
        let pairs = RecognitionBoostSentenceMatcher.pairs(asr: asr, revised: prompt)
        if pairs.isEmpty {
            ClaudeCodeSessionManager.log("[RecognitionBoost] sentence fallback skipped reason=no-pairs sid=\(sid.prefix(8)) source=\(source)")
        }
        return pairs
    }

    private static func learnRecognitionRevision(
        id: UUID,
        segments: [RecognitionBoostSegment],
        createdAt: Date,
        revisedText prompt: String,
        sid: String,
        source: String
    ) {
        RecognitionBoostLearner.learn(
            id: id,
            segments: segments,
            createdAt: createdAt,
            revisedText: prompt,
            sid: sid,
            source: source,
            shouldMerge: dedupeAgentHookRevision
        )
    }

    private static func bestFreeASRRecognitionMatch(for prompt: String, sid: String) -> FreeASRRecognitionMatch? {
        expireAgentHookRecognitionRevisions()
        let scored = recentFreeASRRevisions.compactMap { pending -> FreeASRRecognitionMatch? in
            let asr = pending.segments.map(\.asrText).joined()
            guard asr.count >= freeASRMinCharacters else { return nil }
            let fullScore = RecognitionBoostSimilarity.score(asr, prompt)
            if fullScore >= freeASRMatchThreshold {
                return .init(pending: pending, score: fullScore, mode: "full", pairs: 0)
            }
            let pairs = sentenceRevisionPairs(asr: asr, revised: prompt, sid: sid, source: "free-match")
            let sentenceScore = pairs.map(\.score).max() ?? 0
            guard sentenceScore >= freeASRMatchThreshold else { return nil }
            return .init(pending: pending, score: sentenceScore, mode: "sentences", pairs: pairs.count)
        }.sorted { $0.score > $1.score }

        guard let best = scored.first else {
            ClaudeCodeSessionManager.log("[RecognitionBoost] free skipped reason=low-similarity sid=\(sid.prefix(8))")
            return nil
        }
        if scored.count > 1, best.score - scored[1].score < freeASRMatchMargin {
            ClaudeCodeSessionManager.log("[RecognitionBoost] free skipped reason=ambiguous sid=\(sid.prefix(8)) best=\(String(format: "%.2f", best.score)) second=\(String(format: "%.2f", scored[1].score))")
            return nil
        }
        let pairPart = best.mode == "sentences" ? " pairs=\(best.pairs)" : ""
        ClaudeCodeSessionManager.log("[RecognitionBoost] free matched mode=\(best.mode) sid=\(sid.prefix(8)) score=\(String(format: "%.2f", best.score))\(pairPart)")
        return best
    }

    private static func dedupeAgentHookRevision(asr: String, revised: String) -> Bool {
        expireAgentHookRecognitionRevisions()
        let key = "\(asr)\n---\n\(revised)".data(using: .utf8)?.base64EncodedString() ?? "\(asr)\n---\n\(revised)"
        guard recentAgentHookDedupe[key] == nil else { return false }
        recentAgentHookDedupe[key] = Date()
        return true
    }

    private static func pollTranscriptPrompt(path: String, offset: UInt64) -> String? {
        let deadline = Date().addingTimeInterval(3)
        repeat {
            if let prompt = SessionTranscriptReader.latestPromptText(lines: readTranscriptLines(path: path, offset: offset)) {
                return prompt
            }
            Thread.sleep(forTimeInterval: 0.1)
        } while Date() < deadline
        return nil
    }

    private static func transcriptAlreadyHasPrompt(path: String, offset: UInt64) -> Bool {
        SessionTranscriptReader.latestPromptText(lines: readTranscriptLines(path: path, offset: offset)) != nil
    }

    private static func readTranscriptLines(path: String, offset: UInt64, maxBytes: Int = 64 * 1024) -> [String] {
        let url = URL(fileURLWithPath: path)
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }

        let size = (try? handle.seekToEnd()) ?? 0
        guard size > offset else { return [] }
        let shouldDropPartialFirstLine: Bool
        if offset == 0 {
            shouldDropPartialFirstLine = false
        } else {
            try? handle.seek(toOffset: offset - 1)
            shouldDropPartialFirstLine = handle.readData(ofLength: 1) != Data([0x0A])
        }
        try? handle.seek(toOffset: offset)
        var data = handle.readData(ofLength: min(maxBytes, Int(size - offset)))
        if shouldDropPartialFirstLine, let newline = data.firstIndex(of: 0x0A) {
            data = Data(data.dropFirst(newline + 1))
        } else if shouldDropPartialFirstLine {
            return []
        }
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        return text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    }

    private static func injectOrFallback(text: String, sid: String) {
        guard let session = resolveSession(sid: sid) else {
            logger.warning("exclusive sid=\(sid.prefix(8), privacy: .public) not in store — fallback free+JIT")
            AnalyticsClient.shared.captureInjectionResult(
                inputMode: "exclusive",
                targetKind: AnalyticsSupport.targetKind(sessionId: sid),
                result: KeyboardSimulator.hasAccessibilityPermission ? "success" : "failure",
                errorKind: KeyboardSimulator.hasAccessibilityPermission ? "none" : "permission_denied",
                fallbackUsed: "keyboard",
                textLength: text.count,
                source: "manual"
            )
            fallbackToFree(text: text, sid: sid, reason: .sessionInvalid, clear: false)
            return
        }

        let outcome = PTYInjector.inject(text: text, session: session)
        switch outcome {
        case .success:
            logger.info("exclusive inject ok sid=\(sid.prefix(8), privacy: .public) chars=\(text.count)")
            ClaudeCodeSessionManager.log("[Router] exclusive inject ok sid=\(sid.prefix(8)) chars=\(text.count)")
            AnalyticsClient.shared.captureInjectionResult(
                inputMode: "exclusive",
                targetKind: AnalyticsSupport.targetKind(sessionId: sid),
                result: "success",
                errorKind: "none",
                textLength: text.count,
                source: "manual"
            )
        case .denied(let reason):
            logger.warning("exclusive inject denied sid=\(sid.prefix(8), privacy: .public) reason=\(reason.logDescription, privacy: .public) — fallback free+JIT")
            ClaudeCodeSessionManager.log("[Router] exclusive inject denied sid=\(sid.prefix(8)) reason=\(reason.logDescription) clear=\(reason.shouldClearSelection)")
            let fallbackOk = reason.shouldFallbackToFreeTyping && KeyboardSimulator.hasAccessibilityPermission
            AnalyticsClient.shared.captureInjectionResult(
                inputMode: "exclusive",
                targetKind: AnalyticsSupport.targetKind(sessionId: sid),
                result: fallbackOk ? "success" : "failure",
                errorKind: fallbackOk ? "none" : "injection_denied",
                fallbackUsed: reason.shouldFallbackToFreeTyping ? "keyboard" : "none",
                textLength: text.count,
                source: "manual"
            )
            fallbackToFree(text: text, sid: sid, reason: reason, clear: reason.shouldClearSelection)
        }
    }

    private static func injectPromptOrFallback(text: String, sid: String) {
        guard let session = resolveSession(sid: sid) else {
            logger.warning("prompt exclusive sid=\(sid.prefix(8), privacy: .public) not in store — fallback paste+JIT")
            fallbackPromptToFree(text: text, sid: sid, reason: .sessionInvalid, clear: false)
            return
        }

        let outcome = PTYInjector.inject(text: text, session: session)
        switch outcome {
        case .success:
            logger.info("prompt exclusive inject ok sid=\(sid.prefix(8), privacy: .public) chars=\(text.count)")
            ClaudeCodeSessionManager.log("[Router] prompt exclusive inject ok sid=\(sid.prefix(8)) chars=\(text.count)")
        case .denied(let reason):
            logger.warning("prompt exclusive inject denied sid=\(sid.prefix(8), privacy: .public) reason=\(reason.logDescription, privacy: .public) — fallback paste+JIT")
            ClaudeCodeSessionManager.log("[Router] prompt exclusive inject denied sid=\(sid.prefix(8)) reason=\(reason.logDescription) clear=\(reason.shouldClearSelection)")
            fallbackPromptToFree(text: text, sid: sid, reason: reason, clear: reason.shouldClearSelection)
        }
    }

    private static func fallbackToFree(text: String, sid: String, reason: FallbackReason, clear: Bool, recordFreeASR: Bool = false, learningText: String? = nil) {
        runOnMain {
            toast?(reason)
            if clear { clearSelection?() }
        }
        // `.waitingForApproval` is special: typing into the approval UI can
        // misfire option shortcuts (y/n/1/2), so we drop the text entirely —
        // toast already told the user to resolve the approval first.
        guard reason.shouldFallbackToFreeTyping else {
            logger.info("deny reason=\(reason.logDescription, privacy: .public) — text dropped, no free fallback")
            return
        }
        if recordFreeASR { appendFreeASRRecognitionSegment(learningText ?? text) }
        // Only activate the host app if we still own the selection; if we just
        // cleared, free-mode typing lands wherever the user has focus, which
        // is the expected behavior after "selection gone" feedback.
        if !clear {
            activateTargetIfNeeded(sid: sid)
            Thread.sleep(forTimeInterval: 0.15)
        }
        KeyboardSimulator.typeText(text)
    }

    private static func fallbackPromptToFree(text: String, sid: String, reason: FallbackReason, clear: Bool) {
        runOnMain {
            toast?(reason)
            if clear { clearSelection?() }
        }
        guard reason.shouldFallbackToFreeTyping else {
            logger.info("prompt deny reason=\(reason.logDescription, privacy: .public) — text dropped, no free fallback")
            return
        }
        if !clear {
            activateTargetIfNeeded(sid: sid)
            Thread.sleep(forTimeInterval: 0.15)
        }
        KeyboardSimulator.typePromptText(text)
    }

    private static func resolveSession(sid: String) -> HookSession? {
        var result: HookSession?
        runOnMain {
            result = sessionResolver?(sid)
        }
        return result
    }

    private static func activateTargetIfNeeded(sid: String) {
        runOnMain {
            guard let resolver = sessionResolver, let activator = activator else {
                logger.warning("activator not configured; exclusive fallback will miss target")
                return
            }
            guard let session = resolver(sid) else {
                logger.warning("activator: session \(sid.prefix(8), privacy: .public) not found in hook store")
                return
            }
            activator(session)
        }
    }

    private static func runOnMain(_ work: @MainActor () -> Void) {
        if Thread.isMainThread {
            MainActor.assumeIsolated { work() }
        } else {
            DispatchQueue.main.sync {
                MainActor.assumeIsolated { work() }
            }
        }
    }
}
