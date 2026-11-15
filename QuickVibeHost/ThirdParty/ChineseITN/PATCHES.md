# ChineseITN vendor 说明

- 上游: https://github.com/xzjh/chinese-itn-swift (Apache-2.0)
- vendor 基线: commit `540add9` "Release ChineseITN 0.3.0 output styles" (2026-06)
- vendor 日期: 2026-07-03
- 用途: 本地 Paraformer ASR 无 ITN(FunASR runtime ITN 被 `#if !__APPLE__` 排除),
  在 Swift 侧对识别定稿做逆文本规范化(中文数字→阿拉伯数字/日期/百分比等)。
- App 集成方式: Xcode target 直接编译 `Sources/ChineseITN/*.swift`(非 SPM 依赖);
  本目录同时保留完整 SPM 包结构,验证用 `swift test` 在本目录跑(上游 118 用例
  + QuickVibe 场景用例)。

## 本地补丁(与上游的差异)

1. **Cardinal.swift — 纯读数串长度白名单放宽**(标记 `[QuickVibe patch]`)
   上游: `{3,4,5,11,18}`;本地: `3...11 ∪ {18}`。
   动机: 8 位日期读数串("二零二六零七零三")上游被拒识,lattice 拆成
   "202 60703"。CLI 口述场景日期/时间戳/工单号高频。
   保留上游语义: 2 位模糊量词不转("七八个");12-17 位仍拒识以保留
   "区号+手机"分段拆分(parity 用例 "加一二三四幺三八..." → "1234 13811100000")。

2. **Tests/ChineseITNTests/QuickVibeCLIScenarioTests.swift — 新增文件**
   QuickVibe CLI 口述场景验收集(转换用例 + 误转守卫反例)。

## 升级方式

拉上游新版后重放上述补丁,在本目录 `swift test` 全绿(125 用例)再替换。
