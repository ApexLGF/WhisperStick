import Foundation
import os

/// Writes ASR-produced text directly to a claude session's controlling tty,
/// bypassing the frontmost-app dependency of `KeyboardSimulator`. This is the
/// Step 3 replacement for the exclusive-mode fallback path.
///
/// Injection runs an 8-step pre-check (phase gate, presence, stat, open,
/// TOCTOU pgid match) before `write(2)`. Any failure returns a typed
/// `FallbackReason` so the caller can toast + decide whether to clear the
/// selection or simply warn and fall back to free mode.
///
/// Callers MUST NOT append `\n` to the text — auto-submit is a separate
/// concern, and in approval phases a trailing newline could fire option
/// shortcuts (`1`/`2`/`y`/`n`) instead of filling the text field.
enum PTYInjector {
    private static let logger = Logger(subsystem: "com.vibeeverything.QuickVibeHost", category: "PTYInjector")

    enum Outcome {
        case success
        case denied(FallbackReason)
    }

    enum ASROutcome {
        case success(spanId: String?)
        case denied(FallbackReason)
    }

    static func inject(text: String, session: HookSession) -> Outcome {
        guard !text.isEmpty else { return .denied(.sessionInvalid) }

        switch PhaseGate.allowInject(in: session.phase) {
        case .deny(let reason):
            logger.info("phase gate denied sid=\(session.id.prefix(8), privacy: .public) reason=\(reason.logDescription, privacy: .public)")
            return .denied(reason)
        case .allow:
            break
        }

        guard let data = text.data(using: .utf8), !data.isEmpty else {
            logger.warning("utf-8 encoding produced empty payload")
            return .denied(.sessionInvalid)
        }
        return writeBytes(data, session: session, label: "\(data.count)B text")
    }

    static func injectASRSpan(text: String, session: HookSession) -> ASROutcome {
        guard !text.isEmpty else { return .denied(.sessionInvalid) }

        switch PhaseGate.allowInject(in: session.phase) {
        case .deny(let reason):
            logger.info("asr phase gate denied sid=\(session.id.prefix(8), privacy: .public) reason=\(reason.logDescription, privacy: .public)")
            return .denied(reason)
        case .allow:
            break
        }

        guard let data = text.data(using: .utf8), !data.isEmpty else {
            logger.warning("utf-8 encoding produced empty asr payload")
            return .denied(.sessionInvalid)
        }
        let result = writeBytesResult(data, session: session, label: "\(data.count)B asr", asrSpan: true)
        switch result.outcome {
        case .success:
            return .success(spanId: result.spanId)
        case .denied(let reason):
            return .denied(reason)
        }
    }

    /// Inject a short control-byte sequence (e.g. `\r`, `\x1b\x1b`). Uses a
    /// looser phase gate than `inject(text:)` — Enter/ESC are meaningful in
    /// every phase except `.ended` (Enter confirms approvals; ESC cancels /
    /// interrupts processing), so only `.ended` is denied here.
    static func injectControl(bytes: Data, session: HookSession, label: String) -> Outcome {
        guard !bytes.isEmpty else { return .denied(.sessionInvalid) }

        switch PhaseGate.allowControlInject(in: session.phase) {
        case .deny(let reason):
            logger.info("control phase gate denied sid=\(session.id.prefix(8), privacy: .public) label=\(label, privacy: .public) reason=\(reason.logDescription, privacy: .public)")
            return .denied(reason)
        case .allow:
            break
        }

        return writeBytes(bytes, session: session, label: label)
    }

    /// Shared pid check + vibepty socket inject. macOS 14+ 封了 TIOCSTI 且
    /// 对 slave tty 的 write 只是屏幕输出，所以我们用 `vibepty` wrapper 持有
    /// master fd，通过 unix socket 让 wrapper 代写 master → 字节进 claude stdin。
    private static func writeBytes(_ data: Data, session: HookSession, label: String) -> Outcome {
        writeBytesResult(data, session: session, label: label, asrSpan: false).outcome
    }

