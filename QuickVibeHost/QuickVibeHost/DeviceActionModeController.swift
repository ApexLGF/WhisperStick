import AppKit
import ApplicationServices
import os

@MainActor
final class DeviceActionModeController {
    private struct ApplicationFocusSnapshot {
        let processIdentifier: pid_t
        let window: AXUIElement?
        let element: AXUIElement?
        let elementSubrole: String?
    }

    private weak var ble: BLEManager?
    private let sceneModes: SceneModeStore
    private var nativeApplicationSwitcherTimer: Timer?
    private var nativeApplicationSwitcherActive = false
    private var applicationSwitcherTimeoutTimer: Timer?
    private var applicationSwitcherSelection: RunningApplicationSelection?
    private var applicationSwitcherFocusSnapshots: [pid_t: ApplicationFocusSnapshot] = [:]
    private var applicationFocusRestoreTask: Task<Void, Never>?
    private var applicationSwitcherRequestID: UInt8 = 0
    private var recentApplicationBundleIDs: [String] = []
    private var workspaceObserverTokens: [NSObjectProtocol] = []
    private var activeSceneModeID: UUID?
    private var activeSceneToken: UInt8?
    private var sceneDialArmed = true
    private var musicMetadataTask: Task<Void, Never>?
    private var lastMusicMetadata: MusicNowPlayingMetadata?
    private var lastMusicLanguage: DeviceDisplayLanguage?
    private let logger = Logger(subsystem: "com.vibeeverything.QuickVibeHost", category: "DeviceAction")

    init(ble: BLEManager, sceneModes: SceneModeStore) {
        self.ble = ble
        self.sceneModes = sceneModes
        if let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier {
            recentApplicationBundleIDs = [bundleID]
        }
        observeRunningApplications()
    }

    func handle(_ event: DeviceActionEvent) {
        if event.contextID == DeviceActionEvent.applicationSwitcherContextID {
            handleApplicationSwitcherEvent(event)
            return
        }
        if event.contextID == DeviceActionContext.home.rawValue {
            guard let action = DeviceActionResolver.resolve(event) else { return }
            executeSemantic(action, repeatCount: DeviceActionResolver.repeatCount(for: event))
            return
        }
        guard event.contextID == activeSceneToken else {
            logger.warning("drop stale scene event token=\(event.contextID) active=\(self.activeSceneToken ?? 0)")
            return
        }
        if event.control == .dialD {
            if event.gesture == .holdEnd {
                sceneDialArmed = true
                return
            }
            guard sceneDialArmed else { return }
            if let action = SceneNavigationPolicy.action(
                for: event.gesture,
                supportsRevisedGestures: ble?.supportsApplicationListSwitcher == true
            ) {
                if action == .cycleSceneMode { cycleSceneMode() }
                else { exitSceneMode() }
                return
            }
        }
        guard let id = activeSceneModeID,
              let mode = sceneModes.modes.first(where: { $0.id == id && $0.isEnabled }),
              let input = SceneModeInput.resolve(event: event),
              let action = mode.action(for: input) else { return }
        let repeatCount = DeviceActionResolver.repeatCount(for: event)
        logger.info("scene=\(id.uuidString, privacy: .public) input=\(input.rawValue, privacy: .public)")
        execute(action, repeatCount: repeatCount)
    }

    private func execute(_ action: SceneModeAction, repeatCount: Int) {
        switch action.kind {
        case .none: break
        case .semantic:
            if let semantic = action.semantic { executeSemantic(semantic, repeatCount: repeatCount) }
        case .keyStroke:
            guard let keyCode = action.keyCode else { return }
            let flags = CGEventFlags(rawValue: action.modifiers ?? 0)
            repeatAction(count: repeatCount) {
                KeyboardSimulator.pressKeyCombo(CGKeyCode(keyCode), modifiers: flags)
            }
        case .activateApp:
            guard let bundleIdentifier = action.bundleIdentifier,
                  let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else { return }
            NSWorkspace.shared.open(url)
        }
    }

