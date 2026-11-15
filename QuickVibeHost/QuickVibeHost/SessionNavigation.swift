import AppKit
import ApplicationServices
import Foundation
import os

enum SessionJumpResult: Sendable {
    case exact
    case appOnly
    case unavailable(String)
}

enum SessionNavigationService {
    private static let logger = Logger(
        subsystem: "com.vibeeverything.QuickVibeHost",
        category: "SessionNavigation"
    )

    @MainActor
    static func record(event: HookEvent) {
        let kind = SessionJumpTarget.hostKind(for: event.terminalApp, tmuxTarget: event.tmuxTarget)
        let confidence: JumpTargetConfidence = event.terminalSessionId != nil || event.tmuxTarget != nil
            ? .stableIdentifier : .hook
        SessionJumpTargetStore.shared.update(.init(
            sessionId: event.sessionId,
            hostKind: kind,
            appName: event.terminalApp,
            bundleIdentifier: nil,
            threadId: nil,
            pid: event.pid,
            tty: event.tty,
            terminalSessionId: event.terminalSessionId,
            paneId: event.terminalPaneId,
            tmuxTarget: event.tmuxTarget,
            workingDirectory: event.cwd,
            workspacePath: kind == .vsCode ? event.cwd : nil,
            capturedAt: Date(),
            confidence: confidence
        ))
    }

    @MainActor
    static func recordCodexHook(sessionId: String, payload: [String: Any]) {
        let app = payload["terminal_app"] as? String
        let tmux = payload["tmux_target"] as? String
        let kind = SessionJumpTarget.hostKind(for: app, tmuxTarget: tmux)
        SessionJumpTargetStore.shared.update(.init(
            sessionId: sessionId,
            hostKind: kind,
            appName: app,
            bundleIdentifier: nil,
            threadId: sessionId.split(separator: ":", maxSplits: 1).last.map(String.init),
            pid: payload["pid"] as? Int,
            tty: payload["tty"] as? String,
            terminalSessionId: payload["terminal_session_id"] as? String,
            paneId: payload["terminal_pane_id"] as? String,
            tmuxTarget: tmux,
            workingDirectory: payload["cwd"] as? String,
            workspacePath: kind == .vsCode ? payload["cwd"] as? String : nil,
            capturedAt: Date(),
            confidence: (payload["terminal_session_id"] != nil || tmux != nil) ? .stableIdentifier : .hook
        ))
    }

    @MainActor
    static func open(session: HookSession, sessionManager: ClaudeCodeSessionManager) {
        if session.id.hasPrefix("codex-desktop:") {
            CodexDesktopActivator.bringToFront(threadId: threadId(from: session.id))
            return
        }

        var target = resolvedTarget(session: session, sessionManager: sessionManager)
        if session.id.hasPrefix("codex-vscode:") {
            target.hostKind = .vsCode
            target.appName = target.appName ?? "Visual Studio Code"
            target.bundleIdentifier = target.bundleIdentifier ?? "com.microsoft.VSCode"
            target.workspacePath = target.workspacePath ?? session.cwd
        }

        if target.hasPreciseTerminalLocator || target.hostKind == .vsCode {
            Task.detached(priority: .userInitiated) {
                let result = TerminalSessionNavigator.jump(to: target)
                logger.info("jump sid=\(session.id.prefix(8), privacy: .public) result=\(String(describing: result), privacy: .public)")
            }
            return
        }

        if session.id.hasPrefix("codex-vscode:") {
            CodexVSCodeActivator.bringToFront()
        } else if !session.id.hasPrefix("codex-"),
                  !(session.pid.map(VibeptyClient.isChannelAvailable(pid:)) ?? false) {
            ClaudeDesktopActivator.resume(sessionId: session.id)
        } else {
            SessionActivator.bringToFrontAsync(session: session, sessionManager: sessionManager)
        }
    }

