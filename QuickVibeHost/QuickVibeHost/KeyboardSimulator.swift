import AppKit
import Carbon.HIToolbox
import os

enum KeyboardSimulator {
    enum MediaKey: Int {
        case volumeUp = 0
        case volumeDown = 1
        case playPause = 16
        case nextTrack = 17
        case previousTrack = 18
    }

    private static let logger = Logger(subsystem: "com.vibeeverything.QuickVibeHost", category: "Keyboard")

    // Diagnostics state (see plan: moonlit-prancing-whale.md — 改动 1/2).
    // nonisolated(unsafe): accessed from typeText which may be invoked off main thread.
    nonisolated(unsafe) private static var lastTypeTextAt: Date?
    nonisolated(unsafe) private static var typeTextCounter: UInt32 = 0
    nonisolated(unsafe) private static var hasPromptedForAccessibilityPermission = false

    /// Type text into the current active app.
    ///
    /// BUG-003: 默认走 CGEvent Unicode 分块注入(不碰剪贴板,无回写竞态);
    /// 剪贴板+Cmd+V 保留为兜底,现场回退开关:
    ///   defaults write com.vibeeverything.QuickVibeHost textInjectionMode clipboard
    static func typeText(_ text: String) {
        guard !text.isEmpty else { return }
        guard ensureAccessibilityPermission("typeText") else { return }
        let mode = UserDefaults.standard.string(forKey: "textInjectionMode") ?? "unicode"
        if mode == "clipboard" {
            typeTextViaClipboard(text)
        } else {
            typeTextViaUnicodeEvents(text)
        }
    }

    /// Paste user-authored prompt text. Multi-line prompts need paste
    /// semantics; unicode key events are typing semantics and mangle newlines.
    static func typePromptText(_ text: String) {
        guard !text.isEmpty else { return }
        guard ensureAccessibilityPermission("typePromptText") else { return }
        typeTextViaClipboard(text)
    }

    /// Replace the target app's current selection with paste semantics and wait
    /// until the target has had enough time to consume the clipboard. The caller
    /// owns focus/selection validation before and content verification after this call.
    static func pasteReplacingCurrentSelection(_ text: String) async -> Bool {
        guard !text.isEmpty, ensureAccessibilityPermission("pasteReplacingCurrentSelection") else { return false }
        return await withCheckedContinuation { continuation in
            clipboardInjectQueue.async {
                let pasteboard = NSPasteboard.general
                let savedItems = pasteboard.pasteboardItems?.compactMap { item -> [NSPasteboard.PasteboardType: Data] in
                    var saved: [NSPasteboard.PasteboardType: Data] = [:]
                    for type in item.types {
                        if let data = item.data(forType: type) { saved[type] = data }
                    }
                    return saved
                } ?? []
                pasteboard.clearContents()
                guard pasteboard.setString(text, forType: .string) else {
                    continuation.resume(returning: false)
                    return
                }
                let expectedChangeCount = pasteboard.changeCount
                let source = CGEventSource(stateID: .hidSystemState)
                let posted = postWithSelfInjectMark(source: source, keyCode: 0x09, flags: .maskCommand)
                Thread.sleep(forTimeInterval: 0.8)
                if pasteboard.changeCount == expectedChangeCount,
                   pasteboard.string(forType: .string) == text {
                    pasteboard.clearContents()
                    for itemDictionary in savedItems {
                        let item = NSPasteboardItem()
                        for (type, data) in itemDictionary { item.setData(data, forType: type) }
                        pasteboard.writeObjects([item])
                    }
                }
                ClaudeCodeSessionManager.log("[InputAssistant] keyboard paste posted=\(posted) chars=\(text.count)")
                continuation.resume(returning: posted)
            }
        }
    }

