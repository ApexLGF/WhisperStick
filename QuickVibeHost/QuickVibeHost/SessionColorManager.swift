import Foundation
import SwiftUI
import os

@MainActor
final class SessionColorManager: ObservableObject {
    static let shared = SessionColorManager()

    private static let logger = Logger(subsystem: "com.vibeeverything.QuickVibeHost", category: "SessionColor")

    /// Claude Code built-in colors (canonical 11 色,顺序不可变:
    /// 协议 colorIdx 编码与固件端调色板按此索引对齐,vibepty pid 公式同源)
    static let assignableColors: [String] = [
        "red", "blue", "green", "yellow", "orange",
        "purple", "cyan", "magenta", "pink", "white", "gray"
    ]

    /// white 重映射池(REQ-018):white 作为身份色在浅色模式下不可读(竖条/选中
    /// tint/审批框对比率≈1.0),pid 公式命中 white 时确定性二次映射到此 10 色池。
    /// 保持 canonical 列表与 %11 模数不变 —— 只有 white 命中的 1/11 会话换色,
    /// 其余 pid 颜色不动,不破坏与存量 vibepty 横幅的跨进程一致性。
    /// ⚠ 此规则与 vibepty.py 的 SESSION_COLORS_NO_WHITE 必须同步。
    static let whiteSubstitutePool: [String] = [
        "red", "blue", "green", "yellow", "orange",
        "purple", "cyan", "magenta", "pink", "gray"
    ]

    /// pid → 颜色名(含 white 重映射);Mac / vibepty 共用的公式单一来源
    static func colorName(forPid pid: Int) -> String {
        var name = assignableColors[pid % assignableColors.count]
        if name == "white" {
            name = whiteSubstitutePool[pid % whiteSubstitutePool.count]
        }
        return name
    }

    /// sessionId → colorName. Intentionally NOT @Published: callers read this
    /// via function calls during view body (StatusTab.hookSessionRow), and
    /// lazy assignment would trigger "Publishing changes from within view
    /// updates" warnings. Views re-render via hookStore.sessions instead;
    /// colors stay stable once assigned, so no observer is needed.
    private(set) var colorMap: [String: String] = [:]

    private let storageKey = "sessionColorMap"
    private var nextColorIndex = 0

    private init() {
        load()
    }

    /// Assign or retrieve color for a session. When `pid` is known, the
    /// pid-based formula is authoritative and overrides any stale persisted
    /// value (e.g. legacy round-robin assignment from before the pid scheme
    /// was introduced). This keeps Mac App, BLE device, and the vibepty
    /// terminal banner all showing the same hue for the same session.
    ///
    /// When `pid` is nil (rare — seed before hook delivers pid), falls back
    /// to round-robin against any persisted value.
    ///
    /// Note: no collision avoidance by design. Two concurrently-live sessions
    /// whose pids share the same `% 11` residue get the same color. The
    /// alternative (round-robin) would break cross-process agreement with
    /// vibepty, which is the harder property to recover.
    func colorForSession(_ sessionId: String, pid: Int? = nil) -> String {
        if let pid, pid > 0 {
            let pidColor = Self.colorName(forPid: pid)
            if colorMap[sessionId] != pidColor {
                colorMap[sessionId] = pidColor
                save()
                Self.logger.info("Color for \(sessionId.prefix(8), privacy: .public) pid=\(pid) → \(pidColor, privacy: .public) (pid-formula)")
            }
            return pidColor
        }
        if let existing = colorMap[sessionId] {
            return existing
        }
        // 轮转兜底同样避开 white(REQ-018)
        let color = Self.whiteSubstitutePool[nextColorIndex % Self.whiteSubstitutePool.count]
        nextColorIndex += 1
        colorMap[sessionId] = color
        save()
        Self.logger.info("Color for \(sessionId.prefix(8), privacy: .public) → \(color, privacy: .public) (round-robin, pid unknown)")
        return color
    }

    /// Get the color index (0-10) for BLE transmission
    func colorIndexForSession(_ sessionId: String, pid: Int? = nil) -> UInt8 {
        let color = colorForSession(sessionId, pid: pid)
        return UInt8(Self.assignableColors.firstIndex(of: color) ?? 0)
    }

    /// Remove sessions that are no longer active
    func pruneStale(activeIds: Set<String>) {
        let staleKeys = colorMap.keys.filter { !activeIds.contains($0) }
        guard !staleKeys.isEmpty else { return }
        for key in staleKeys { colorMap.removeValue(forKey: key) }
        save()
        Self.logger.info("Pruned \(staleKeys.count) stale color mappings")
    }

    /// 会话色的可读版本(REQ-018):浅色模式下对白底弱对比的色相压暗
    /// (yellow/cyan;white 为遗留兜底退化为中灰)。深色模式下系统语义色
    /// 已自动提亮适配,原样返回。用于会话色作前景的场合:context 竖条填充、
    /// 选中行 tint、审批框边框。
    static func readableColor(for name: String, in scheme: ColorScheme) -> Color {
        guard scheme == .light else { return swiftUIColor(for: name) }
        switch name {
        case "white":  return Color(white: 0.55)
        case "yellow": return Color(red: 0.72, green: 0.55, blue: 0.0)
        case "cyan":   return Color(red: 0.0, green: 0.50, blue: 0.65)
        default:       return swiftUIColor(for: name)
        }
    }

    /// SwiftUI Color for a given color name
    static func swiftUIColor(for name: String) -> Color {
        switch name {
        case "red": return .red
        case "blue": return .blue
        case "green": return .green
        case "yellow": return .yellow
        case "orange": return .orange
        case "purple": return .purple
        case "cyan": return .cyan
        case "magenta": return Color(.magenta)
        case "pink": return .pink
        case "white": return .white
        case "gray": return .gray
        default: return .gray
        }
    }

    // MARK: - Persistence

    private func save() {
        UserDefaults.standard.set(colorMap, forKey: storageKey)
    }

    private func load() {
        if let saved = UserDefaults.standard.dictionary(forKey: storageKey) as? [String: String] {
            colorMap = saved
            // Resume nextColorIndex to avoid re-assigning recent colors
            nextColorIndex = saved.count
            // REQ-018 一次性迁移:历史 white 分配重映射(pid 已知的会话下次
            // colorForSession 会被 pid 公式覆盖;这里兜底 pid-nil 的遗留项)
            let whiteSids = colorMap.filter { $0.value == "white" }.map(\.key)
            if !whiteSids.isEmpty {
                for sid in whiteSids { colorMap[sid] = "gray" }
                save()
                Self.logger.info("Migrated \(whiteSids.count) legacy white assignments → gray")
            }
        }
    }
}