    private func executeSemantic(_ action: DeviceSemanticAction, repeatCount: Int) {
        logger.info("action=\(String(describing: action), privacy: .public)")
        switch action {
        case .beginApplicationSwitcher: beginApplicationSwitcher()
        case .endApplicationSwitcher: endApplicationSwitcher()
        case .enterPreferredSceneMode: enterPreferredSceneMode()
        case .cycleSceneMode: cycleSceneMode()
        case .exitActionMode: exitSceneMode()
        case .up: repeatKey(0x7E, count: repeatCount)
        case .down: repeatKey(0x7D, count: repeatCount)
        case .left: repeatKey(0x7B, count: repeatCount)
        case .right: repeatKey(0x7C, count: repeatCount)
        case .pageUp: repeatKey(0x74, count: repeatCount)
        case .pageDown: repeatKey(0x79, count: repeatCount)
        case .backspace: repeatKey(0x33, count: repeatCount)
        case .undo:
            repeatAction(count: repeatCount) {
                KeyboardSimulator.pressKeyCombo(0x06, modifiers: .maskCommand)
            }
        case .chatGPTNextChat:
            // ChatGPT App's actual adjacent-chat navigation on this install.
            activateChatGPTThen {
                KeyboardSimulator.pressKeyCombo(0x21, modifiers: [.maskCommand, .maskShift])
            }
        case .chatGPTPreviousChat:
            activateChatGPTThen {
                KeyboardSimulator.pressKeyCombo(0x1E, modifiers: [.maskCommand, .maskShift])
            }
        case .chatGPTNewChat:
            performChatGPTMenuAction(titles: ["New Chat", "New Thread", "新聊天", "新建聊天", "新建会话"],
                                     fallbackKey: 0x2D, fallbackFlags: .maskCommand)
        case .chatGPTNewTemporaryChat:
            performChatGPTMenuAction(titles: ["New Temporary Chat", "New Temporary Thread", "新建临时聊天", "新建临时会话"],
                                     fallbackKey: 0x2D, fallbackFlags: [.maskCommand, .maskShift])
        case .chatGPTToggleSidebar:
            performChatGPTMenuAction(titles: ["Toggle Sidebar", "Show Sidebar", "Hide Sidebar", "切换边栏", "显示侧边栏", "隐藏侧边栏"],
                                     fallbackKey: 0x0B, fallbackFlags: .maskCommand)
        case .chatGPTArchiveChat:
            performChatGPTMenuAction(titles: ["Archive Chat", "Archive Thread", "归档聊天", "归档会话"],
                                     fallbackKey: 0x00, fallbackFlags: [.maskCommand, .maskShift])
        case .workBuddyNextTask, .workBuddyPreviousTask, .workBuddyNewTask,
             .workBuddyQuickQuestion, .workBuddyToggleArtifacts, .workBuddyStopTask:
            guard let shortcut = WorkBuddyShortcutResolver.resolve(action) else { return }
            activateWorkBuddyThen {
                KeyboardSimulator.pressKeyCombo(
                    CGKeyCode(shortcut.keyCode),
                    modifiers: CGEventFlags(rawValue: shortcut.modifiers)
                )
            }
        case .volumeDown: repeatMediaKey(.volumeDown, count: repeatCount)
        case .volumeUp: repeatMediaKey(.volumeUp, count: repeatCount)
        case .playPause: KeyboardSimulator.pressMediaKey(.playPause)
        case .nextTrack: KeyboardSimulator.pressMediaKey(.nextTrack)
        case .previousTrack: KeyboardSimulator.pressMediaKey(.previousTrack)
        }
    }

    private func activateWorkBuddyThen(_ action: @escaping @MainActor @Sendable () -> Void) {
        guard let url = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: SceneModeRegistry.workBuddyBundleIdentifier
        ) else {
            logger.error("WorkBuddy is not installed")
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { app, error in
            if let error {
                self.logger.error("Failed to activate WorkBuddy: \(error.localizedDescription, privacy: .public)")
                return
            }
            if let app {
                app.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
                _ = ApplicationSwitcherForegroundActivator.forceFront(
                    processIdentifier: app.processIdentifier
                )
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: action)
        }
    }

    func stopTransientActions() {
        endNativeApplicationSwitcher()
        closeApplicationSwitcher(notifyDevice: false)
        applicationFocusRestoreTask?.cancel()
        applicationFocusRestoreTask = nil
        stopMusicMetadataUpdates()
        activeSceneModeID = nil
        activeSceneToken = nil
        sceneDialArmed = true
    }