    /// Read the whole contents of a focused control that does not expose an AX
    /// value (notably WeChat's chat composer). The caller must restrict where
    /// this fallback is allowed. Clipboard contents are restored before return.
    static func copyWholeCurrentField(collapseSelectionAfterCopy: Bool) async -> String? {
        guard ensureAccessibilityPermission("copyWholeCurrentField"), !IsSecureEventInputEnabled() else { return nil }
        return await withCheckedContinuation { continuation in
            clipboardInjectQueue.async {
                let pasteboard = NSPasteboard.general
                let savedItems = pasteboard.pasteboardItems?.compactMap { item -> [NSPasteboard.PasteboardType: Data] in
                    var saved: [NSPasteboard.PasteboardType: Data] = [:]
                    for type in item.types {
                        if let data = item.data(forType: type) { saved[type] = data }
                    }
                    return saved
                } ?? []
                pasteboard.clearContents()

                let source = CGEventSource(stateID: .hidSystemState)
                let selected = postWithSelfInjectMark(source: source, keyCode: 0x00, flags: .maskCommand) // Cmd+A
                Thread.sleep(forTimeInterval: 0.10)
                let copied = postWithSelfInjectMark(source: source, keyCode: 0x08, flags: .maskCommand) // Cmd+C
                Thread.sleep(forTimeInterval: 0.20)
                let text = selected && copied ? pasteboard.string(forType: .string) : nil

                if collapseSelectionAfterCopy {
                    _ = postWithSelfInjectMark(source: source, keyCode: 0x7C, flags: []) // Right arrow
                    Thread.sleep(forTimeInterval: 0.04)
                }
                pasteboard.clearContents()
                for itemDictionary in savedItems {
                    let item = NSPasteboardItem()
                    for (type, data) in itemDictionary { item.setData(data, forType: type) }
                    pasteboard.writeObjects([item])
                }
                ClaudeCodeSessionManager.log("[InputAssistant] keyboard copy posted=\(selected && copied) chars=\(text?.count ?? 0)")
                continuation.resume(returning: text)
            }
        }
    }

    /// 串行注入队列:chunk 间 usleep 步进不能占用调用方线程(调用方基本是
    /// MainActor,长文本会卡 UI 并拖慢 hotkey event tap);串行保证多次
    /// typeText 之间不交错。
    private static let unicodeInjectQueue = DispatchQueue(
        label: "com.vibeeverything.QuickVibeHost.unicodeInject", qos: .userInteractive)
    private static let clipboardInjectQueue = DispatchQueue(
        label: "com.vibeeverything.QuickVibeHost.clipboardInject", qos: .userInteractive)

    /// L1 主路径:每个合成 keyDown 事件携带 ≤20 个 UTF-16 code units
    /// (CGEventKeyboardSetUnicodeString 的系统截断上限,espanso/Hammerspoon 同法),
    /// 目标 app 直接从事件取字符串,全程不依赖剪贴板。
    private static func typeTextViaUnicodeEvents(_ text: String) {
        typeTextCounter &+= 1
        let tid = typeTextCounter
        lastTypeTextAt = Date()
        // 环境快照在调用方线程取(请求时刻的 frontApp 才有诊断意义)
        let frontApp = currentFrontAppBundleId()
        let inputSourceId = currentInputSourceId()

        unicodeInjectQueue.async {
            let entryAt = Date()
            let source = CGEventSource(stateID: .hidSystemState)
            let units = Array(text.utf16)
            var chunks = 0
            var postFailures = 0
            var idx = 0
            while idx < units.count {
                var end = min(idx + 20, units.count)
                // 不拆散 surrogate pair(emoji 等 BMP 外字符占 2 个 code unit)
                if end < units.count, UTF16.isLeadSurrogate(units[end - 1]) { end -= 1 }
                var chunk = Array(units[idx..<end])
                idx = end
                chunks += 1

                for keyDown in [true, false] {
                    guard let ev = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: keyDown) else {
                        postFailures += 1
                        continue
                    }
                    ev.flags = []   // 剥离用户残留修饰键(日志中见过 0x100/⌘ 残留)
                    if keyDown {
                        ev.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: &chunk)
                    }
                    // 自注入标记:当前无 tap 消费,保留供将来事件过滤用
                    ev.setIntegerValueField(.eventSourceUserData, value: SELF_INJECT_SIGNATURE)
                    ev.post(tap: .cgSessionEventTap)
                }
                usleep(2000)   // chunk 间 2ms,防事件乱序/目标 app 丢事件
            }

