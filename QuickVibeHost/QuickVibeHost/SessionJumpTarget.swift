import Foundation

enum SessionHostKind: String, Codable, Sendable {
    case codexDesktop
    case claudeDesktop
    case chatGPT
    case terminal
    case iTerm
    case ghostty
    case tmux
    case vsCode
    case unknown
}

enum JumpTargetConfidence: Int, Codable, Comparable, Sendable {
    case fallback = 0
    case inferred = 1
    case hook = 2
    case stableIdentifier = 3

    static func < (lhs: JumpTargetConfidence, rhs: JumpTargetConfidence) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

struct SessionJumpTarget: Codable, Equatable, Sendable {
    let sessionId: String
    var hostKind: SessionHostKind
    var appName: String?
    var bundleIdentifier: String?
    var threadId: String?
    var pid: Int?
    var tty: String?
    var terminalSessionId: String?
    var paneId: String?
    var tmuxTarget: String?
    var workingDirectory: String?
    var workspacePath: String?
    var displayTitle: String? = nil
    var capturedAt: Date
    var confidence: JumpTargetConfidence

    var hasPreciseTerminalLocator: Bool {
        tmuxTarget != nil || terminalSessionId != nil || tty != nil
    }

    mutating func merge(_ newer: SessionJumpTarget) {
        guard sessionId == newer.sessionId else { return }
        if newer.hostKind != .unknown { hostKind = newer.hostKind }
        appName = newer.appName ?? appName
        bundleIdentifier = newer.bundleIdentifier ?? bundleIdentifier
        threadId = newer.threadId ?? threadId
        pid = newer.pid ?? pid
        tty = newer.tty ?? tty
        terminalSessionId = newer.terminalSessionId ?? terminalSessionId
        paneId = newer.paneId ?? paneId
        tmuxTarget = newer.tmuxTarget ?? tmuxTarget
        workingDirectory = newer.workingDirectory ?? workingDirectory
        workspacePath = newer.workspacePath ?? workspacePath
        displayTitle = newer.displayTitle ?? displayTitle
        capturedAt = max(capturedAt, newer.capturedAt)
        confidence = max(confidence, newer.confidence)
    }

    static func hostKind(for appName: String?, tmuxTarget: String? = nil) -> SessionHostKind {
        if tmuxTarget != nil { return .tmux }
        switch appName?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "terminal", "apple_terminal": return .terminal
        case "iterm", "iterm2", "iterm.app": return .iTerm
        case "ghostty": return .ghostty
        case "visual studio code", "vs code", "vscode", "code": return .vsCode
        default: return .unknown
        }
    }
}

@MainActor
final class SessionJumpTargetStore {
    static let shared = SessionJumpTargetStore()
    private var targets: [String: SessionJumpTarget] = [:]

    func update(_ target: SessionJumpTarget) {
        if var existing = targets[target.sessionId] {
            existing.merge(target)
            targets[target.sessionId] = existing
        } else {
            targets[target.sessionId] = target
        }
    }

    func target(for sessionId: String) -> SessionJumpTarget? {
        targets[sessionId]
    }

    func remove(sessionId: String) {
        targets.removeValue(forKey: sessionId)
    }
}

struct ClaudeDesktopSessionMapping: Equatable, Sendable {
    let desktopSessionId: String
    let cliSessionId: String
    let modifiedAt: Date

    var isSyntheticImport: Bool {
        desktopSessionId == "local_\(cliSessionId)"
    }
}

enum ClaudeDesktopSessionResolver {
    static func mapping(cliSessionId: String, baseURL: URL) -> ClaudeDesktopSessionMapping? {
        guard !cliSessionId.isEmpty,
              let accounts = try? FileManager.default.contentsOfDirectory(
                at: baseURL,
                includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey],
                options: [.skipsHiddenFiles]
              ) else { return nil }

        var matches: [ClaudeDesktopSessionMapping] = []
        for account in accounts where isDirectory(account) {
            guard let organizations = try? FileManager.default.contentsOfDirectory(
                at: account,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            for organization in organizations where isDirectory(organization) {
                guard let files = try? FileManager.default.contentsOfDirectory(
                    at: organization,
                    includingPropertiesForKeys: [.contentModificationDateKey],
                    options: [.skipsHiddenFiles]
                ) else { continue }
                for file in files where file.pathExtension == "json" {
                    guard let data = try? Data(contentsOf: file),
                          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let storedCLI = object["cliSessionId"] as? String,
                          storedCLI == cliSessionId,
                          let desktop = object["sessionId"] as? String,
                          !desktop.isEmpty else { continue }
                    let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?
                        .contentModificationDate ?? .distantPast
                    matches.append(.init(
                        desktopSessionId: desktop,
                        cliSessionId: storedCLI,
                        modifiedAt: modified
                    ))
                }
            }
        }
        return matches.sorted {
            if $0.isSyntheticImport != $1.isSyntheticImport {
                return !$0.isSyntheticImport
            }
            return $0.modifiedAt > $1.modifiedAt
        }.first
    }

    private static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }
}