    private func enterPreferredSceneMode() {
        let frontmost = NSWorkspace.shared.frontmostApplication
        let isActive = frontmost?.isActive == true
        let bundleIdentifier = isActive ? frontmost?.bundleIdentifier : nil
        guard let mode = SceneModeRegistry.preferredMode(
            frontmostBundleIdentifier: bundleIdentifier,
            isActive: isActive,
            modes: runtimeModes
        ) else {
            let language = displayLanguage
            activeSceneModeID = nil
            activeSceneToken = 0xFE
            ble?.sendActionMode(.noEnabledScenes(language: language))
            return
        }
        logger.info("scene enter frontmost=\(bundleIdentifier ?? "<none>", privacy: .public) mode=\(mode.id.uuidString, privacy: .public)")
        showSceneMode(mode, requireDialRelease: true)
    }

    private func cycleSceneMode() {
        guard let next = SceneModeRegistry.nextMode(after: activeSceneModeID, modes: runtimeModes) else {
            ble?.sendActionMode(.noEnabledScenes(language: displayLanguage))
            return
        }
        logger.info("scene cycle next=\(next.id.uuidString, privacy: .public)")
        showSceneMode(next, requireDialRelease: false)
    }

    private func showSceneMode(_ mode: SceneModeDefinition, requireDialRelease: Bool) {
        let language = displayLanguage
        let token = token(for: mode)
        activeSceneModeID = mode.id
        activeSceneToken = token
        // Entry is triggered by a D hold. Ignore that physical press until its
        // release so it can never also satisfy the new "hold D to exit" rule.
        sceneDialArmed = !requireDialRelease
        if mode.builtInKind != .music { stopMusicMetadataUpdates() }
        ble?.sendActionMode(.scene(mode, token: token, language: language))
        if mode.builtInKind == .music {
            startMusicMetadataUpdates(language: language)
        }
    }

    private func exitSceneMode() {
        logger.info("scene exit token=\(self.activeSceneToken ?? 0)")
        activeSceneModeID = nil
        activeSceneToken = nil
        sceneDialArmed = true
        stopMusicMetadataUpdates()
        ble?.sendActionModeExit()
    }

    private func startMusicMetadataUpdates(language: DeviceDisplayLanguage) {
        stopMusicMetadataUpdates()
        lastMusicLanguage = language
        musicMetadataTask = Task { [weak self] in
            while !Task.isCancelled {
                // NSAppleScript is not thread-safe and must be executed on the
                // main thread. The query is local and runs only once per second.
                let metadata = AppleMusicNowPlayingReader.read()
                guard let self, let id = self.activeSceneModeID,
                      let mode = self.sceneModes.modes.first(where: { $0.id == id && $0.builtInKind == .music }),
                      let token = self.activeSceneToken else { return }
                let currentLanguage: DeviceDisplayLanguage = DeviceType.isMicStickName(self.ble?.memorizedDeviceName)
                    ? .selected : .simplifiedChinese
                if metadata != self.lastMusicMetadata || currentLanguage != self.lastMusicLanguage {
                    self.lastMusicMetadata = metadata
                    self.lastMusicLanguage = currentLanguage
                    self.ble?.sendActionMode(.scene(mode, token: token, language: currentLanguage,
                                                    nowPlaying: metadata))
                }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    private func stopMusicMetadataUpdates() {
        musicMetadataTask?.cancel()
        musicMetadataTask = nil
        lastMusicMetadata = nil
        lastMusicLanguage = nil
    }

    private func beginApplicationSwitcher() {
        guard ble?.supportsApplicationListSwitcher == true else {
            beginNativeApplicationSwitcher()
            return
        }
        guard applicationSwitcherSelection == nil else { return }
        let running = NSWorkspace.shared.runningApplications.map {
            RunningApplicationDescriptor(processIdentifier: $0.processIdentifier,
                                         bundleIdentifier: $0.bundleIdentifier ?? "",
                                         name: $0.localizedName ?? "",
                                         isEligible: !$0.isTerminated && $0.activationPolicy == .regular)
        }
        let selection = RunningApplicationListBuilder.build(
            applications: running,
            recentBundleIdentifiers: recentApplicationBundleIDs + windowOrderedBundleIdentifiers(),
            frontmostBundleIdentifier: NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
            excludedBundleIdentifier: Bundle.main.bundleIdentifier
        )
        applicationSwitcherSelection = selection
        applicationSwitcherFocusSnapshots = captureApplicationFocusSnapshots(selection.applications)
        applicationSwitcherRequestID &+= 1
        if applicationSwitcherRequestID == 0 { applicationSwitcherRequestID = 1 }
        let presentation = ApplicationSwitcherPresentation.make(
            requestID: applicationSwitcherRequestID,
            applicationNames: selection.applications.map(\.name),
            selectedIndex: selection.selectedIndex,
            language: displayLanguage
        )
        logger.info("application list open count=\(selection.applications.count) selected=\(selection.selectedIndex)")
        ble?.sendApplicationSwitcher(presentation)
        applicationSwitcherTimeoutTimer?.invalidate()
        applicationSwitcherTimeoutTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.closeApplicationSwitcher(notifyDevice: true) }
        }
    }

    private func beginNativeApplicationSwitcher() {
        guard !nativeApplicationSwitcherActive else { return }
        nativeApplicationSwitcherActive = true
        KeyboardSimulator.setModifierKey(0x37, isDown: true, flags: .maskCommand)
        KeyboardSimulator.pressKeyCombo(0x30, modifiers: .maskCommand)
        nativeApplicationSwitcherTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            Task { @MainActor in
                KeyboardSimulator.pressKeyCombo(0x30, modifiers: .maskCommand)
            }
        }
    }