            let elapsedMs = Int(Date().timeIntervalSince(entryAt) * 1000)
            ClaudeCodeSessionManager.log(
                "[typeText tid=\(tid)] unicode-inject chars=\(text.count) utf16=\(units.count) chunks=\(chunks) "
                + "postFailures=\(postFailures) elapsedMs=\(elapsedMs) frontApp=\(frontApp) inputSource=\(inputSourceId)"
            )
            logger.info("Typed \(text.count) characters via unicode events tid=\(tid) chunks=\(chunks) failures=\(postFailures)")
        }
    }

    /// L2 兜底:剪贴板 + Cmd+V(原实现,含诊断探针)。已知缺陷:目标 app 的
    /// paste 处理晚于剪贴板回写时会贴出旧内容(BUG-003),仅在 unicode 注入
    /// 对特定目标 app 失效时手动切换使用。
    private static func typeTextViaClipboard(_ text: String) {
        clipboardInjectQueue.async {
            typeTextViaClipboardOnQueue(text)
        }
    }

    private static func typeTextViaClipboardOnQueue(_ text: String) {
        // ——— Diagnostic prelude (see plan: moonlit-prancing-whale.md) ———
        typeTextCounter &+= 1
        let tid = typeTextCounter
        let entryAt = Date()
        let sinceLastMs: Int
        if let last = lastTypeTextAt {
            sinceLastMs = Int(entryAt.timeIntervalSince(last) * 1000)
        } else {
            sinceLastMs = -1
        }
        lastTypeTextAt = entryAt

        let pasteboard = NSPasteboard.general
        let startClipString = pasteboard.string(forType: .string)
        let pbChangeCountBefore = pasteboard.changeCount
        let flagsAtEnter = currentFlagsStateHex()
        let frontApp = currentFrontAppBundleId()
        let inputSourceId = currentInputSourceId()

        // Save current pasteboard content
        let savedItems = pasteboard.pasteboardItems?.compactMap { item -> [NSPasteboard.PasteboardType: Data] in
            var dict = [NSPasteboard.PasteboardType: Data]()
            for type in item.types {
                if let data = item.data(forType: type) {
                    dict[type] = data
                }
            }
            return dict
        } ?? []
        let savedTypesCount = savedItems.reduce(0) { $0 + $1.count }

        ClaudeCodeSessionManager.log(
            "[typeText tid=\(tid)] enter chars=\(text.count) startClipHash=\(hashForLog(startClipString)) "
            + "pbChangeCountBefore=\(pbChangeCountBefore) savedTypes=\(savedTypesCount) "
            + "sinceLastMs=\(sinceLastMs) frontApp=\(frontApp) inputSource=\(inputSourceId) "
            + "flagsStateAtEnter=\(flagsAtEnter)"
        )

        // Set recognized text
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        let pbChangeCountAfterSet = pasteboard.changeCount

        // Simulate Cmd+V
        let source = CGEventSource(stateID: .hidSystemState)
        let vKeyCode: CGKeyCode = 0x09 // kVK_ANSI_V

        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: true)
        keyDown?.flags = .maskCommand
        keyDown?.post(tap: .cgSessionEventTap)

        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: false)
        keyUp?.flags = .maskCommand
        keyUp?.post(tap: .cgSessionEventTap)

        // Optional Command-flag residue clear — feature-gated, default OFF.
        // Enable via: `defaults write com.vibeeverything.QuickVibeHost keyboardFlagsResetEnabled -bool true`
        if UserDefaults.standard.bool(forKey: "keyboardFlagsResetEnabled") {
            let resetFlags = CGEvent(source: source)
            resetFlags?.type = .flagsChanged
            resetFlags?.flags = []
            resetFlags?.post(tap: .cgSessionEventTap)
        }

        let postedElapsedMs = Int(Date().timeIntervalSince(entryAt) * 1000)
        let flagsAfterPost = currentFlagsStateHex()
        ClaudeCodeSessionManager.log(
            "[typeText tid=\(tid)] posted chars=\(text.count) postedElapsedMs=\(postedElapsedMs) "
            + "pbChangeCountAfterSet=\(pbChangeCountAfterSet) flagsStateAfterPost=\(flagsAfterPost)"
        )
        logger.info("Typed \(text.count) characters tid=\(tid)")

        // Debug A/B switch for clipboard restore delay.
        // - Default (1.0s): observation mode. Lets diagnostic probes at
        //   50/100/150 ms sample pbChangeCount within the restore window —
        //   useful for catching third-party clipboard mutators (e.g. WeType
        //   IME) that write back to the pasteboard after reading our text.
        // - Fast (0.03s): experiment mode. Shrinks the window third-party
        //   clipboard watchers have to latch the ASR text. Enable via:
        //     defaults write com.vibeeverything.QuickVibeHost clipboardRestoreFast -bool true
        //   When fast mode is on, probes are disabled (they'd all fire after
        //   restore and give noise).
        // See plan: mighty-squishing-pelican.md — Step 1 & Step 2.
        let fastRestore = UserDefaults.standard.bool(forKey: "clipboardRestoreFast")
        let restoreDelaySec: Double = fastRestore ? 0.03 : 1.0

        if !fastRestore {
            let expectedChangeCountAfterSet = pbChangeCountAfterSet
            for (idx, ms) in [50, 100, 150].enumerated() {
                DispatchQueue.main.asyncAfter(deadline: .now() + Double(ms) / 1000.0) {
                    let cc = pasteboard.changeCount
                    let clip = pasteboard.string(forType: .string)
                    let drift = cc - expectedChangeCountAfterSet
                    ClaudeCodeSessionManager.log(
                        "[typeText tid=\(tid)] probe#\(idx + 1) at=\(ms)ms pbChangeCount=\(cc) drift=\(drift) clipHash=\(hashForLog(clip))"
                    )
                }
            }
        }

        let restoreScheduledAt = Date()
        let textForRestoreCheck = text
        Thread.sleep(forTimeInterval: restoreDelaySec)
        let restoreDelayMs = Int(Date().timeIntervalSince(restoreScheduledAt) * 1000)
        let clipNow = pasteboard.string(forType: .string)
        let pbChangeCountBeforeRestore = pasteboard.changeCount
        let matchesOurText = (clipNow == textForRestoreCheck)
        ClaudeCodeSessionManager.log(
            "[typeText tid=\(tid)] restore delayMs=\(restoreDelayMs) mode=\(fastRestore ? "fast" : "obs") "
            + "clipNowHash=\(hashForLog(clipNow)) "
            + "pbChangeCountBeforeRestore=\(pbChangeCountBeforeRestore) matchesOurText=\(matchesOurText ? "Y" : "N") "
            + "restoredTypes=\(savedTypesCount)"
        )
        guard pbChangeCountBeforeRestore == pbChangeCountAfterSet && matchesOurText else {
            ClaudeCodeSessionManager.log("[typeText tid=\(tid)] restore skipped: pasteboard changed after set")
            return
        }
        pasteboard.clearContents()
        for itemDict in savedItems {
            let item = NSPasteboardItem()
            for (type, data) in itemDict {
                item.setData(data, forType: type)
            }
            pasteboard.writeObjects([item])
        }
    }

    /// Simulate pressing the Return/Enter key.
    static func pressEnter() {
        logEnvSnapshot("pressEnter")
        let source = CGEventSource(stateID: .hidSystemState)
        let returnKeyCode: CGKeyCode = 0x24 // kVK_Return
        if postWithSelfInjectMark(source: source, keyCode: returnKeyCode, flags: []) {
            logger.info("Simulated Enter key")
        }
    }

    /// Simulate pressing the Escape key.
    static func pressEscape() {
        logEnvSnapshot("pressEscape")
        let source = CGEventSource(stateID: .hidSystemState)
        let escKeyCode: CGKeyCode = 0x35 // kVK_Escape
        if postWithSelfInjectMark(source: source, keyCode: escKeyCode, flags: []) {
            logger.info("Simulated Escape key")
        }
    }

    /// Simulate pressing the Up Arrow key.
    static func pressUpArrow() {
        logEnvSnapshot("pressUpArrow")
        let source = CGEventSource(stateID: .hidSystemState)
        let keyCode: CGKeyCode = 0x7E // kVK_UpArrow
        if postWithSelfInjectMark(source: source, keyCode: keyCode, flags: []) {
            logger.info("Simulated Up Arrow key")
        }
    }

    /// Simulate pressing the Down Arrow key.
    static func pressDownArrow() {
        logEnvSnapshot("pressDownArrow")
        let source = CGEventSource(stateID: .hidSystemState)
        let keyCode: CGKeyCode = 0x7D // kVK_DownArrow
        if postWithSelfInjectMark(source: source, keyCode: keyCode, flags: []) {
            logger.info("Simulated Down Arrow key")
        }
    }

    /// Simulate a generic key + modifier combo (e.g. Shift+Tab).
    /// All self-injected events carry `SELF_INJECT_SIGNATURE` (see
    /// `KeyboardAction.swift`) in `.eventSourceUserData` so our own event
    /// taps can identify and pass them through instead of suppressing.
    static func pressKeyCombo(_ keyCode: CGKeyCode, modifiers: CGEventFlags) {
        logEnvSnapshot("pressKeyCombo[\(String(format: "0x%02X", keyCode))+0x\(String(modifiers.rawValue, radix: 16))]")
        let source = CGEventSource(stateID: .hidSystemState)
        if postWithSelfInjectMark(source: source, keyCode: keyCode, flags: modifiers) {
            logger.info("Simulated keyCombo 0x\(String(keyCode, radix: 16)) flags=0x\(String(modifiers.rawValue, radix: 16))")
        }
    }

    /// Post a macOS system-defined media-key press. This keeps Music Mode
    /// useful for Apple Music and for any other player the user binds later.
    static func pressMediaKey(_ key: MediaKey) {
        guard ensureAccessibilityPermission("pressMediaKey") else { return }
        for state in [0xA, 0xB] { // NX_KEYDOWN, then NX_KEYUP
            let data1 = (key.rawValue << 16) | (state << 8)
            let event = NSEvent.otherEvent(
                with: .systemDefined,
                location: .zero,
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: 0,
                context: nil,
                subtype: 8,
                data1: data1,
                data2: -1
            )
            event?.cgEvent?.post(tap: CGEventTapLocation.cghidEventTap)
        }
        logger.info("Simulated media key \(key.rawValue)")
    }

    /// Keep a modifier physically down across multiple synthetic key events.
    /// Used by the device's hold-C application switcher gesture.
    static func setModifierKey(_ keyCode: CGKeyCode, isDown: Bool, flags: CGEventFlags) {
        guard ensureAccessibilityPermission("setModifierKey") else { return }
        let source = CGEventSource(stateID: .hidSystemState)
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: isDown) else { return }
        event.flags = flags
        event.setIntegerValueField(.eventSourceUserData, value: SELF_INJECT_SIGNATURE)
        event.post(tap: .cgSessionEventTap)
    }

    @discardableResult
    private static func postWithSelfInjectMark(source: CGEventSource?, keyCode: CGKeyCode, flags: CGEventFlags) -> Bool {
        guard ensureAccessibilityPermission("postKey") else { return false }
        if let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true) {
            if !flags.isEmpty { down.flags = flags }
            down.setIntegerValueField(.eventSourceUserData, value: SELF_INJECT_SIGNATURE)
            down.post(tap: .cgSessionEventTap)
        }
        if let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) {
            if !flags.isEmpty { up.flags = flags }
            up.setIntegerValueField(.eventSourceUserData, value: SELF_INJECT_SIGNATURE)
            up.post(tap: .cgSessionEventTap)
        }
        return true
    }

    /// Structured pre-post environment snapshot for Cmd+V / Return / ESC
    /// key simulation. Captures the four variables most likely to swallow a
    /// CGEvent post: frontmost app (did we activate the wrong window?), input
    /// source (CJK IME composition state?), modifier flags (Command/Opt stuck
    /// from a prior paste?), and Secure Event Input (another app's password
    /// field blocking all posts).
    /// See plan: luminous-crunching-journal.md (改动 2).
    private static func logEnvSnapshot(_ label: String) {
        let frontApp = currentFrontAppBundleId()
        let inputSource = currentInputSourceId()
        let flags = currentFlagsStateHex()
        let secure = IsSecureEventInputEnabled() ? "Y" : "N"
        // ax=N 是最常见的"合成按键飘忽"元凶 —— 尤其 Xcode debug 构建重签名后
        // 授权会半失效。先看这一项能省很多弯路。详见 MEMORY/feedback_accessibility_stale.md。
        let ax = AXIsProcessTrusted() ? "Y" : "N"
        // Use os.Logger (same stream as "Simulated Enter key") so `log stream
        // --predicate 'subsystem == "com.vibeeverything.QuickVibeHost"'`
        // surfaces this alongside routeControl. Also mirror to file log for
        // offline analysis.
        logger.info(
            "[\(label) env] frontApp=\(frontApp, privacy: .public) inputSource=\(inputSource, privacy: .public) flagsState=\(flags, privacy: .public) secureInput=\(secure, privacy: .public) ax=\(ax, privacy: .public)"
        )
        ClaudeCodeSessionManager.log(
            "[\(label) env] frontApp=\(frontApp) inputSource=\(inputSource) "
            + "flagsState=\(flags) secureInput=\(secure) ax=\(ax)"
        )
    }

    /// Check if Accessibility permission is granted.
    static var hasAccessibilityPermission: Bool {
        AXIsProcessTrusted()
    }

    static var isSecureInputEnabled: Bool {
        IsSecureEventInputEnabled()
    }

    private static func ensureAccessibilityPermission(_ action: String) -> Bool {
        guard AXIsProcessTrusted() else {
            requestAccessibilityPermissionIfNeeded()
            ClaudeCodeSessionManager.log("[KeyboardSimulator] drop \(action): Accessibility not trusted")
            logger.warning("drop \(action, privacy: .public): Accessibility not trusted")
            return false
        }
        hasPromptedForAccessibilityPermission = false
        return true
    }

    private static func requestAccessibilityPermissionIfNeeded() {
        guard !hasPromptedForAccessibilityPermission else { return }
        hasPromptedForAccessibilityPermission = true
        requestAccessibilityPermission()
    }

    /// Prompt user for Accessibility permission.
    static func requestAccessibilityPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    // MARK: - Diagnostic helpers

    /// Stable FNV-1a 32-bit hash (first 4 hex digits) + length. Used to fingerprint clipboard
    /// content without logging plaintext.
    private static func hashForLog(_ s: String?) -> String {
        guard let s, !s.isEmpty else { return "crc:----,len:0" }
        var h: UInt32 = 2166136261
        for byte in s.utf8 {
            h ^= UInt32(byte)
            h = h &* 16777619
        }
        return String(format: "crc:%04X,len:%d", h & 0xFFFF, s.count)
    }

    private static func currentFrontAppBundleId() -> String {
        runOnMainForSnapshot {
            NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "<unknown>"
        }
    }

    private static func currentInputSourceId() -> String {
        runOnMainForSnapshot {
            currentInputSourceIdOnMain()
        }
    }

    private static func currentInputSourceIdOnMain() -> String {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else {
            return "<nil>"
        }
        guard let ptr = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else {
            return "<nil>"
        }
        return Unmanaged<CFString>.fromOpaque(ptr).takeUnretainedValue() as String
    }

    private static func runOnMainForSnapshot<T>(_ work: @escaping () -> T) -> T {
        Thread.isMainThread ? work() : DispatchQueue.main.sync(execute: work)
    }

    private static func currentFlagsStateHex() -> String {
        let raw = CGEventSource.flagsState(.combinedSessionState).rawValue
        return String(format: "0x%X", raw)
    }
}
