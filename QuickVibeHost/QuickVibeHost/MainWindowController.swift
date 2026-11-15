import AppKit
import SwiftUI

private enum MainWindowMetrics {
    static let compactWidth: CGFloat = 370
    static let settingsWidth: CGFloat = 620
    static let minHeight: CGFloat = 500
    static let autosaveName = "MainWindow-v3"
}

private enum FirstRunWindowMetrics {
    static let width: CGFloat = 960
    static let height: CGFloat = 640
    static let minWidth: CGFloat = 860
    static let minHeight: CGFloat = 560
}

@MainActor
final class MainWindowController: NSObject, NSWindowDelegate, ObservableObject {
    private var window: NSWindow?
    private var autoExpandedForSettings = false
    private var lastAppliedTab = 0
    private var isFirstRunWindow = false
    nonisolated(unsafe) private var currentMinWidth: CGFloat = MainWindowMetrics.compactWidth
    @Published var isShown = false

    func setupWindow<Content: View>(with rootView: Content) {
        if let window {
            isFirstRunWindow = false
            window.styleMask.insert(.resizable)
            window.styleMask.remove(.fullSizeContentView)
            window.titleVisibility = .visible
            window.titlebarAppearsTransparent = false
            window.isMovableByWindowBackground = false
            let hostingView = NSHostingView(rootView: rootView.frame(minWidth: MainWindowMetrics.compactWidth, minHeight: MainWindowMetrics.minHeight))
            hostingView.sizingOptions = []
            window.contentView = hostingView
            window.setFrameAutosaveName(MainWindowMetrics.autosaveName)
            window.minSize = NSSize(width: MainWindowMetrics.compactWidth, height: MainWindowMetrics.minHeight)
            window.contentMinSize = NSSize(width: MainWindowMetrics.compactWidth, height: MainWindowMetrics.minHeight)
            currentMinWidth = MainWindowMetrics.compactWidth
            return
        }

        guard window == nil else { return }
        isFirstRunWindow = false

        // SwiftUI 侧最小宽约束:NSHostingView 会用内容最小尺寸接管窗口约束,
        // 只设 window.minSize 会被覆盖,必须让 rootView 自带 minWidth。
        let hostingView = NSHostingView(rootView: rootView.frame(minWidth: MainWindowMetrics.compactWidth, minHeight: MainWindowMetrics.minHeight))
        hostingView.sizingOptions = []   // 禁止 SwiftUI 反向改写窗口 min/max,以下方手动值为准
        // 默认撑满屏幕可见高度、默认宽 370(= 最小宽);用户手动调整后通过 setFrameAutosaveName 持久化。
        let screenHeight = NSScreen.main?.visibleFrame.height ?? 900
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: MainWindowMetrics.compactWidth, height: screenHeight),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        window.title = AppBrand.displayName
        window.setFrameAutosaveName(MainWindowMetrics.autosaveName)   // 一次性重置旧 1000px 存档
        window.minSize = NSSize(width: MainWindowMetrics.compactWidth, height: MainWindowMetrics.minHeight)
        window.contentMinSize = NSSize(width: MainWindowMetrics.compactWidth, height: MainWindowMetrics.minHeight)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        self.window = window
    }

    func setupFirstRunWindow<Content: View>(with rootView: Content) {
        isFirstRunWindow = true
        let hostingView = NSHostingView(rootView: rootView.frame(minWidth: FirstRunWindowMetrics.minWidth, minHeight: FirstRunWindowMetrics.minHeight))
        hostingView.sizingOptions = []

        if let window {
            window.styleMask.remove(.resizable)
            window.styleMask.insert(.fullSizeContentView)
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.isMovableByWindowBackground = true
            window.contentView = hostingView
            window.minSize = NSSize(width: FirstRunWindowMetrics.minWidth, height: FirstRunWindowMetrics.minHeight)
            window.contentMinSize = NSSize(width: FirstRunWindowMetrics.minWidth, height: FirstRunWindowMetrics.minHeight)
            currentMinWidth = FirstRunWindowMetrics.minWidth
            window.setContentSize(NSSize(width: FirstRunWindowMetrics.width, height: FirstRunWindowMetrics.height))
            window.center()
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: FirstRunWindowMetrics.width, height: FirstRunWindowMetrics.height),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        window.title = AppBrand.displayName
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.minSize = NSSize(width: FirstRunWindowMetrics.minWidth, height: FirstRunWindowMetrics.minHeight)
        window.contentMinSize = NSSize(width: FirstRunWindowMetrics.minWidth, height: FirstRunWindowMetrics.minHeight)
        window.isReleasedWhenClosed = false
        window.delegate = self
        currentMinWidth = FirstRunWindowMetrics.minWidth
        window.center()
        self.window = window
    }

    func applyLayout(for tab: Int) {
        lastAppliedTab = tab
        let minWidth = tab == 4 ? MainWindowMetrics.settingsWidth : MainWindowMetrics.compactWidth
        currentMinWidth = minWidth
        window?.minSize = NSSize(width: minWidth, height: MainWindowMetrics.minHeight)
        window?.contentMinSize = NSSize(width: minWidth, height: MainWindowMetrics.minHeight)

        guard let window else { return }
        if tab == 4 {
            if window.frame.width != MainWindowMetrics.settingsWidth {
                resizeWindow(toWidth: MainWindowMetrics.settingsWidth)
            }
            autoExpandedForSettings = true
        } else if tab != 4, autoExpandedForSettings || window.frame.width >= MainWindowMetrics.settingsWidth {
            resizeWindow(toWidth: MainWindowMetrics.compactWidth)
            autoExpandedForSettings = false
        }
    }

    private func resizeWindow(toWidth width: CGFloat) {
        guard let window else { return }
        var frame = window.frame
        let midX = frame.midX
        frame.size.width = width
        frame.origin.x = midX - width / 2
        if let visibleFrame = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame {
            if frame.width >= visibleFrame.width {
                frame.origin.x = visibleFrame.minX
            } else {
                frame.origin.x = min(max(frame.origin.x, visibleFrame.minX), visibleFrame.maxX - frame.width)
            }
        }
        window.setFrame(frame, display: true, animate: false)
    }

    func resetAutoExpandedWindow() {
        guard autoExpandedForSettings else { return }
        currentMinWidth = MainWindowMetrics.compactWidth
        window?.minSize = NSSize(width: MainWindowMetrics.compactWidth, height: MainWindowMetrics.minHeight)
        window?.contentMinSize = NSSize(width: MainWindowMetrics.compactWidth, height: MainWindowMetrics.minHeight)
        resizeWindow(toWidth: MainWindowMetrics.compactWidth)
        window?.saveFrame(usingName: MainWindowMetrics.autosaveName)
        autoExpandedForSettings = false
    }

    func toggle() {
        if isShown {
            hide()
        } else {
            show()
        }
    }

    func show() {
        guard let window else { return }
        if !isFirstRunWindow {
            applyLayout(for: lastAppliedTab)
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        isShown = true
    }

    func hide() {
        resetAutoExpandedWindow()
        window?.orderOut(nil)
        isShown = false
    }

    /// ui-smoke 自截图(零 TCC):对 contentView 做 bitmap 缓存渲染写 PNG。
    /// 只截自己窗口内容,不经 CGWindowList/screencapture,无需 Screen Recording 授权。
    func snapshotWindow(to path: String) -> Bool {
        guard let view = window?.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return false }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return false }
        return (try? data.write(to: URL(fileURLWithPath: path))) != nil
    }

    // MARK: - NSWindowDelegate

    /// 强制最小尺寸:minSize/contentMinSize 会被 NSHostingView 的约束体系架空,
    /// delegate 钳制对拖拽/程序化 resize 一律生效,是唯一可靠下限。
    nonisolated func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        NSSize(width: max(frameSize.width, currentMinWidth), height: max(frameSize.height, MainWindowMetrics.minHeight))
    }

    nonisolated func windowShouldClose(_ sender: NSWindow) -> Bool {
        Task { @MainActor in
            self.resetAutoExpandedWindow()
            sender.orderOut(nil)
            self.isShown = false
        }
        return false
    }
}