    @MainActor
    private static func resolvedTarget(
        session: HookSession,
        sessionManager: ClaudeCodeSessionManager
    ) -> SessionJumpTarget {
        var target = SessionJumpTargetStore.shared.target(for: session.id) ?? .init(
            sessionId: session.id,
            hostKind: .unknown,
            appName: nil,
            bundleIdentifier: nil,
            threadId: threadId(from: session.id),
            pid: session.pid,
            tty: session.tty,
            terminalSessionId: nil,
            paneId: nil,
            tmuxTarget: nil,
            workingDirectory: session.cwd,
            workspacePath: nil,
            capturedAt: Date(),
            confidence: .inferred
        )
        target.pid = target.pid ?? session.pid
        target.tty = target.tty ?? session.tty
        target.workingDirectory = target.workingDirectory ?? session.cwd
        target.displayTitle = target.displayTitle ?? session.projectName

        if target.appName == nil, let pid = session.pid {
            let cached = sessionManager.sessions.first(where: { $0.pid == pid })?.hostApp
            if let path = cached ?? ClaudeCodeSessionManager.resolveHostApp(forPid: pid) {
                let bundle = Bundle(path: path)
                target.bundleIdentifier = bundle?.bundleIdentifier
                target.appName = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
            }
        }
        if target.hostKind == .unknown {
            target.hostKind = SessionJumpTarget.hostKind(for: target.appName, tmuxTarget: target.tmuxTarget)
        }
        return target
    }

    private static func threadId(from sessionId: String) -> String? {
        sessionId.split(separator: ":", maxSplits: 1).last.map(String.init)
    }
}

enum TerminalSessionNavigator {
    static func jump(to target: SessionJumpTarget) -> SessionJumpResult {
        if let tmuxTarget = target.tmuxTarget {
            var outer = target
            outer.tmuxTarget = nil
            outer.hostKind = SessionJumpTarget.hostKind(for: outer.appName)
            _ = jump(to: outer)
            guard run("/usr/bin/env", ["tmux", "select-pane", "-t", tmuxTarget]) else {
                return activate(target) ? .appOnly : .unavailable("tmux select-pane failed")
            }
            return .exact
        }

        switch target.hostKind {
        case .terminal:
            return jumpTerminal(target)
        case .iTerm:
            return jumpITerm(target)
        case .ghostty:
            return jumpGhostty(target)
        case .vsCode:
            return jumpVSCode(target)
        default:
            return activate(target) ? .appOnly : .unavailable("unsupported host")
        }
    }

    private static func jumpTerminal(_ target: SessionJumpTarget) -> SessionJumpResult {
        guard let tty = normalizedTTY(target.tty) else {
            return activate(target) ? .appOnly : .unavailable("Terminal TTY missing")
        }
        let value = appleScriptString(tty)
        let script = """
        tell application "Terminal"
          set targetWindow to missing value
          set targetTab to missing value
          repeat with aWindow in windows
            repeat with aTab in tabs of aWindow
              if (tty of aTab as text) is "\(value)" then
                set targetWindow to aWindow
                set targetTab to aTab
                exit repeat
              end if
            end repeat
            if targetTab is not missing value then exit repeat
          end repeat
          if targetTab is missing value then return "miss"
          try
            if miniaturized of targetWindow then set miniaturized of targetWindow to false
          end try
          set index of targetWindow to 1
          set selected of targetTab to true
          activate
          delay 0.08
          if (tty of selected tab of front window as text) is "\(value)" then return "matched"
          return "focused"
        end tell
        """
        let result = runAppleScript(script)
        if result == "matched" || result == "focused" { return .exact }
        return activate(target) ? .appOnly : .unavailable("Terminal tab not found")
    }

    private static func jumpITerm(_ target: SessionJumpTarget) -> SessionJumpResult {
        let rawID = target.terminalSessionId
        let guid = rawID.flatMap { $0.split(separator: ":").last.map(String.init) }
        let condition: String?
        if let guid, !guid.isEmpty {
            condition = "(unique ID of aSession as text) is \"\(appleScriptString(guid))\""
        } else if let tty = normalizedTTY(target.tty) {
            condition = "(tty of aSession as text) is \"\(appleScriptString(tty))\""
        } else {
            condition = nil
        }
        guard let condition else {
            return activate(target) ? .appOnly : .unavailable("iTerm session id missing")
        }
        let script = """
        tell application "iTerm"
          repeat with aWindow in windows
            repeat with aTab in tabs of aWindow
              repeat with aSession in sessions of aTab
                if \(condition) then
                  select aWindow
                  select aTab
                  select aSession
                  activate
                  return "matched"
                end if
              end repeat
            end repeat
          end repeat
          return "miss"
        end tell
        """
        if runAppleScript(script) == "matched" { return .exact }
        return activate(target) ? .appOnly : .unavailable("iTerm session not found")
    }