    private func endApplicationSwitcher() {
        // Releasing C commits only the compatibility Cmd-Tab path. The new
        // device list remains open until D confirms or C cancels.
        endNativeApplicationSwitcher()
    }

    private func endNativeApplicationSwitcher() {
        nativeApplicationSwitcherTimer?.invalidate()
        nativeApplicationSwitcherTimer = nil
        guard nativeApplicationSwitcherActive else { return }
        nativeApplicationSwitcherActive = false
        KeyboardSimulator.setModifierKey(0x37, isDown: false, flags: [])
    }

    private func handleApplicationSwitcherEvent(_ event: DeviceActionEvent) {
        guard var selection = applicationSwitcherSelection else { return }
        if event.control == .dialD, event.gesture == .rotate, !selection.applications.isEmpty {
            selection = selection.moving(by: event.delta)
            applicationSwitcherSelection = selection
            applicationSwitcherTimeoutTimer?.fireDate = Date().addingTimeInterval(15)
            return
        }
        if event.control == .dialD, event.gesture == .tap {
            if selection.applications.indices.contains(selection.selectedIndex) {
                activateApplication(selection.applications[selection.selectedIndex])
            }
            closeApplicationSwitcher(notifyDevice: true)
            return
        }
        if event.control == .buttonC,
           (event.gesture == .tap || event.gesture == .holdEnd) {
            closeApplicationSwitcher(notifyDevice: event.gesture == .tap)
        }
    }

    private func closeApplicationSwitcher(notifyDevice: Bool) {
        applicationSwitcherTimeoutTimer?.invalidate()
        applicationSwitcherTimeoutTimer = nil
        guard applicationSwitcherSelection != nil else { return }
        applicationSwitcherSelection = nil
        applicationSwitcherFocusSnapshots.removeAll()
        if notifyDevice { ble?.sendApplicationSwitcherExit(requestID: applicationSwitcherRequestID) }
    }

