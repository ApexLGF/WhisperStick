// ITNPostProcessor.swift
// 识别定稿的逆文本规范化(ITN)后处理 — REQ-008 backlog #3。
//
// 为什么在 Swift 侧做:FunASR C++ runtime 的 ITN 在 macOS 构建里被上游
// `#if !__APPLE__` 排除(二进制里 0 个 ITN 符号),本地 Paraformer 出的是
// "二零二六零七零三"这类口语字面;shim 传 itn=true 是空操作。
// 引擎选型与评审见 20_项目/_R&B/VibePanel/REQ-008(调优 Backlog #3)。
//
// 实现:vendored 纯 Swift 库 ThirdParty/ChineseITN(WeTextProcessing 官方
// 文法的 Swift 重实现,Apache-2.0,补丁见其 PATCHES.md)。
//
// 挂载点(两处独立,新增识别入口时必须同步挂):
//   ① presentEditor — mic 侧全部成功路径(离线/流式/兜底/重试成功);
//   ② processButtonAAudio 定稿汇合点 — BLE 入口不走 presentEditor,单独挂。
// 豆包服务端 ITN 已开,其结果已是数字形态,规则不再命中 — 幂等,可安全
// 统一处理;顺带兜住豆包漏转的表达。
// 只处理定稿,不碰流式 partial(草稿闪变没必要,且省每 chunk ~毫秒级开销)。

import Foundation

enum ITNPostProcessor {

    /// 与 SettingsTab 的 @AppStorage("itnPostProcessEnabled") 同键。默认开。
    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: "itnPostProcessEnabled") as? Bool ?? true
    }

    /// 对识别定稿做 ITN。关闭或空文本时原样返回。
    /// ChineseITN.normalize 线程安全(全静态不可变表),任意队列可调;
    /// 实测 64 字长句 ~4ms(release),定稿一次一调无感。
    static func apply(_ text: String) -> String {
        guard isEnabled, !text.isEmpty else { return text }
        return mergeSpelledLetters(ChineseITN.normalize(text))
    }

    /// 拼读字母合并(2026-07-07):本地 Paraformer 对拼读英文输出
    /// "u s b" 这类逐字母带空格形态 → 合并为 "usb"。
    /// 规则:连续 ≥2 个"单字母␠单字母"串,且首尾不紧贴其他英文/数字
    /// (避免误伤 "this is a test" / "Plan B" / "vitamin b" / "x 7")。
    /// 豆包输出的 "USB" 不含此形态,规则不命中 — 幂等,统一处理安全。
    static func mergeSpelledLetters(_ text: String) -> String {
        let pattern = "(?<![A-Za-z0-9])[A-Za-z](?: [A-Za-z])+(?![A-Za-z0-9])"
        guard let re = try? NSRegularExpression(pattern: pattern) else { return text }
        var result = text
        let matches = re.matches(in: result, range: NSRange(result.startIndex..., in: result)).reversed()
        for m in matches {
            if let r = Range(m.range, in: result) {
                result.replaceSubrange(r, with: result[r].replacingOccurrences(of: " ", with: ""))
            }
        }
        return result
    }
}
