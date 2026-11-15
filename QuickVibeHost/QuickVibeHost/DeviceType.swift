import Foundation

/// 支持的自有设备类型：Stick S3(原型)与 VE 语音棒(MicPad,正式量产)。
enum DeviceType: String, Identifiable, CaseIterable {
    case stickS3
    case micPad

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .stickS3: return "M5Stack Stick S3"
        case .micPad:  return AppL10n.tr("VE 语音棒")
        }
    }

    /// 卡片主标题（"添加 XXX 设备"），用在 DeviceTypeCard。
    var addActionTitle: String {
        switch self {
        case .stickS3: return AppL10n.tr("添加一体化设备")
        case .micPad:  return AppL10n.tr("添加 VE 语音棒")
        }
    }

    /// 括号里的状态备注。
    var statusNote: String {
        switch self {
        case .stickS3: return AppL10n.tr("原型设备")
        case .micPad:  return AppL10n.tr("正式量产设备")
        }
    }

    var introCopy: String {
        switch self {
        case .stickS3:
            return AppL10n.tr("Stick S3 是当前唯一一款已接入的原型设备，含屏幕与 A/B 按键，支持语音注入、模式切换与会话面板切换。")
        case .micPad:
            // 【REQ-013-待确认】草稿，待 user 用 REQ-013 原文校对替换
            return AppL10n.tr("VE 语音棒是正式量产的一体化远程语音设备，内置麦克风、屏幕与机械按键，支持语音注入、模式切换与会话面板切换。相比原型 Stick S3，拥有更大屏幕、更大电池与更好手感。开机后在附近点『添加设备』即可配对。")
        }
    }

    /// Assets.xcassets 中的设备图（复用线稿 asset）。
    var imageName: String {
        switch self {
        case .stickS3: return "StickS3Scratch"
        case .micPad:  return "MicPadScratch"
        }
    }

    /// MicStick 与 MicPad 共用 v5 协议，但设备卡需要展示各自的产品图。
    /// 同时兼容现行固件广播名 `MicStick-XXXX` 和完整产品名前缀。
    static func isMicStickName(_ name: String?) -> Bool {
        guard let normalized = name?.lowercased() else { return false }
        return normalized.hasPrefix("micstick") || normalized.hasPrefix("quickvibemicstick")
    }

    static func micPadFamilyImageName(for deviceName: String?) -> String {
        isMicStickName(deviceName) ? "LineQVMSImage" : "MicPadScratch"
    }

    /// 两类自有设备均已接入。
    var isImplemented: Bool { true }
}
