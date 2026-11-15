import AppKit
import Foundation
import os

/// Brings the terminal host app of a claude session to the foreground.
///
/// Step 2 scope: best-effort activation. We resolve the host app via
/// `ClaudeCodeSessionManager`'s process-tree walk (already cached), map it to
/// a running `NSRunningApplication`, and activate. Failures log a warning but
/// never throw — later steps decide what UX to show.
enum SessionActivator {
    private static let logger = Logger(subsystem: "com.vibeeverything.QuickVibeHost", category: "Activator")

    /// BUG-005:「打开窗口」按钮用的非阻塞版。同步版在高负载机器上会把主线程卡 2-3s
    /// (fork ps 解析进程树 + AX 窗口枚举 IPC + NSAppleScript 等目标 app 应答)。
    /// 此版:缓存查找留在主线程(纯内存),其余全部后台;激活用 LaunchServices
    /// (`/usr/bin/open -b`)替代 Apple Event——不等目标 app 事件循环、免 Automation TCC。
    /// 语义:按钮含义就是"把窗口带到前台",无状态高亮绑定,异步无误导。
    /// 同步版保留给自由回退 JIT(键盘模拟必须等焦点落定,见 InputRouter.fallbackToFree)。
    @MainActor
    static func bringToFrontAsync(session: HookSession, sessionManager: ClaudeCodeSessionManager) {
        guard let pid = session.pid else {
            logger.warning("async activate: no pid for session \(session.id.prefix(8), privacy: .public)")
            return
        }
        // 缓存命中路径(纯内存)在主线程取;miss 时进程树解析(fork ps)留给后台
        let cachedHost = sessionManager.sessions.first(where: { $0.pid == pid })?.hostApp
        Task.detached(priority: .userInitiated) {
            guard let hostAppPath = cachedHost ?? ClaudeCodeSessionManager.resolveHostApp(forPid: pid) else {
                logger.warning("async activate: no hostApp for pid \(pid)")
                return
            }
            guard let bundle = Bundle(path: hostAppPath), let bid = bundle.bundleIdentifier else {
                logger.warning("async activate: no bundleIdentifier for \(hostAppPath, privacy: .public)")
                return
            }
            // NSRunningApplication 类方法/属性读非 UI 对象(workspace 查询包装),
            // 后台线程调用是常见用法,非 main-thread-only(review 已核)
            guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bid).first else {
                logger.warning("async activate: no running instance for \(bid, privacy: .public)")
                return
            }
            if app.isHidden { _ = await MainActor.run { app.unhide() } }
            unminimizeIfAllMinimized(app: app)   // AX IPC:后台线程阻塞无妨
            // LaunchServices 激活:open 对已运行 app 即"带到前台",子进程等待在后台线程
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            proc.arguments = ["-b", bid]
            guard (try? proc.run()) != nil else {
                logger.warning("async activate: open 启动失败 bid=\(bid, privacy: .public)")
                return   // 未启动的 Process 调 waitUntilExit 是无效用法(Foundation 断言)
            }
            proc.waitUntilExit()
            logger.info("async activate \(bid, privacy: .public) pid=\(pid) open-status=\(proc.terminationStatus)")
        }
    }

    @discardableResult
    @MainActor
    static func bringToFront(session: HookSession, sessionManager: ClaudeCodeSessionManager) -> Bool {
        guard let pid = session.pid else {
            logger.warning("no pid for session \(session.id.prefix(8), privacy: .public)")
            return false
        }
        guard let hostAppPath = hostAppPath(forPid: pid, sessionManager: sessionManager) else {
            logger.warning("no hostApp resolved for pid \(pid)")
            return false
        }
        guard let bundle = Bundle(path: hostAppPath),
              let bid = bundle.bundleIdentifier else {
            logger.warning("cannot resolve bundleIdentifier for \(hostAppPath, privacy: .public)")
            return false
        }
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: bid)
        guard let app = apps.first else {
            logger.warning("no running instance for bundle \(bid, privacy: .public)")
            return false
        }
        // activate(NS/AppleScript 两条路)都不会恢复已最小化进 Dock 的窗口,先处理这两种收起态:
        // ⌘H 隐藏用 unhide;最小化用 AX 写 AXMinimized(app 已持辅助功能授权,零新增 TCC)。
        if app.isHidden { app.unhide() }
        unminimizeIfAllMinimized(app: app)
        // NSRunningApplication.activate() on macOS 14+ is "polite" — it returns
        // true but won't steal focus from a window the user just clicked into.
        // Call it first, then fall through to AppleScript `activate`, which
        // bypasses the focus-steal guard via the Apple Event path.
        let nsOK = app.activate()
        let scriptOK = activateViaAppleScript(bundleId: bid)
        logger.info("activate \(bid, privacy: .public) pid=\(pid) ns=\(nsOK) osa=\(scriptOK)")
        return nsOK || scriptOK
    }

    /// 宿主 app 的窗口全部处于最小化时,用 AX 恢复它们;只要有一个未最小化窗口就不动
    /// (activate 已足够,避免误恢复用户故意收进 Dock 的其他窗口)。tab 级定位不在本档范围。
    private static func unminimizeIfAllMinimized(app: NSRunningApplication) {
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        var winsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &winsRef) == .success,
              let wins = winsRef as? [AXUIElement], !wins.isEmpty else { return }

        func isMinimized(_ w: AXUIElement) -> Bool {
            var v: CFTypeRef?
            return AXUIElementCopyAttributeValue(w, kAXMinimizedAttribute as CFString, &v) == .success
                && (v as? Bool) == true
        }

        let minimized = wins.filter(isMinimized)
        guard minimized.count == wins.count else { return }   // 还有可见窗口,activate 即可
        for w in minimized {
            AXUIElementSetAttributeValue(w, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        }
        logger.info("unminimized \(minimized.count) window(s) of pid \(app.processIdentifier)")
    }

    /// AppleScript activation — reliably brings an app to front even when
    /// `NSRunningApplication.activate()` is politely ignored by macOS 14+.
    private static func activateViaAppleScript(bundleId: String) -> Bool {
        let src = "tell application id \"\(bundleId)\" to activate"
        guard let script = NSAppleScript(source: src) else { return false }
        var err: NSDictionary?
        _ = script.executeAndReturnError(&err)
        if let err = err {
            logger.warning("osascript activate failed bid=\(bundleId, privacy: .public) err=\(String(describing: err), privacy: .public)")
            return false
        }
        return true
    }

    /// Best-effort pid → hostApp path. Prefers `ClaudeCodeSessionManager`'s
    /// cached mapping (populated during process scans); returns nil when not
    /// yet seen.
    @MainActor
    private static func hostAppPath(forPid pid: Int, sessionManager: ClaudeCodeSessionManager) -> String? {
        if let match = sessionManager.sessions.first(where: { $0.pid == pid }),
           let host = match.hostApp {
            return host
        }
        // CC 进程扫描缓存查不到(codex 会话 / 无 sessions.json 记录)→ 即时进程树解析
        return ClaudeCodeSessionManager.resolveHostApp(forPid: pid)
    }
}
