import Foundation
import os

/// Auto-installs Claude Code hooks for VibeEverything on app launch.
/// Detects CodeIsland to avoid PermissionRequest conflict.
struct HookInstaller {
    private static let logger = Logger(subsystem: "com.vibeeverything.QuickVibeHost", category: "HookInstaller")
    private static let scriptName = "vibepanel-hook.py"

    /// Install hook script and update settings.json
    static func installIfNeeded() {
        let claudeDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude")
        let hooksDir = claudeDir.appendingPathComponent("hooks")
        let pythonScript = hooksDir.appendingPathComponent(scriptName)
        let settings = claudeDir.appendingPathComponent("settings.json")

        try? FileManager.default.createDirectory(at: hooksDir, withIntermediateDirectories: true)

        // Atomically replace the local hook on every launch. The bundled script and
        // its schema are versioned with the app, so stale hooks never stay active.
        if let bundled = Bundle.main.url(forResource: "vibepanel-hook", withExtension: "py") {
            do {
                try Data(contentsOf: bundled).write(to: pythonScript, options: .atomic)
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o755],
                    ofItemAtPath: pythonScript.path
                )
                logger.info("Installed hook script to \(pythonScript.path)")
            } catch {
                logger.error("Failed to update hook script: \(error.localizedDescription, privacy: .public)")
                return
            }
        } else {
            logger.error("Hook script not found in bundle")
        }

        let codeIslandPresent = isCodeIslandInstalled(at: settings)
        updateSettings(at: settings, skipPermission: codeIslandPresent)

        if codeIslandPresent {
            logger.info("CodeIsland detected — skipping PermissionRequest registration")
        }
    }

    /// Check if CodeIsland hooks are registered in settings.json
    private static func isCodeIslandInstalled(at settingsURL: URL) -> Bool {
        guard let data = try? Data(contentsOf: settingsURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hooks = json["hooks"] as? [String: Any] else { return false }

        for (_, value) in hooks {
            if let entries = value as? [[String: Any]] {
                for entry in entries {
                    if let entryHooks = entry["hooks"] as? [[String: Any]] {
                        for hook in entryHooks {
                            if let cmd = hook["command"] as? String,
                               cmd.contains("codeisland-state.py") {
                                return true
                            }
                        }
                    }
                }
            }
        }
        return false
    }

    private static func updateSettings(at settingsURL: URL, skipPermission: Bool) {
        var json: [String: Any] = [:]
        if let data = try? Data(contentsOf: settingsURL),
           let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            json = existing
        }

        let python = detectPython()
        let command = "\(python) ~/.claude/hooks/\(scriptName)"
        let hookEntry: [[String: Any]] = [["type": "command", "command": command]]
        let hookEntryWithTimeout: [[String: Any]] = [["type": "command", "command": command, "timeout": 86400]]
        let withMatcher: [[String: Any]] = [["matcher": "*", "hooks": hookEntry]]
        let withMatcherAndTimeout: [[String: Any]] = [["matcher": "*", "hooks": hookEntryWithTimeout]]
        let withoutMatcher: [[String: Any]] = [["hooks": hookEntry]]
        let preCompactConfig: [[String: Any]] = [
            ["matcher": "auto", "hooks": hookEntry],
            ["matcher": "manual", "hooks": hookEntry],
        ]

        var hookEvents: [(String, [[String: Any]])] = [
            ("UserPromptSubmit", withoutMatcher),
            ("PreToolUse", withMatcher),
            ("PostToolUse", withMatcher),
            ("Notification", withMatcher),
            ("Stop", withoutMatcher),
            // REQ-022 后续批:CC 错误 → 设备 TASK_ERROR。
            // StopFailure = turn 因 API 错误结束(CLI 2.1.81 实测触发,payload 含 error 短码);
            // PostToolUseFailure = 单工具失败(只计数不响铃)。均 fire-and-forget,不阻塞。
            ("StopFailure", withoutMatcher),
            ("PostToolUseFailure", withMatcher),
            ("SessionStart", withoutMatcher),
            ("SessionEnd", withoutMatcher),
            ("PreCompact", preCompactConfig),
        ]

        if !skipPermission {
            hookEvents.append(("PermissionRequest", withMatcherAndTimeout))
        }

        var hooks = json["hooks"] as? [String: Any] ?? [:]

        for (event, config) in hookEvents {
            if var existingEvent = hooks[event] as? [[String: Any]] {
                let hasOurHook = existingEvent.contains { entry in
                    if let entryHooks = entry["hooks"] as? [[String: Any]] {
                        return entryHooks.contains { h in
                            let cmd = h["command"] as? String ?? ""
                            return cmd.contains(scriptName)
                        }
                    }
                    return false
                }
                if !hasOurHook {
                    existingEvent.append(contentsOf: config)
                    hooks[event] = existingEvent
                }
            } else {
                hooks[event] = config
            }
        }

        json["hooks"] = hooks

        if let data = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: settingsURL)
        }

        logger.info("Updated settings.json with \(hookEvents.count) hook events")
    }

    /// Uninstall hooks from settings.json and remove script
    static func uninstall() {
        let claudeDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude")
        let hooksDir = claudeDir.appendingPathComponent("hooks")
        let pythonScript = hooksDir.appendingPathComponent(scriptName)
        let settings = claudeDir.appendingPathComponent("settings.json")

        try? FileManager.default.removeItem(at: pythonScript)

        guard let data = try? Data(contentsOf: settings),
              var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var hooks = json["hooks"] as? [String: Any] else { return }

        for (event, value) in hooks {
            if var entries = value as? [[String: Any]] {
                entries.removeAll { entry in
                    if let entryHooks = entry["hooks"] as? [[String: Any]] {
                        return entryHooks.contains { hook in
                            let cmd = hook["command"] as? String ?? ""
                            return cmd.contains(scriptName)
                        }
                    }
                    return false
                }
                if entries.isEmpty {
                    hooks.removeValue(forKey: event)
                } else {
                    hooks[event] = entries
                }
            }
        }

        if hooks.isEmpty { json.removeValue(forKey: "hooks") } else { json["hooks"] = hooks }

        if let data = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: settings)
        }
        logger.info("Uninstalled VibeEverything hooks")
    }

    private static func detectPython() -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = ["python3"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus == 0 { return "python3" }
        } catch {}
        return "python"
    }
}
