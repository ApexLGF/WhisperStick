import Foundation
import Combine
import os

/// Persists the currently selected claude session id for exclusive input mode.
/// The id is shared with `InputRouter` via the `exclusiveSelectedSessionId`
/// UserDefaults key so routing decisions stay consistent across launches.
///
/// Subscribes to `ClaudeHookSessionStore.$sessions` to auto-clear the selection
/// when the chosen session ends or disappears from the store.
@MainActor
final class SessionSelectionStore: ObservableObject {
    static let userDefaultsKey = InputRouter.selectedSessionIdKey

    @Published private(set) var selectedSessionId: String? {
        didSet {
            UserDefaults.standard.set(selectedSessionId ?? "", forKey: Self.userDefaultsKey)
            logger.info("selection -> \(self.selectedSessionId?.prefix(8) ?? "<none>", privacy: .public)")
        }
    }

    private let logger = Logger(subsystem: "com.vibeeverything.QuickVibeHost", category: "Selection")
    private var cancellable: AnyCancellable?
    private var bleCancellable: AnyCancellable?
    /// Prevents premature auto-clear at startup: the hookStore emits an empty
    /// snapshot before seed/hook traffic lands, which would otherwise clear a
    /// persisted selection. We only arm auto-clear once we've observed the
    /// selected session in the store at least once.
    private var hasSeenSelectedSession = false

    init() {
        let raw = UserDefaults.standard.string(forKey: Self.userDefaultsKey) ?? ""
        self.selectedSessionId = raw.isEmpty ? nil : raw
    }

    /// Subscribe to the hook store so the selection self-clears when the session
    /// ends. Call once from the app entry point.
    ///
    /// REQ-019: 直通目标可能是 CC(hookStore)或 Codex(codexMonitor),
    /// 两个 store 的快照合并后按 sid 前缀路由;任一 store 更新都重新评估。
    ///
    /// `onFirstRestore` fires once at startup when a persisted selection is
    /// confirmed against the hook store — callers use it to re-activate the
    /// target host app so Step 1/2 fallback (free-mode KeyboardSimulator) lands
    /// in the right window without requiring the user to re-toggle selection.
    func bind(to hookStore: ClaudeHookSessionStore,
              codexMonitor: CodexSessionMonitor? = nil,
              onFirstRestore: ((HookSession) -> Void)? = nil) {
        let codexPublisher = codexMonitor?.$sessions.eraseToAnyPublisher()
            ?? Just([String: HookSession]()).eraseToAnyPublisher()
        cancellable = hookStore.$sessions
            .combineLatest(codexPublisher)
            .receive(on: RunLoop.main)
            .sink { [weak self] ccSessions, codexSessions in
                guard let self, let sid = self.selectedSessionId else { return }
                let sessions = sid.hasPrefix("codex-") ? codexSessions : ccSessions
                if let session = sessions[sid], session.phase != .ended {
                    let wasFirstSight = !self.hasSeenSelectedSession
                    self.hasSeenSelectedSession = true
                    if wasFirstSight {
                        self.logger.info("restored selection \(sid.prefix(8), privacy: .public) confirmed")
                        onFirstRestore?(session)
                    }
                    return
                }
                guard self.hasSeenSelectedSession else { return }
                // Diagnostic: distinguish the two "gone" branches so we can see
                // whether approval-phase transients are causing spurious clears.
                // See plan: luminous-crunching-journal.md (改动 3).
                let reason: String
                let lastPhase: String
                if let session = sessions[sid] {
                    reason = "phaseEnded"
                    lastPhase = String(describing: session.phase)
                } else {
                    reason = "notInStore"
                    lastPhase = "<absent>"
                }
                self.logger.info("selected session \(sid.prefix(8), privacy: .public) gone — clearing reason=\(reason, privacy: .public) lastPhase=\(lastPhase, privacy: .public)")
                ClaudeCodeSessionManager.log("[Selection] auto-clear sid=\(sid.prefix(8)) reason=\(reason) lastPhase=\(lastPhase)")
                self.selectedSessionId = nil
            }
    }

    /// 监听 BLE 生命周期：进入 `.memorizedFailed` / `.memorizedWaiting`（快速重连已耗尽）时清掉直通。
    /// `.memorizedReconnecting` 不清，给自动重连窗口保留选择。
    /// waiting 可能持续数小时（挂起等设备回归），直通的 session 大概率已轮换，保留无意义。
    func bindDeviceLifecycle(from bleManager: BLEManager) {
        bleCancellable = bleManager.$connectionState
            .combineLatest(bleManager.$autoReconnectAttempts, bleManager.$isPendingWait)
            .receive(on: RunLoop.main)
            .sink { [weak self, weak bleManager] _, _, _ in
                guard let self, let bleManager else { return }
                guard self.selectedSessionId != nil else { return }
                switch bleManager.deviceLifecycle {
                case .memorizedFailed, .memorizedWaiting:
                    self.logger.info("device lifecycle = \(String(describing: bleManager.deviceLifecycle)) — clearing exclusive selection")
                    ClaudeCodeSessionManager.log("[Selection] lifecycle-clear state=\(String(describing: bleManager.deviceLifecycle))")
                    self.selectedSessionId = nil
                default:
                    break
                }
            }
    }

    func select(_ sessionId: String) {
        ClaudeCodeSessionManager.log("[Selection] select sid=\(sessionId.prefix(8))")
        selectedSessionId = sessionId
    }

    func clear() {
        ClaudeCodeSessionManager.log("[Selection] clear (explicit)")
        selectedSessionId = nil
    }

    func toggle(_ sessionId: String) {
        if selectedSessionId == sessionId {
            clear()
        } else {
            select(sessionId)
        }
    }

    func isSelected(_ sessionId: String) -> Bool {
        selectedSessionId == sessionId
    }
}
