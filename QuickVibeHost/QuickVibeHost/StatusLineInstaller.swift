import Foundation
import os

/// 安装 Claude Code statusLine wrapper(BUG 修复:OAuth 端点在无代理网络下不可达 → 额度改走本地侧信道)。
///
/// Claude Code 每次刷新状态行时把完整 JSON(含 rate_limits/context_window/cost)喂给
/// statusLine 命令的 stdin。wrapper 把这份 JSON 捕获到 per-session 文件
/// `~/.claude/.quickvibehost/statusline/<session_id>.json`,再 call-through 用户原有的
/// statusLine 命令,原状态行照常渲染。ClaudeUsageManager 本地读取 capture,零网络、零凭据。
///
/// 设计移植自 code-by-wire 的 statusLine wrapper:
/// - stdin 先落 tmp 文件再 mv 原子发布,读端不会看到半写文件
/// - session_id 用 sed 提取(只依赖 sh + sed),含 `/` 的 id 拒绝(防路径穿越)
/// - 全步骤 2>/dev/null + exit 0,wrapper 永不阻塞/失败 prompt
/// - wrapper 自带 find -mtime +7 自清理:app 被删后 capture 目录磁盘占用仍有界
/// - 原命令写入独立的 statusline-original.sh 文件(字节原样,不做文本拼接),wrapper 按
///   该文件是否存在决定 call-through——含引号/反斜杠/换行的原命令不会破坏 wrapper 本体
struct StatusLineInstaller {
    private static let logger = Logger(subsystem: "com.vibeeverything.QuickVibeHost", category: "StatusLineInstaller")

    private static var quickVibeDir: String { NSHomeDirectory() + "/.claude/.quickvibehost" }
    static var captureDir: String { quickVibeDir + "/statusline" }
    static var scriptPath: String { quickVibeDir + "/statusline.sh" }
    private static var originalScriptPath: String { quickVibeDir + "/statusline-original.sh" }
    private static var statePath: String {
        NSHomeDirectory() + "/Library/Application Support/QuickVibeHost/statusline-state.json"
    }
    private static var settingsPath: String { NSHomeDirectory() + "/.claude/settings.json" }

    /// 卸载恢复用的安装记录;不塞进 settings.json(statusLine 块 additionalProperties: false)。
    private struct InstallState: Codable {
        var wrappedCommand: String?   // 被包裹的原 statusLine 命令;nil = 原本没有可用命令
        var hadStatusLine: Bool       // 原本是否存在 statusLine 块(与 wrappedCommand 解耦)
    }

    // MARK: - Install

    static func installIfNeeded() {
        // 文件缺失 = 全新安装可创建;文件存在但解析失败 = 中止,绝不把用户的 hooks/env/permissions
        // 整份覆盖成只剩 statusLine 的空壳(半写/手改坏 JSON 都可能触发)
        var settings: [String: Any] = [:]
        if let data = FileManager.default.contents(atPath: settingsPath) {
            guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                logger.error("settings.json exists but is unparseable — aborting statusLine install")
                return
            }
            settings = json
        }

        let block = settings["statusLine"] as? [String: Any]
        let currentCommand = block?["command"] as? String

        if currentCommand == scriptPath {
            // 已安装:只重新生成脚本(app 升级后 wrapper 逻辑跟新),原命令从 state 取。
            // state 丢失时退化为 capture-only(原命令不可恢复,状态行留空,不猜)。
            writeScript(wrappedCommand: loadState()?.wrappedCommand)
            return
        }

        // 首次安装或用户换过 statusLine:包裹当前命令
        let wrappedCommand = (currentCommand?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap {
            $0.isEmpty ? nil : $0
        }
        saveState(InstallState(wrappedCommand: wrappedCommand, hadStatusLine: block != nil))
        writeScript(wrappedCommand: wrappedCommand)

        // 只动 type/command 两键;padding/refreshInterval 等上游字段原样保留
        var newBlock = block ?? [:]
        newBlock["type"] = "command"
        newBlock["command"] = scriptPath
        settings["statusLine"] = newBlock
        writeSettings(settings)
        logger.info("Installed statusLine wrapper (wrapped: \(wrappedCommand != nil))")
    }

    /// 恢复原 statusLine 配置,删除脚本与 capture 目录
    static func uninstall() {
        if let data = FileManager.default.contents(atPath: settingsPath),
           var settings = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           var block = settings["statusLine"] as? [String: Any],
           block["command"] as? String == scriptPath {
            let state = loadState()
            if state?.hadStatusLine == true, let original = state?.wrappedCommand {
                block["command"] = original
                settings["statusLine"] = block
            } else {
                settings.removeValue(forKey: "statusLine")
            }
            writeSettings(settings)
        }
        try? FileManager.default.removeItem(atPath: quickVibeDir)
        try? FileManager.default.removeItem(atPath: statePath)
        logger.info("Uninstalled statusLine wrapper")
    }

    // MARK: - Wrapper script

    /// wrapper 本体是固定文本,不含任何用户输入——capture 目录与原命令文件都相对脚本自身定位
    /// (${0%/*}),路径或原命令含特殊字符都不会破坏脚本。原命令若自身语法有误,只影响
    /// call-through 那一个子进程,capture 与 exit 0 不受影响。
    private static let wrapperScript = """
    #!/bin/sh
    # QuickVibeHost statusLine wrapper — AUTO-GENERATED, do not edit (regenerated on app launch).
    dir="${0%/*}/statusline"
    mkdir -p "$dir" 2>/dev/null
    find "$dir" -name "*.json*" -mtime +7 -delete 2>/dev/null
    raw="$dir/$$.json.tmp"
    cat > "$raw" 2>/dev/null
    sid=$(sed -n 's/.*"session_id"[[:space:]]*:[[:space:]]*"\\([^"]*\\)".*/\\1/p' "$raw" 2>/dev/null)
    case "$sid" in */*) sid= ;; esac
    if [ -n "$sid" ]; then
      mv -f "$raw" "$dir/$sid.json" 2>/dev/null
      src="$dir/$sid.json"
    else
      src="$raw"
    fi
    orig="${0%/*}/statusline-original.sh"
    if [ -x "$orig" ]; then
      cat "$src" | "$orig"
    fi
    rm -f "$raw" 2>/dev/null
    exit 0

    """

    private static func writeScript(wrappedCommand: String?) {
        let fm = FileManager.default
        try? fm.createDirectory(atPath: captureDir, withIntermediateDirectories: true)
        do {
            try wrapperScript.write(toFile: scriptPath, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptPath)
        } catch {
            logger.error("write wrapper script failed: \(error.localizedDescription)")
        }
        // 原命令单独成文件、字节原样,由 sh 作为完整脚本解释;不存在该文件 = 无 call-through
        if let cmd = wrappedCommand {
            do {
                try "#!/bin/sh\n\(cmd)\n".write(toFile: originalScriptPath, atomically: true, encoding: .utf8)
                try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: originalScriptPath)
            } catch {
                logger.error("write original statusLine script failed: \(error.localizedDescription)")
            }
        } else {
            try? fm.removeItem(atPath: originalScriptPath)
        }
    }

    // MARK: - State / settings IO

    private static func loadState() -> InstallState? {
        guard let data = FileManager.default.contents(atPath: statePath) else { return nil }
        return try? JSONDecoder().decode(InstallState.self, from: data)
    }

    private static func saveState(_ state: InstallState) {
        let url = URL(fileURLWithPath: statePath)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(state) {
            try? data.write(to: url)
        }
    }

    private static func writeSettings(_ settings: [String: Any]) {
        if let data = try? JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: settingsPath))
        }
    }
}