    private func activateApplication(_ descriptor: RunningApplicationDescriptor) {
        let application = NSRunningApplication(processIdentifier: descriptor.processIdentifier)
            ?? NSWorkspace.shared.runningApplications.first {
                $0.bundleIdentifier?.caseInsensitiveCompare(descriptor.bundleIdentifier) == .orderedSame
            }
        guard let application, !application.isTerminated else {
            logger.warning("selected application quit before activation bundle=\(descriptor.bundleIdentifier, privacy: .public)")
            return
        }
        let snapshot = applicationSwitcherFocusSnapshots[application.processIdentifier]
        applicationFocusRestoreTask?.cancel()
        application.unhide()
        if let window = snapshot?.window {
            _ = AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
            _ = AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        }
        let activated = application.activate(options: [.activateAllWindows])
        let forced = ApplicationSwitcherForegroundActivator.forceFront(
            processIdentifier: application.processIdentifier
        )
        if !activated && !forced {
            logger.warning("application activation failed bundle=\(descriptor.bundleIdentifier, privacy: .public)")
        }
        logger.info("application activation bundle=\(descriptor.bundleIdentifier, privacy: .public) ns=\(activated) forced=\(forced)")
        guard let snapshot else { return }
        applicationFocusRestoreTask = Task { [weak self, weak application] in
            // Let AppKit/Electron finish selecting its key window before
            // restoring the window and control remembered at menu-open time.
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard !Task.isCancelled, let self, let application else { return }
            if NSWorkspace.shared.frontmostApplication?.processIdentifier != application.processIdentifier {
                // macOS may politely ignore the first activation from a
                // background/menu-bar app. Retry once after the target had a
                // chance to restore its windows, then apply the focus snapshot.
                application.unhide()
                _ = application.activate(options: [.activateAllWindows])
                _ = ApplicationSwitcherForegroundActivator.forceFront(
                    processIdentifier: application.processIdentifier
                )
                try? await Task.sleep(nanoseconds: 80_000_000)
                guard !Task.isCancelled else { return }
            }
            self.restoreApplicationFocus(snapshot, application: application)
        }
    }

    private func captureApplicationFocusSnapshots(
        _ applications: [RunningApplicationDescriptor]
    ) -> [pid_t: ApplicationFocusSnapshot] {
        guard AXIsProcessTrusted() else { return [:] }
        var snapshots: [pid_t: ApplicationFocusSnapshot] = [:]
        for application in applications {
            let pid = pid_t(application.processIdentifier)
            let appElement = AXUIElementCreateApplication(pid)
            let window = axElement(appElement, attribute: kAXFocusedWindowAttribute)
                ?? axElement(appElement, attribute: kAXMainWindowAttribute)
            let element = axElement(appElement, attribute: kAXFocusedUIElementAttribute)
            let subrole = element.flatMap { axString($0, attribute: kAXSubroleAttribute) }
            snapshots[pid] = ApplicationFocusSnapshot(
                processIdentifier: pid,
                window: window,
                element: subrole == "AXSecureTextField" ? nil : element,
                elementSubrole: subrole
            )
        }
        return snapshots
    }

