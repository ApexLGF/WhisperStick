import Foundation
import CoreGraphics

/// Dispatcher 层的联合动作类型。
/// - `controlKey`: 所有按键类动作（Enter / ESC / ↑/↓/←/→ / Home/End / Shift+Tab / Backspace）
///   统一走 `InputRouter.routeControl` —— 直通模式下 PTY 注入到目标 session，
///   free 模式 / PTY 失败时走 `KeyboardSimulator` 键盘模拟。
/// - `micStart/micStop`: 直通 `VoiceInputManager`，不经 `InputRouter`
enum KeyboardAction: Sendable, Equatable {
    case controlKey(ControlKey)
    case micStart
    case micStop

    var logName: String {
        switch self {
        case .controlKey(let k): k.logName
        case .micStart: "mic+"
        case .micStop: "mic-"
        }
    }
}

/// 自注入事件白名单标记。写入 `eventSourceUserData`，CGEventTap 入口识别后直接放行，
/// 避免 QuickVibeHost 自己 post 的 Shift+Tab / Enter 被本应用自己吞掉。
/// 字节序列 "QVH_SELF" 的 ASCII 大端。
let SELF_INJECT_SIGNATURE: Int64 = 0x5156_485F_5345_4C46
