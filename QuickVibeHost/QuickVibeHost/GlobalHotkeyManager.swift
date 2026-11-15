import Foundation
import AppKit
import SwiftUI

/// 快捷键触发的语音意图：
/// - asrInject：走 Option+1 / Stick S3 A 键，识别后注入光标
enum VoiceIntent {
    case asrInject
}

/// 语音录制的触发来源。贯穿录音/注入链路（`toggleRecording(triggerSource:)` /
/// `activeTriggerSource` / `presentEditor(trigger:)`）。HID 小键盘线移除后仅剩
/// hotkey 路径，但枚举/参数保留，避免改动注入链路。
/// - hotkey：Option+1/Option+2 全局快捷键触发，光标注入的自由模式
enum VoiceTriggerSource: String {
    case hotkey
}

@MainActor
final class GlobalHotkeyManager: ObservableObject {
    /// ASR 注入快捷键的键码，本期固定为 Option+1 (keyCode 18)
    @AppStorage("hotkeyKeyCode") var hotkeyKeyCode: Int = 18
    @AppStorage("hotkeyEnabled") var hotkeyEnabled: Bool = true

    /// Whether the global CGEvent tap is currently installed and active.
    /// Published so UI (DeviceTab's hotkey section) can warn the user when
    /// `false`, which typically means Accessibility permission is missing
    /// and `CGEvent.tapCreate` returned nil.
    /// See plan: mighty-squishing-pelican.md — 快捷键失效防御方案.
    @Published var isActive: Bool = false

    weak var voiceInputManager: VoiceInputManager?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    /// When true, next Option+key press sets the hotkey instead of triggering recording
    private var isRecordingHotkey = false
    private var hotkeyRecordingCallback: ((Int) -> Void)?

    /// In-flight retry timer. Cancelled by `stop()` so a paused manager
    /// doesn't keep polling tapCreate forever.
    private var retryWork: DispatchWorkItem?
    /// Number of retries since the current `start()` cycle began.
    /// Reset to 0 on success.
    private var retryAttemptCount = 0
    /// Throttles the per-failure log to once per `start()` cycle; otherwise
    /// a perpetually denied permission would spam quickvibe.log.
    private var hasLoggedFailure = false

    // Static weak reference for C callback bridging
    nonisolated(unsafe) private static var shared: GlobalHotkeyManager?

    var hotkeyDisplayName: String {
        "⌥\(keyCodeToString(hotkeyKeyCode))"
    }

    func startRecordingHotkey(completion: @escaping (Int) -> Void) {
        isRecordingHotkey = true
        hotkeyRecordingCallback = completion
    }

    func start() {
        guard eventTap == nil else { return }
        Self.shared = self
        retryAttemptCount = 0
        hasLoggedFailure = false
        _ = tryInstallTap()
    }

    /// Attempt to create + install the event tap. Returns true on success.
    /// On failure, logs once (with AX state) and schedules a 2s retry so the
    /// tap comes back online automatically once the user grants permission —
    /// no app restart required.
    @discardableResult
    private func tryInstallTap() -> Bool {
        // Skip if `stop()` ran between schedule and fire.
        guard Self.shared === self else { return false }

        let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue)

        let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { (proxy, type, event, userInfo) -> Unmanaged<CGEvent>? in
                // Re-enable tap if disabled by system
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    if let tap = GlobalHotkeyManager.shared?.eventTap {
                        CGEvent.tapEnable(tap: tap, enable: true)
                    }
                    return Unmanaged.passUnretained(event)
                }

                guard type == .keyDown else {
                    return Unmanaged.passUnretained(event)
                }

                let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
                let flags = event.flags

                // Debug-only: log every keyDown to quickvibe.log so we can
                // correlate user keystrokes with typeText events when a
                // duplicate-paste is reported. Gate on UserDefaults key
                // `keyDownTraceEnabled` to avoid flooding the log in normal
                // usage. Enable via:
                //   defaults write com.vibeeverything.QuickVibeHost keyDownTraceEnabled -bool true
                // See plan: mighty-squishing-pelican.md — Step 2.
                if UserDefaults.standard.bool(forKey: "keyDownTraceEnabled") {
                    let frontApp = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "<unknown>"
                    let flagsHex = String(format: "0x%X", flags.rawValue)
                    ClaudeCodeSessionManager.log(
                        "[keyDown] keyCode=\(keyCode) flags=\(flagsHex) frontApp=\(frontApp)"
                    )
                }