    private func restoreApplicationFocus(_ snapshot: ApplicationFocusSnapshot,
                                         application: NSRunningApplication) {
        let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        guard ApplicationFocusRestorePolicy.shouldRestore(
            snapshotProcessIdentifier: snapshot.processIdentifier,
            targetProcessIdentifier: application.processIdentifier,
            frontmostProcessIdentifier: frontmostPID,
            elementSubrole: snapshot.elementSubrole
        ) else {
            logger.info("skip stale/secure focus restore bundle=\(application.bundleIdentifier ?? "<none>", privacy: .public)")
            return
        }

        let appElement = AXUIElementCreateApplication(application.processIdentifier)
        if let window = snapshot.window, axElementBelongsToProcess(window, application.processIdentifier) {
            _ = AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
            _ = AXUIElementSetAttributeValue(window, kAXFocusedAttribute as CFString, kCFBooleanTrue)
            _ = AXUIElementSetAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, window)
            _ = AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        }
        if let element = snapshot.element,
           axElementBelongsToProcess(element, application.processIdentifier) {
            let direct = AXUIElementSetAttributeValue(
                element, kAXFocusedAttribute as CFString, kCFBooleanTrue
            )
            if direct != .success {
                _ = AXUIElementSetAttributeValue(
                    appElement, kAXFocusedUIElementAttribute as CFString, element
                )
            }
            logger.info("restored application focus bundle=\(application.bundleIdentifier ?? "<none>", privacy: .public) status=\(direct.rawValue)")
        }
    }

    private func axElement(_ element: AXUIElement, attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeBitCast(value, to: AXUIElement.self)
    }

    private func axString(_ element: AXUIElement, attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return value as? String
    }

    private func axElementBelongsToProcess(_ element: AXUIElement, _ expectedPID: pid_t) -> Bool {
        var actualPID: pid_t = 0
        return AXUIElementGetPid(element, &actualPID) == .success && actualPID == expectedPID
    }

    private func observeRunningApplications() {
        let center = NSWorkspace.shared.notificationCenter
        workspaceObserverTokens.append(center.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                    as? NSRunningApplication,
                  let bundleID = application.bundleIdentifier else { return }
            Task { @MainActor in self?.noteApplicationActivation(bundleID) }
        })
    }

    /// Quartz returns on-screen windows front-to-back. Owner identifiers give
    /// us a useful launch-time MRU seed without Screen Recording permission;
    /// workspace activation notifications refine it while the Host is running.
    private func windowOrderedBundleIdentifiers() -> [String] {
        guard let windowInfo = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else { return [] }
        var result: [String] = []
        var seen = Set<String>()
        for window in windowInfo {
            guard let processID = window[kCGWindowOwnerPID as String] as? Int,
                  let app = NSRunningApplication(processIdentifier: pid_t(processID)),
                  app.activationPolicy == .regular,
                  let bundleID = app.bundleIdentifier else { continue }
            let key = bundleID.lowercased()
            if seen.insert(key).inserted { result.append(bundleID) }
        }
        return result
    }

    private func noteApplicationActivation(_ bundleID: String) {
        recentApplicationBundleIDs.removeAll { $0.caseInsensitiveCompare(bundleID) == .orderedSame }
        recentApplicationBundleIDs.insert(bundleID, at: 0)
        if recentApplicationBundleIDs.count > RunningApplicationListBuilder.maximumCount {
            recentApplicationBundleIDs.removeLast(recentApplicationBundleIDs.count - RunningApplicationListBuilder.maximumCount)
        }
    }

    private func repeatKey(_ keyCode: CGKeyCode, count: Int) {
        for _ in 0..<count {
            KeyboardSimulator.pressKeyCombo(keyCode, modifiers: [])
        }
    }

    private func repeatMediaKey(_ key: KeyboardSimulator.MediaKey, count: Int) {
        for _ in 0..<count {
            KeyboardSimulator.pressMediaKey(key)
        }
    }

    private func repeatAction(count: Int, action: () -> Void) {
        for _ in 0..<max(1, count) { action() }
    }

    private var displayLanguage: DeviceDisplayLanguage {
        DeviceType.isMicStickName(ble?.memorizedDeviceName) ? .selected : .simplifiedChinese
    }

    private var runtimeModes: [SceneModeDefinition] {
        guard ble?.supportsDynamicSceneModes != true else { return sceneModes.modes }
        return sceneModes.modes.filter {
            $0.id == SceneModeDefinition.chatGPTID ||
                $0.id == SceneModeDefinition.customOneID ||
                $0.id == SceneModeDefinition.musicID
        }
    }

    private func token(for mode: SceneModeDefinition) -> UInt8 {
        if mode.id == SceneModeDefinition.customOneID { return DeviceActionContext.customOne.rawValue }
        if mode.id == SceneModeDefinition.chatGPTID { return DeviceActionContext.chatGPTApp.rawValue }
        if mode.id == SceneModeDefinition.musicID { return DeviceActionContext.music.rawValue }
        if mode.id == SceneModeDefinition.workBuddyID { return 0x0F }
        let ordered = sceneModes.modes.filter { !$0.isBuiltIn && $0.id != SceneModeDefinition.customOneID }
            .sorted { $0.order < $1.order }
        let index = ordered.firstIndex(where: { $0.id == mode.id }) ?? 0
        return UInt8(min(0xFD, 0x10 + index))
    }

    private func activateChatGPTThen(_ action: @escaping @MainActor @Sendable () -> Void) {
        CodexDesktopActivator.bringToFront()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: action)
    }

    /// AXPress executes the matching installed-app menu command itself, so a
    /// remapped user shortcut remains authoritative. Key chords are fallback
    /// behavior for ChatGPT versions that do not expose the menu item via AX.
    private func performChatGPTMenuAction(titles: [String], fallbackKey: CGKeyCode,
                                          fallbackFlags: CGEventFlags) {
        activateChatGPTThen {
            if ChatGPTMenuAction.perform(titles: titles) { return }
            KeyboardSimulator.pressKeyCombo(fallbackKey, modifiers: fallbackFlags)
        }
    }
}