    private static func jumpGhostty(_ target: SessionJumpTarget) -> SessionJumpResult {
        let terminalCondition: String?
        if let id = target.terminalSessionId, !id.isEmpty {
            terminalCondition = "(id of aTerminal as text) is \"\(appleScriptString(id))\""
        } else {
            terminalCondition = nil
        }

        if let terminalCondition {
            let script = """
            tell application "Ghostty"
              repeat with aWindow in windows
                repeat with aTab in tabs of aWindow
                  repeat with aTerminal in terminals of aTab
                    if \(terminalCondition) then
                      focus aTerminal
                      return "matched-id"
                    end if
                  end repeat
                end repeat
              end repeat
              return "miss"
            end tell
            """
            if runAppleScript(script) == "matched-id" { return .exact }
        }

        // Ghostty does not currently export TERM_SESSION_ID to every shell. Its
        // tab title still carries Claude's custom session title, which is a much
        // stronger discriminator than cwd when several tabs share one project.
        if let title = target.displayTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
           !title.isEmpty {
            let value = appleScriptString(title)
            let script = """
            tell application "Ghostty"
              repeat with aWindow in windows
                repeat with aTab in tabs of aWindow
                  if (name of aTab as text) contains "\(value)" then
                    focus (focused terminal of aTab)
                    return "matched-title"
                  end if
                end repeat
              end repeat
              return "miss"
            end tell
            """
            if runAppleScript(script) == "matched-title" { return .exact }
        }

        guard let cwd = target.workingDirectory, !cwd.isEmpty else {
            return activate(target) ? .appOnly : .unavailable("Ghostty locator missing")
        }
        let value = appleScriptString(cwd)
        let script = """
        tell application "Ghostty"
          set matchedTerminal to missing value
          set matchCount to 0
          repeat with aWindow in windows
            repeat with aTab in tabs of aWindow
              repeat with aTerminal in terminals of aTab
                if (working directory of aTerminal as text) is "\(value)" then
                  set matchedTerminal to aTerminal
                  set matchCount to matchCount + 1
                end if
              end repeat
            end repeat
          end repeat
          if matchCount is not 1 then return "ambiguous"
          focus matchedTerminal
          return "matched-cwd"
        end tell
        """
        if runAppleScript(script) == "matched-cwd" { return .exact }
        return activate(target) ? .appOnly : .unavailable("Ghostty terminal is ambiguous")
    }

    private static func jumpVSCode(_ target: SessionJumpTarget) -> SessionJumpResult {
        let path = target.workspacePath ?? target.workingDirectory
        let project = path.map { URL(fileURLWithPath: $0).lastPathComponent }
        if let project, !project.isEmpty {
            let bundle = appleScriptString(target.bundleIdentifier ?? "com.microsoft.VSCode")
            let title = appleScriptString(project.replacingOccurrences(of: ".code-workspace", with: ""))
            let script = """
            tell application "System Events"
              try
                set targetProcess to first process whose bundle identifier is "\(bundle)"
              on error
                return "miss"
              end try
              repeat with aWindow in windows of targetProcess
                try
                  if (name of aWindow as text) contains "\(title)" then
                    set frontmost of targetProcess to true
                    perform action "AXRaise" of aWindow
                    return "matched"
                  end if
                end try
              end repeat
              return "miss"
            end tell
            """
            if runAppleScript(script) == "matched" { return .exact }
        }
        if let path, run("/usr/bin/open", ["-b", target.bundleIdentifier ?? "com.microsoft.VSCode", path]) {
            return .appOnly
        }
        return activate(target) ? .appOnly : .unavailable("VS Code workspace not found")
    }

    private static func activate(_ target: SessionJumpTarget) -> Bool {
        if let bundle = target.bundleIdentifier, run("/usr/bin/open", ["-b", bundle]) { return true }
        if let app = target.appName, run("/usr/bin/open", ["-a", app]) { return true }
        return false
    }

    static func normalizedTTY(_ value: String?) -> String? {
        guard let raw = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty, raw != "??", raw != "-" else { return nil }
        return raw.hasPrefix("/dev/") ? raw : "/dev/\(raw)"
    }

    static func appleScriptString(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "\n", with: "\" & return & \"")
    }

    private static func runAppleScript(_ script: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }
        return String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @discardableResult
    private static func run(_ executable: String, _ arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }
}