                // Check left Option + configured key
                let leftOptionBit: UInt64 = 0x00000020  // NX_DEVICELALTKEYMASK
                let hasLeftOption = flags.rawValue & leftOptionBit != 0
                let hasOption = flags.contains(.maskAlternate)

                // Ensure no other modifiers (command, control, shift) are pressed
                let hasOtherModifiers = flags.contains(.maskCommand) || flags.contains(.maskControl) || flags.contains(.maskShift)

                guard let mgr = GlobalHotkeyManager.shared else {
                    return Unmanaged.passUnretained(event)
                }

                // Recording mode: capture Option+key as new hotkey
                if mgr.isRecordingHotkey && hasOption && hasLeftOption && !hasOtherModifiers {
                    let newKeyCode = Int(keyCode)
                    DispatchQueue.main.async {
                        guard let mgr = GlobalHotkeyManager.shared else { return }
                        mgr.hotkeyKeyCode = newKeyCode
                        mgr.isRecordingHotkey = false
                        mgr.hotkeyRecordingCallback?(newKeyCode)
                        mgr.hotkeyRecordingCallback = nil
                    }
                    return nil
                }

                let asrKeyCode = mgr.hotkeyKeyCode
                let enabled = mgr.hotkeyEnabled

                if enabled && hasOption && hasLeftOption && !hasOtherModifiers {
                    if keyCode == asrKeyCode {
                        DispatchQueue.main.async {
                            GlobalHotkeyManager.shared?.voiceInputManager?.toggleRecording(intent: .asrInject)
                        }
                        return nil
                    }
                }

                return Unmanaged.passUnretained(event)
            },
            userInfo: nil
        )

        if let tap {
            eventTap = tap
            let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
            runLoopSource = source
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            isActive = true

            if retryAttemptCount > 0 {
                ClaudeCodeSessionManager.log(
                    "[GlobalHotkeyManager] tapCreate succeeded after \(retryAttemptCount) retries"
                )
            }
            retryAttemptCount = 0
            hasLoggedFailure = false
            return true
        }

        // tapCreate failed — almost always means Accessibility permission is
        // denied (or AX state is stale after a Debug rebuild). Log once per
        // start() cycle, then auto-retry so the hotkey comes back as soon
        // as the user grants permission.
        if !hasLoggedFailure {
            let ax = AXIsProcessTrusted() ? "Y" : "N"
            ClaudeCodeSessionManager.log(
                "[GlobalHotkeyManager] tapCreate failed ax=\(ax) — will auto-retry every 2s until success"
            )
            hasLoggedFailure = true
        }
        isActive = false
        scheduleRetry()
        return false
    }

    private func scheduleRetry() {
        retryWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.retryAttemptCount += 1
            _ = self.tryInstallTap()
        }
        retryWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: work)
    }

    func stop() {
        retryWork?.cancel()
        retryWork = nil
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            if let source = runLoopSource {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            }
            CFMachPortInvalidate(tap)
        }
        eventTap = nil
        runLoopSource = nil
        isActive = false
        Self.shared = nil
    }

    deinit {
        // Can't call stop() directly from deinit in @MainActor class
        retryWork?.cancel()
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            if let source = runLoopSource {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            }
            CFMachPortInvalidate(tap)
        }
    }

    private func keyCodeToString(_ keyCode: Int) -> String {
        switch keyCode {
        case 18: return "1"
        case 19: return "2"
        case 20: return "3"
        case 21: return "4"
        case 23: return "5"
        case 22: return "6"
        case 26: return "7"
        case 28: return "8"
        case 25: return "9"
        case 29: return "0"
        case 0: return "A"
        case 11: return "B"
        case 8: return "C"
        case 2: return "D"
        case 14: return "E"
        case 3: return "F"
        case 5: return "G"
        case 4: return "H"
        case 34: return "I"
        case 38: return "J"
        case 40: return "K"
        case 37: return "L"
        case 46: return "M"
        case 45: return "N"
        case 31: return "O"
        case 35: return "P"
        case 12: return "Q"
        case 15: return "R"
        case 1: return "S"
        case 17: return "T"
        case 32: return "U"
        case 9: return "V"
        case 13: return "W"
        case 7: return "X"
        case 16: return "Y"
        case 6: return "Z"
        case 49: return "Space"
        default: return "Key(\(keyCode))"
        }
    }
}