/// `NSRunningApplication.activate` can be accepted without transferring the
/// keyboard-front process when called by an accessory/menu-bar application.
/// The legacy Process Manager ABI is still present on current macOS and is
/// used narrowly as the same front-window fallback already used by Codex
/// session activation elsewhere in QuickVibeHost.
private enum ApplicationSwitcherForegroundActivator {
    private struct ProcessSerialNumber {
        var high: UInt32 = 0
        var low: UInt32 = 0
    }

    private typealias GetProcessForPID = @convention(c)
        (pid_t, UnsafeMutableRawPointer) -> Int32
    private typealias SetFrontProcessWithOptions = @convention(c)
        (UnsafeRawPointer, UInt32) -> Int32

    private static let functions: (GetProcessForPID, SetFrontProcessWithOptions)? = {
        guard let handle = dlopen(
            "/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices",
            RTLD_LAZY
        ),
        let getProcess = dlsym(handle, "GetProcessForPID"),
        let setFront = dlsym(handle, "SetFrontProcessWithOptions") else { return nil }
        return (
            unsafeBitCast(getProcess, to: GetProcessForPID.self),
            unsafeBitCast(setFront, to: SetFrontProcessWithOptions.self)
        )
    }()

    static func forceFront(processIdentifier: pid_t) -> Bool {
        guard let (getProcess, setFront) = functions else { return false }
        var serial = ProcessSerialNumber()
        let lookup = withUnsafeMutablePointer(to: &serial) {
            getProcess(processIdentifier, UnsafeMutableRawPointer($0))
        }
        guard lookup == 0 else { return false }
        // kSetFrontProcessFrontWindowOnly = 1.
        return withUnsafePointer(to: &serial) {
            setFront(UnsafeRawPointer($0), 1)
        } == 0
    }
}

@MainActor
private enum AppleMusicNowPlayingReader {
    private static let bundleIdentifier = "com.apple.Music"
    private static var lastDiagnostic: String?
    private static let script = """
        tell application id "com.apple.Music"
            if player state is stopped then return {}
            try
                set activeTrack to current track
                return {name of activeTrack as text, artist of activeTrack as text}
            on error
                return {}
            end try
        end tell
        """

    static func read() -> MusicNowPlayingMetadata? {
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).isEmpty else {
            logDiagnostic("Music is not running")
            return nil
        }
        guard let appleScript = NSAppleScript(source: script) else {
            logDiagnostic("AppleScript source failed to compile")
            return nil
        }
        var error: NSDictionary?
        let result = appleScript.executeAndReturnError(&error)
        if let error {
            logDiagnostic("AppleScript error: \(error)")
            return nil
        }
        guard result.numberOfItems >= 2,
              let rawTitle = result.atIndex(1)?.stringValue else {
            logDiagnostic("Music returned no current track")
            return nil
        }
        let title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let artist = (result.atIndex(2)?.stringValue ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else {
            logDiagnostic("Music returned an empty track title")
            return nil
        }
        logDiagnostic("Now-playing metadata available")
        return MusicNowPlayingMetadata(title: title, artist: artist)
    }

    private static func logDiagnostic(_ message: String) {
        guard message != lastDiagnostic else { return }
        lastDiagnostic = message
        ClaudeCodeSessionManager.log("[music-now-playing] \(message)")
    }
}

private enum ChatGPTMenuAction {
    static func perform(titles: [String]) -> Bool {
        guard AXIsProcessTrusted(),
              let app = CodexDesktopActivator.bundleIds.lazy
                .compactMap({ NSRunningApplication.runningApplications(withBundleIdentifier: $0).first })
                .first else { return false }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXMenuBarAttribute as CFString, &value) == .success,
              let menuBar = value else { return false }
        return findAndPress(menuBar as! AXUIElement, titles: Set(titles), depth: 0)
    }

    private static func findAndPress(_ element: AXUIElement, titles: Set<String>, depth: Int) -> Bool {
        guard depth < 8 else { return false }
        var titleValue: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &titleValue) == .success,
           let title = titleValue as? String, titles.contains(title),
           AXUIElementPerformAction(element, kAXPressAction as CFString) == .success {
            return true
        }
        var childrenValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenValue) == .success,
              let children = childrenValue as? [AXUIElement] else { return false }
        return children.contains { findAndPress($0, titles: titles, depth: depth + 1) }
    }
}