    private static func writeBytesResult(_ data: Data, session: HookSession, label: String, asrSpan: Bool) -> (outcome: Outcome, spanId: String?) {
        guard let pid = session.pid, pid > 0 else {
            logger.warning("no pid for sid=\(session.id.prefix(8), privacy: .public)")
            // codex 会话无 pid = sidecar 映射缺失(未经 vibepty 启动 / wrapper 已退出),
            // 属注入通道终态缺失 → codexNotWrapped(自动清直通);CC 保持原 sessionInvalid
            return (.denied(session.id.hasPrefix("codex-") ? .codexNotWrapped : .sessionInvalid), nil)
        }

        // pid 存活性 + comm 校验（防 pid 重用）— vibepty 存在但 child 是别的进程的情况
        // 只有 vibepty 来不及清 socket 的短窗口可能发生。
        guard let snapshot = readProcessSnapshot(pid: pid) else {
            logger.warning("ps snapshot failed for pid=\(pid) — process gone?")
            return (.denied(.sessionEnded), nil)
        }
        // BUG-021: 严格白名单 {claude,node} 在 CC 新版启动器下 100% 误判 —
        // 实际引擎进程是 ~/.local/share/claude/versions/<X.Y.Z>,comm 就是版本号
        // 字符串(实测 "2.1.203");另有 argv 改名的 "claude bg-pty-host" 等变体。
        // 放宽为模式匹配;真正的 pid 重用安全网是 vibepty 按 pid 寻址的 socket
        // (pid 被重用时 socket 不存在或握手失败,走 vibeptyUnavailable/ttyWriteFailed)。
        let commLeaf = (snapshot.comm as NSString).lastPathComponent
        let isVersionBinary = commLeaf.range(of: #"^\d+(\.\d+)+$"#, options: .regularExpression) != nil
        // REQ-019: codex 经 npm 启动时 vibepty child 是 node(codex.js);原生安装是 codex 二进制
        let commLooksLikeAgent = commLeaf.hasPrefix("claude")
            || commLeaf.hasPrefix("codex")
            || commLeaf == "node" || commLeaf == "bun"
            || isVersionBinary
            || snapshot.comm.contains("/claude/")
            || snapshot.comm.contains("/codex/")
        guard commLooksLikeAgent else {
            logger.warning("pid=\(pid) comm=\(snapshot.comm, privacy: .public) 不像 claude/codex 进程 — pid 疑被重用")
            return (.denied(.ttyReused), nil)
        }

        // 通过 vibepty socket 注入
        do {
            let spanId = try VibeptyClient.inject(bytes: data, toPid: pid, asrSpan: asrSpan)
            logger.info("injected sid=\(session.id.prefix(8), privacy: .public) pid=\(pid) payload=\(label, privacy: .public)")
            return (.success, spanId)
        } catch let err as VibeptyClient.ClientError {
            switch err {
            case .connectRefused(let e):
                logger.info("vibepty socket unreachable pid=\(pid) errno=\(e) — 未用 vibepty 启动?")
                return (.denied(.vibeptyUnavailable), nil)
            case .socketCreateFailed(let e), .sendFailed(let e), .recvFailed(let e):
                logger.warning("vibepty transport error pid=\(pid) errno=\(e)")
                return (.denied(.ttyWriteFailed), nil)
            case .pathTooLong, .replyInvalid, .replyError:
                logger.warning("vibepty reply error: \(String(describing: err), privacy: .public)")
                return (.denied(.ttyWriteFailed), nil)
            }
        } catch {
            logger.warning("vibepty unexpected error: \(error.localizedDescription, privacy: .public)")
            return (.denied(.ttyWriteFailed), nil)
        }
    }

    private struct ProcessSnapshot {
        let pid: Int
        let tty: String    // short form, e.g. "ttys004"
        let comm: String   // last path component of argv[0]
    }

    /// Runs `ps -o pid=,tty=,comm= -p <pid>` and parses the single row. Returns
    /// nil when ps exits non-zero (pid gone) or the row can't be parsed.
    ///
    /// `ps` pads tty with trailing spaces and may emit the comm as an absolute
    /// path; we trim and take the basename.
    private static func readProcessSnapshot(pid: Int) -> ProcessSnapshot? {
        let process = Process()
        process.launchPath = "/bin/ps"
        process.arguments = ["-o", "pid=,tty=,comm=", "-p", "\(pid)"]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }
        let raw = String(
            data: out.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        )?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // ps emits: "<pid> <tty> <comm...>" with variable whitespace. Split
        // into at most 3 fields so a path-containing comm stays intact.
        let parts = raw.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard parts.count == 3,
              let psPid = Int(parts[0]) else { return nil }
        let ttyRaw = String(parts[1]).trimmingCharacters(in: .whitespaces)
        let tty = TTYNormalizer.normalize(ttyRaw)
        let comm = String(parts[2]).trimmingCharacters(in: .whitespaces)
        return ProcessSnapshot(pid: psPid, tty: tty, comm: comm)
    }
}

// MARK: - Phase Gate

enum PhaseGate {
    /// Tools whose approval UI contains a free-text input field where PTY
    /// writes can land (only after the user manually shifts focus to the
    /// text box by pressing the option number/Tab). Kept as an explicit
    /// whitelist — default is deny.
    static let textInputApprovalTools: Set<String> = [
        "ExitPlanMode",
        "AskUserQuestion",
    ]

    enum Decision {
        case allow
        case deny(FallbackReason)
    }

    static func allowInject(in phase: SessionPhase) -> Decision {
        switch phase {
        case .ended:
            return .deny(.sessionEnded)
        case .waitingForApproval(let ctx):
            if textInputApprovalTools.contains(ctx.toolName) {
                return .allow
            }
            return .deny(.waitingForApproval(toolName: ctx.toolName))
        case .idle, .processing, .waitingForInput, .compacting:
            return .allow
        }
    }

    /// Control keys (Enter / ESC) are meaningful in every phase except
    /// `.ended` — Enter confirms approvals and submits prompts, ESC cancels
    /// approvals and interrupts processing. No per-tool whitelist needed.
    static func allowControlInject(in phase: SessionPhase) -> Decision {
        switch phase {
        case .ended:
            return .deny(.sessionEnded)
        case .idle, .processing, .waitingForInput, .compacting, .waitingForApproval:
            return .allow
        }
    }
}

// MARK: - TTY Normalizer

enum TTYNormalizer {
    /// Converts raw tty strings to the short form `ttysNNN`. Accepts
    /// `/dev/ttysNNN`, `ttysNNN`, and trims whitespace. Returns the input as-is
    /// if it doesn't match the expected pattern — `stat`/`open` will then
    /// surface the error typed as `.ttyOpenFailed`.
    static func normalize(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("/dev/") {
            return String(trimmed.dropFirst("/dev/".count))
        }
        return trimmed
    }
}
