import Foundation

/// Why an exclusive-mode injection couldn't land on the selected session.
/// Each case carries a toast-ready Chinese string + a log tag + a hint on
/// whether the selection should auto-clear (target gone for good).
enum FallbackReason: Equatable, Sendable {
    case sessionEnded
    case sessionInvalid                          // missing pid/tty or not in store
    case waitingForApproval(toolName: String)
    case ttyOpenFailed                           // stat/open failed (not a permission error)
    case ttyReused                               // pgid mismatch: tty claimed by another process group
    case ttyWriteFailed                          // write() returned < requested
    case permissionDenied                        // EACCES or uid mismatch on tty
    case vibeptyUnavailable                      // vibepty socket not found / unreachable (user didn't wrap claude)
    case codexNotWrapped                         // codex 会话无 pid 映射(未经 vibepty 启动,或 wrapper 已退出)
    case exclusiveDeviceOffline                  // exclusive requires device lifecycle == connected
    case exclusiveRequiresDevice                 // no memorized device yet
    case exclusiveClearedUnsupported             // 设备旋钮选中不可直通会话 → 取消原直通回自由输入(2026-07-25)

    var toastMessage: String {
        switch self {
        case .sessionEnded:
            AppL10n.tr("目标 Claude 会话已结束，已清空直通选择")
        case .sessionInvalid:
            AppL10n.tr("目标会话状态异常（缺少 pid/tty），本次走自由输入")
        case .waitingForApproval(let tool):
            AppL10n.format("Claude 正在请求 %@ 审批，请先处理；本次走自由输入", tool)
        case .ttyOpenFailed:
            AppL10n.tr("无法打开目标终端，已走自由输入")
        case .ttyReused:
            AppL10n.tr("目标进程校验未通过，本次注入未执行（直通保留，可重试）")
        case .ttyWriteFailed:
            AppL10n.tr("PTY 写入失败，已走自由输入")
        case .permissionDenied:
            AppL10n.tr("系统拒绝写入目标终端（权限/所有权不匹配）")
        case .vibeptyUnavailable:
            AppL10n.tr("目标 claude 未用 vibepty 启动（请设置 alias 并重开终端），本次走自由输入")
        case .codexNotWrapped:
            AppL10n.tr("该 Codex 会话无注入通道（codex 需经 vibepty 启动，新开终端生效），无法直通")
        case .exclusiveDeviceOffline:
            AppL10n.tr("设备未在线，直通模式需要物理设备在线，已取消本次直通")
        case .exclusiveRequiresDevice:
            AppL10n.tr("需要外接设备才能进入直通，请先到设备 TAB 连接 Stick S3")
        case .exclusiveClearedUnsupported:
            AppL10n.tr("该会话不支持直通，已切换为自由输入")
        }
    }

    var logDescription: String {
        switch self {
        case .sessionEnded: "sessionEnded"
        case .sessionInvalid: "sessionInvalid"
        case .waitingForApproval(let t): "waitingForApproval(\(t))"
        case .ttyOpenFailed: "ttyOpenFailed"
        case .ttyReused: "ttyReused"
        case .ttyWriteFailed: "ttyWriteFailed"
        case .permissionDenied: "permissionDenied"
        case .vibeptyUnavailable: "vibeptyUnavailable"
        case .codexNotWrapped: "codexNotWrapped"
        case .exclusiveDeviceOffline: "exclusiveDeviceOffline"
        case .exclusiveRequiresDevice: "exclusiveRequiresDevice"
        case .exclusiveClearedUnsupported: "exclusiveClearedUnsupported"
        }
    }

    /// Whether this reason means the selection is permanently unusable for
    /// this session id — caller should clear persisted selection.
    var shouldClearSelection: Bool {
        switch self {
        case .sessionEnded: true
        // codex 无 pid 映射 = 注入通道终态缺失(wrapper 未用/已退出),保留选择只会反复失败
        case .codexNotWrapped: true
        // BUG-021: ttyReused 不再自动清空 — 该判定历史上出过白名单假阳性
        // (CC 版本号引擎二进制),误清空的代价(直通静默失效)远大于保留一个
        // 可疑选择的代价(注入由 vibepty per-pid socket 兜底拒绝)。
        case .ttyReused: false
        default: false
        }
    }

    /// Whether the router should fall back to free-mode typing so the user's
    /// speech still lands somewhere visible. False means drop the text entirely
    /// and only show the toast — used for `.waitingForApproval`, where hard
    /// typing into the approval UI can misfire option shortcuts (y/n/1/2).
    var shouldFallbackToFreeTyping: Bool {
        switch self {
        case .waitingForApproval: false
        default: true
        }
    }
}
