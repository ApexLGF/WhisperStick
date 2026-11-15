import AppKit
import SwiftUI

/// 流式草稿内容高度 → 驱动浮窗自增高。
private struct DraftHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// 录音波形:5 根竖条,由**实时音频 RMS 电平**(state.recordingLevel)驱动 —— 说话大波形大、
/// 安静则小。权重 [0.5,0.8,1.0,0.75,0.55](中高两侧低)+ 平滑包络(attack 40%/release 15%)
/// + 每根 ±4% 随机抖动增加有机感。44×32px,30fps。
private struct WaveformView: View {
    @ObservedObject var state: OverlayState
    var barWidth: CGFloat = 5
    var spacing: CGFloat = 4
    var maxHeight: CGFloat = 32
    var minBar: CGFloat = 4
    @State private var bars: [CGFloat] = Array(repeating: 0.12, count: 5)
    private let weights: [CGFloat] = [0.5, 0.8, 1.0, 0.75, 0.55]
    private let recordingColor = Color.orange.opacity(0.85)
    private let timer = Timer.publish(every: 1.0 / 30.0, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(alignment: .center, spacing: spacing) {
            ForEach(0..<5, id: \.self) { i in
                Capsule()
                    .fill(recordingColor)
                    .frame(width: barWidth, height: max(minBar, bars[i] * maxHeight))
            }
        }
        .frame(width: barWidth * 5 + spacing * 4, height: maxHeight, alignment: .center)
        .onReceive(timer) { _ in
            let lvl = CGFloat(state.recordingLevel)
            for i in 0..<5 {
                let jitter = CGFloat.random(in: 0.96...1.04)            // ±4% 抖动
                let target = max(0.08, lvl) * weights[i] * jitter        // 静音也留个底
                let rate: CGFloat = target > bars[i] ? 0.4 : 0.15        // attack 40% / release 15%
                bars[i] += (target - bars[i]) * rate
            }
        }
    }
}

// MARK: - 胶囊模式(REQ-012:识别即输入)

/// NSVisualEffectView(.hudWindow 材质)包装,供 SwiftUI 用作胶囊背景。
private struct VisualEffectView: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow
    var cornerRadius: CGFloat = 28
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = .behindWindow
        v.state = .active
        // ★ 在 layer 层裁圆角:SwiftUI 的 clipShape 裁不住 NSVisualEffectView,
        //   不这么做四角会漏出矩形毛玻璃(用户报"直角边角")。
        v.wantsLayer = true
        v.layer?.cornerRadius = cornerRadius
        v.layer?.masksToBounds = true
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) {
        v.material = material
        v.layer?.cornerRadius = cornerRadius
    }
}

private struct CapsuleTextWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

/// 尾随滚动文字:内容宽 ≤ maxWidth 时正常显示(胶囊随之弹性变宽);超出则固定 maxWidth、
/// 只显示**末尾**(trailing 对齐 + clip)——新文字从右进入把老文字向左推出。变化带 0.25s 过渡。
private struct ScrollingTailText: View {
    let text: String
    let fontSize: CGFloat
    let maxWidth: CGFloat
    @State private var contentWidth: CGFloat = 0

    var body: some View {
        let visible = min(contentWidth, maxWidth)
        Text(text.isEmpty ? " " : text)
            .font(.system(size: fontSize, weight: .regular))
            .lineLimit(1)
            .fixedSize()
            .background(GeometryReader { g in
                Color.clear.preference(key: CapsuleTextWidthKey.self, value: g.size.width)
            })
            .frame(width: max(0, visible), alignment: .trailing)
            .clipped()
            .onPreferenceChange(CapsuleTextWidthKey.self) { contentWidth = $0 }
            .animation(.easeOut(duration: 0.25), value: text)
    }
}

/// 胶囊视图:底部居中、无边框、.hudWindow 毛玻璃胶囊。左波形(实时 RMS)+ 右尾随滚动文字。
/// 出错态:警告 + 原因 + 重试;重试成功后(capsuleShowCopy)显示文本 + 复制,不自动注入。
struct CapsuleOverlayView: View {
    @ObservedObject var state: OverlayState
    @AppStorage("overlayFontScale") private var fontScale: Double = 1.0

    // 字号跟随设置,但胶囊比例克制放大:1x≈48 / 2x≈65 / 3x≈82。
    private var fontSize: CGFloat { 15 + (min(max(CGFloat(fontScale), 1), 3) - 1) * 7.5 }
    private var capsuleHeight: CGFloat { min(92, max(46, fontSize * 2.25 + 14)) }
    private var cornerRadius: CGFloat { capsuleHeight / 2 }               // 纯胶囊(半高圆角)
    private var barWidth: CGFloat { min(5, max(3, fontSize * 0.16)) }
    private var barSpacing: CGFloat { min(5, max(3, fontSize * 0.14)) }
    private var waveMaxHeight: CGFloat { min(capsuleHeight * 0.46, fontSize * 1.45) }
    private var waveWidth: CGFloat { barWidth * 5 + barSpacing * 4 }
    private var hPadding: CGFloat { min(28, max(18, fontSize * 0.82)) }
    private var itemSpacing: CGFloat { min(14, max(9, fontSize * 0.42)) }
    /// 文字区可见上限:总宽封顶 560 - 波形 - 间距 - 两侧内边距。
    private var textMaxWidth: CGFloat { max(120, 560 - waveWidth - itemSpacing - hPadding * 2) }

    var body: some View {
        content
            .padding(.horizontal, hPadding)
            .frame(height: capsuleHeight)
            .background(
                ZStack {
                    VisualEffectView(material: .hudWindow, cornerRadius: cornerRadius)
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .fill(.white.opacity(0.045))
                }
            )
            .overlay(RoundedRectangle(cornerRadius: cornerRadius)
                        .strokeBorder(.white.opacity(0.18), lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            .scaleEffect(state.capsuleVisible ? 1.0 : 0.82)
            .opacity(state.capsuleVisible ? 1.0 : 0.0)
            .animation(state.capsuleVisible
                       ? .spring(response: 0.35, dampingFraction: 0.72)   // 入场弹簧 0.35s
                       : .easeIn(duration: 0.22),                          // 退场缩放 0.22s
                       value: state.capsuleVisible)
    }

    @ViewBuilder
    private var content: some View {
        if case .error(let msg) = state.phase {
            HStack(spacing: itemSpacing) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.system(size: fontSize))
                ScrollingTailText(text: state.capsuleShowCopy ? state.text : msg,
                                  fontSize: fontSize, maxWidth: textMaxWidth)
                    .foregroundStyle(state.capsuleShowCopy ? Color.primary : Color.orange)
                if state.capsuleShowCopy {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(state.text, forType: .string)
                        state.onClose?()
                    } label: { Image(systemName: "doc.on.doc").font(.system(size: fontSize * 0.9)) }
                    .buttonStyle(.plain).help(AppL10n.tr("复制到剪贴板"))
                }
                Button { state.onRetry?() } label: {
                    Image(systemName: "arrow.clockwise").font(.system(size: fontSize * 0.9, weight: .semibold))
                }
                .buttonStyle(.plain).help(AppL10n.tr("重试识别"))
            }
        } else {
            HStack(spacing: itemSpacing) {
                capsuleStatusIcon
                ScrollingTailText(text: displayText, fontSize: fontSize, maxWidth: textMaxWidth)
                    .foregroundStyle(state.draft.isEmpty && state.text.isEmpty ? .secondary : .primary)
            }
        }
    }

    @ViewBuilder
    private var capsuleStatusIcon: some View {
        switch state.phase {
        case .recording:
            WaveformView(state: state, barWidth: barWidth, spacing: barSpacing,
                         maxHeight: waveMaxHeight, minBar: max(3, fontSize * 0.16))
        case .processing:
            ProgressView()
                .controlSize(.small)
                .tint(.orange)
                .frame(width: waveWidth, height: waveMaxHeight)
        case .editing:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: min(fontSize * 0.95, waveMaxHeight), weight: .medium))
                .foregroundStyle(.green)
                .frame(width: waveWidth, height: waveMaxHeight)
        case .error:
            EmptyView()
        }
    }

    /// 录音/识别中显示实时草稿;定稿显示 text;都空则占位「录音中 / xx 识别中」。
    private var displayText: String {
        if !state.draft.isEmpty { return state.draft }
        if !state.text.isEmpty { return state.text }
        if state.isProcessing { return state.engineLabel.isEmpty ? AppL10n.tr("识别中") : AppL10n.format("%@ 识别中", state.engineLabel) }
        return AppL10n.tr("录音中")
    }
}

// MARK: - SwiftUI Overlay View

struct RecordingOverlayView: View {
    @ObservedObject var state: OverlayState
    /// 浮窗字体倍率(设置-语音:默认 1x / 2x / 3x)。
    @AppStorage("overlayFontScale") private var fontScale: Double = 1.0

    @State private var animating = false
    @State private var sparkleVisible = true
    /// 编辑区测得高度(clamp 到 1 行~6 行),驱动自增高。
    @State private var editorHeight: CGFloat = 36

    private var fontSize: CGFloat { 13 * CGFloat(fontScale) }
    private var oneLineHeight: CGFloat { 36 * CGFloat(fontScale) }
    private var maxEditorHeight: CGFloat { 132 * CGFloat(fontScale) }   // ≈6 行
    private let editorCornerRadius: CGFloat = 12

    var body: some View {
        content
            .background(
                ZStack {
                    VisualEffectView(material: .hudWindow, cornerRadius: editorCornerRadius)
                    RoundedRectangle(cornerRadius: editorCornerRadius)
                        .fill(.white.opacity(0.025))
                    RoundedRectangle(cornerRadius: editorCornerRadius)
                        .fill(
                            LinearGradient(
                                colors: [.white.opacity(0.075), .white.opacity(0.015), .black.opacity(0.05)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                }
            )
            .overlay(
                RoundedRectangle(cornerRadius: editorCornerRadius)
                    .strokeBorder(.white.opacity(0.16), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: editorCornerRadius))
            .shadow(color: .black.opacity(0.20), radius: 12, x: 0, y: 5)
            .onAppear {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    withAnimation(.easeInOut(duration: 0.4).repeatForever(autoreverses: true)) {
                        animating = true
                        sparkleVisible.toggle()
                    }
                }
            }
    }

    @ViewBuilder
    private var content: some View {
        editorLayout   // 统一外壳:titleBar(phase 驱动状态) + editorBody(phase 驱动内容),不再二分致两窗跳
    }

    // MARK: Editor layout (录音 / 转录 / 已识别(可编辑) / 出错 —— 统一外壳)

    private var editorLayout: some View {
        VStack(spacing: 0) {
            titleBar
            editorBody
        }
        .frame(width: editorWidth)
    }

    private var titleBar: some View {
        HStack(spacing: 6) {
            statusIcon
            Text(state.escHintFlash ? AppL10n.tr("再按一次 ESC 关闭") : statusText)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(state.escHintFlash ? Color.orange : statusColor)
                .lineLimit(1)

            Spacer(minLength: 4)

            if let badge = state.exclusiveBadge {
                exclusiveChip(badge)
            }
            if !state.sourceLabel.isEmpty {
                sourceChip(state.sourceLabel)
            }
            if case .error = state.phase {
                Button { state.onRetry?() } label: {
                    Image(systemName: "arrow.clockwise").font(.system(size: 11, weight: .semibold))
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .help(AppL10n.tr("重试识别"))
            }
            Button { state.onClose?() } label: {
                Image(systemName: "xmark").font(.system(size: 15, weight: .medium))
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary.opacity(0.85))
            .help(AppL10n.tr("关闭(丢弃)"))
        }
        .padding(.leading, 14)
        .padding(.trailing, 10)
        .padding(.vertical, 9)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(.white.opacity(0.035))
                .frame(height: 1)
        }
    }

    @ViewBuilder
    private var editorBody: some View {
        if case .error(let msg) = state.phase {
            // 出错:① 顶部一行红字给出原因;② 若此前已识别出文字,继续以可编辑视图展示并保留,
            //   不再因报错而丢失(可直接提交/编辑,或点标题栏重试追加新结果)。
            VStack(alignment: .leading, spacing: 6) {
                Text(msg)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if !state.text.isEmpty {
                    EditorTextView(
                        text: $state.text,
                        fontSize: fontSize,
                        onSubmit: { state.onSubmit?() },
                        onEscape: { state.onEscape?() },
                        onHeightChange: { measured in
                            let clamped = min(max(measured.rounded(.up), oneLineHeight), maxEditorHeight)
                            if editorHeight != clamped { editorHeight = clamped }
                            state.onHeightChange?(clamped)
                        }
                    )
                    .frame(height: editorHeight)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 16)
        } else if state.phase == .recording && !state.draft.isEmpty {
            // 子模块 A 流式草稿:已识别文字(正常色)+ 新草稿(灰)。随内容增高,到 maxEditorHeight
            // 后内部滚动并**自动滚到底**,保证最新识别的文字始终可见。
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 0) {
                        (Text(state.text) + Text(state.draft).foregroundColor(state.text.isEmpty ? .primary : .secondary))
                            .font(.system(size: fontSize))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.disabled)
                            .background(GeometryReader { g in
                                Color.clear.preference(key: DraftHeightKey.self, value: g.size.height)
                            })
                        Color.clear.frame(height: 1).id("draftBottom")
                    }
                }
                .frame(height: editorHeight)
                .onChange(of: state.draft) { _ in
                    proxy.scrollTo("draftBottom", anchor: .bottom)   // 草稿变长 → 滚到底显示最新
                }
                .onPreferenceChange(DraftHeightKey.self) { h in
                    // 草稿内容高度 → 驱动自增高(clamp 到 1 行~maxEditorHeight)+ 面板重设尺寸。
                    let clamped = min(max(h.rounded(.up), oneLineHeight), maxEditorHeight)
                    if editorHeight != clamped { editorHeight = clamped; state.onHeightChange?(clamped) }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 16)
        } else if state.phase == .editing || !state.text.isEmpty {
            // 渲染可编辑视图的条件:
            // ① `.editing` 态 —— 哪怕文本被全选删空也保持编辑器 + 焦点,否则全删后
            //    掉回录音占位、TextView 失焦 → ESC×2 关不掉(已修);
            // ② 或有文本 —— 连续 PTT 再录音时 phase 回 recording/processing 也保留已累积 text。
            EditorTextView(
                text: $state.text,
                fontSize: fontSize,
                onSubmit: { state.onSubmit?() },
                onEscape: { state.onEscape?() },
                onHeightChange: { measured in
                    // 取整:消除永久波形动画持续重渲染带来的亚像素高度抖动(否则面板按 0.x 差反复 resize)。
                    let clamped = min(max(measured.rounded(.up), oneLineHeight), maxEditorHeight)
                    if editorHeight != clamped { editorHeight = clamped }
                    state.onHeightChange?(clamped)
                }
            )
            .frame(height: editorHeight)
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 16)
        } else {
            // 录音/转录态且尚无文本:占位行(波形条 / spinner / 🧠 + 状态文字)。
            recordingPlaceholder
        }
    }

    // MARK: Recording / processing placeholder (无文本时的录音·转录占位)

    @ViewBuilder
    private var recordingPlaceholder: some View {
        if state.isThinking || state.isProcessing {
            HStack(spacing: 6) {
                if state.isThinking {
                    ZStack {
                        Text("🧠").font(.system(size: 12))
                        Text("✨")
                            .font(.system(size: 7))
                            .offset(x: 7, y: -5)
                            .opacity(sparkleVisible ? 1.0 : 0.2)
                    }
                } else {
                    ProgressView().controlSize(.small)
                }
                Text(compactStatusText)
                    .font(.caption2)
                    .foregroundStyle(.primary.opacity(0.8))
                Spacer(minLength: 0)
            }
            .frame(height: 36)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.bottom, 10)
        } else {
            // 纯录音态:波形 + 「录音中」已挪到标题栏,编辑框留空(底部留一点内边距即可)。
            Color.clear.frame(height: 6)
        }
    }

    // MARK: Pieces

    @ViewBuilder
    private var statusIcon: some View {
        Group {
            switch state.phase {
            case .recording:
                // 小波形:与「录音中」字号(caption2≈11pt)等高,替换原红点。实时 RMS 驱动。
                WaveformView(state: state, barWidth: 2, spacing: 1.5, maxHeight: 14, minBar: 3)
            case .processing:
                ProgressView().controlSize(.mini)
            case .editing:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(.system(size: 14))
            case .error:
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red).font(.system(size: 13))
            }
        }
        .frame(width: 22, height: 18, alignment: .center)   // 固定槽位:phase 切换时图标宽不变,后面文字不左右抖
    }

    @ViewBuilder
    private func exclusiveChip(_ badge: ExclusiveBadge) -> some View {
        let color = SessionColorManager.swiftUIColor(for: badge.colorName)
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(badge.name)
                .font(.system(size: 11, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Capsule().fill(.white.opacity(0.055)))
    }

    private func sourceChip(_ label: String) -> some View {
        Text(label)
            .font(.system(size: 9, weight: .medium))
            .foregroundStyle(.secondary.opacity(0.56))
            .padding(.horizontal, 2)
            .padding(.vertical, 3)
    }

    private var editorWidth: CGFloat { min(560, max(160, (state.exclusiveBadge == nil ? 300 : 380) * CGFloat(fontScale))) }

    /// 识别中文案:有引擎名则「豆包流式 识别中」,无则退化「识别中」。
    private var recognizingText: String {
        state.engineLabel.isEmpty ? AppL10n.tr("识别中") : AppL10n.format("%@ 识别中", state.engineLabel)
    }

    private var compactStatusText: String {
        state.isProcessing ? recognizingText : AppL10n.tr("录音中")
    }

    private var statusText: String {
        switch state.phase {
        case .recording:  return AppL10n.tr("录音中")
        case .processing: return recognizingText
        case .editing:    return AppL10n.tr("已识别(可编辑)")
        case .error:      return AppL10n.tr("出错")
        }
    }

    private var statusColor: Color {
        switch state.phase {
        case .recording:  return .orange.opacity(0.95)
        case .processing: return .orange.opacity(0.95)
        case .editing:    return .green.opacity(0.95)
        case .error:      return .red.opacity(0.95)
        }
    }

    private func barHeight(for index: Int) -> CGFloat {
        switch index {
        case 0: return 14
        case 1: return 18
        case 2: return 12
        default: return 10
        }
    }
}

// MARK: - Editor Text View (NSTextView 包装:可靠 Enter/Shift+Enter/ESC + 原生中文 IME)

/// 用原生 `NSTextView`(自带 IME 组字),只拦截 Enter / Shift+Enter / ESC;
/// 其余键(方向/退格/中文候选)交给系统,避免吞掉用户真打的键。
struct EditorTextView: NSViewRepresentable {
    @Binding var text: String
    var fontSize: CGFloat = 13
    var onSubmit: () -> Void
    var onEscape: () -> Void
    var onHeightChange: (CGFloat) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder

        let tv = SubmitTextView()
        tv.delegate = context.coordinator
        tv.onSubmit = onSubmit
        tv.onEscape = onEscape
        tv.drawsBackground = false
        tv.isRichText = false
        tv.allowsUndo = true
        tv.font = .systemFont(ofSize: fontSize)
        tv.textContainerInset = NSSize(width: 0, height: 6)
        tv.textContainer?.lineFragmentPadding = 0
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.textContainer?.widthTracksTextView = true
        tv.string = text

        scroll.documentView = tv
        context.coordinator.textView = tv
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let tv = scroll.documentView as? SubmitTextView else { return }
        tv.onSubmit = onSubmit
        tv.onEscape = onEscape
        if tv.font?.pointSize != fontSize { tv.font = .systemFont(ofSize: fontSize) }   // 字体大小设置变化
        // 外部 setText(子模块 A / 重置)时同步;用户输入不在此覆盖(组字安全)。
        if tv.string != text && !tv.hasMarkedText() {
            tv.string = text
        }
        context.coordinator.reportHeight()
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        let parent: EditorTextView
        weak var textView: SubmitTextView?

        init(_ parent: EditorTextView) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let tv = textView else { return }
            if parent.text != tv.string { parent.text = tv.string }
            reportHeight()
        }

        func reportHeight() {
            guard let tv = textView, let lm = tv.layoutManager, let tc = tv.textContainer else { return }
            lm.ensureLayout(for: tc)
            let used = lm.usedRect(for: tc).height + tv.textContainerInset.height * 2
            // 异步上报,避开 SwiftUI 更新周期内改状态的告警。
            DispatchQueue.main.async { [parent] in parent.onHeightChange(used) }
        }
    }
}

/// `keyDown` 拦截 Enter(提交)/ Shift·Opt+Enter(换行)/ ESC(关闭判定);
/// 组字(marked text)期间全交给系统 —— Enter 用于确认候选而非提交。
final class SubmitTextView: NSTextView {
    var onSubmit: (() -> Void)?
    var onEscape: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        if hasMarkedText() { super.keyDown(with: event); return }
        switch event.keyCode {
        case 36, 76:   // Return / 小键盘 Enter
            let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if mods.contains(.shift) || mods.contains(.option) {
                super.keyDown(with: event)   // 插入换行
            } else {
                onSubmit?()
            }
        case 53:       // ESC
            onEscape?()
        case 115:      // Home → 行首(普通编辑器语义)
            moveToBeginningOfLine(nil)
        case 119:      // End → 行尾
            moveToEndOfLine(nil)
        default:
            super.keyDown(with: event)
        }
    }
}

// MARK: - NSPanel

final class RecordingOverlayPanel: NSPanel {
    /// ESC(无文本视图消费时,如「识别中」态)→ 路由给 controller 做 ESC×2 判定。
    var onCancelOperation: (() -> Void)?
    override func cancelOperation(_ sender: Any?) { onCancelOperation?() }

    init(contentView: NSView) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 170, height: 40),
            styleMask: [.nonactivatingPanel, .fullSizeContentView, .borderless],
            backing: .buffered,
            defer: true
        )
        self.level = .floating
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hidesOnDeactivate = false
        // ★ 浮动面板:nonactivating 编辑器没让 app 激活,若不设此则面板随焦点切换被系统收掉
        //   (用户报"识别完还没编辑浮窗就消失")。isFloatingPanel + .stationary 让它常驻最上、
        //   不随 app 失焦/切 Space 消失。
        self.isFloatingPanel = true
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        self.animationBehavior = .none   // 关窗口隐式动画,出现时不做缩放/位移动画(消抖)
        // 原 true(被动 HUD)→ false:editing/error 态需点击编辑。
        // recording/processing 态由 controller 动态设回 true(不抢交互)。
        self.ignoresMouseEvents = false
        self.contentView = contentView
    }

    /// 原默认 false。可编辑态需 makeKey 接受键盘输入(含中文 IME)。
    override var canBecomeKey: Bool { true }
}

// MARK: - Overlay Phase

/// Drives the title-bar status region of the (re)designed overlay editor.
/// Engine-agnostic: sub-module A (streaming partial) reuses the same phases.
enum OverlayPhase: Equatable {
    case recording        // 录音中
    case processing       // 转录中
    case editing          // 已识别(可编辑)
    case error(String)    // 出错 + 原因文本
}

// MARK: - Overlay State

/// Display chip appended to the overlay when exclusive input mode is armed.
/// Caller (app entry) wires `RecordingOverlayController.exclusiveBadgeProvider`;
/// the overlay re-reads on every show to reflect the current selection.
struct ExclusiveBadge: Equatable {
    let name: String
    let colorName: String   // SessionColorManager color name, e.g. "yellow"
}

@MainActor
final class OverlayState: ObservableObject {
    @Published var isProcessing = false
    @Published var isThinking = false   // LLM processing phase (brain icon)
    @Published var buttonAActive = false
    @Published var exclusiveBadge: ExclusiveBadge?
    // 新增 —— 全部 @Published(SwiftUI 反应性铁律,漏一个则后端对、UI 永远初始值):
    @Published var phase: OverlayPhase = .recording
    @Published var text: String = ""           // 编辑器内容(双向绑定 TextEditor)
    @Published var escHintFlash: Bool = false  // 单次 ESC 提示闪烁
    @Published var draft: String = ""          // 子模块 A:录音态实时草稿(只读),partial 刷新;定稿后清空
    @Published var sourceLabel: String = ""    // 识别来源角标(豆包流式/豆包云端/本地),标题栏显示
    @Published var engineLabel: String = ""    // 识别中所用引擎(豆包流式/豆包云端/本地 ASR),标题栏「xx 识别中」
    @Published var recordingLevel: Float = 0   // 实时音频 RMS 电平(0~1),驱动录音波形
    // 胶囊模式(REQ-012)
    @Published var capsuleVisible: Bool = false   // 入场/退场动画开关(缩放+淡入淡出)
    @Published var capsuleShowCopy: Bool = false  // 出错重试成功后:显示文本+复制(不自动注入)

    // View → Controller 回调(非 UI 绑定,无需 @Published)。Controller 在 wire 时注入。
    var onSubmit: (() -> Void)?                 // Enter 提交
    var onClose: (() -> Void)?                  // ✕ 关闭(丢弃)
    var onRetry: (() -> Void)?                  // 错误态重试
    var onEscape: (() -> Void)?                 // 编辑器内 ESC(controller 做 ESC×2 判定)
    var onHeightChange: ((CGFloat) -> Void)?    // 编辑区测得高度变化 → controller 重设面板尺寸

    /// 引擎无关注入接口。定稿文本(离线 SeACo / 流式定稿)→ 进编辑态,顺手清草稿。
    func setText(_ s: String) { text = s; draft = ""; phase = .editing }
    /// 子模块 A:流式 partial 刷新草稿(phase 保持 .recording,只读渲染)。
    func setDraft(_ s: String) { draft = s }

    /// ② 连续 PTT:末尾追加 + 智能分隔(已以换行/空格结尾则不再补空格),不清空已有内容。
    /// 末尾追加(非光标处插入)实现最稳,避开 NSTextView selection range / IME 组字期时序坑。
    func appendText(_ s: String) {
        let sep = text.isEmpty ? "" : (text.hasSuffix("\n") || text.hasSuffix(" ") ? "" : " ")
        text = text + sep + s
        draft = ""   // 连续 PTT 进编辑态清残留草稿
        phase = .editing
    }
}

// MARK: - Controller

@MainActor
final class RecordingOverlayController {
    typealias CapsuleSessionID = Int

    private var panel: RecordingOverlayPanel?
    let overlayState = OverlayState()

    /// Called at every show/refresh to pull the current exclusive-mode badge
    /// (session name + color name). Nil = no badge. App entry wires this.
    var exclusiveBadgeProvider: (@MainActor () -> ExclusiveBadge?)?

    /// Set by `showButtonA(suppressBadge:)` / `showButtonB(suppressBadge:)` to
    /// force-hide the chip for this show cycle (hotkey-triggered recording).
    private var suppressBadgeThisShow = false

    // MARK: 编辑器态新增

    /// 进入可编辑/错误态前捕获的前台 app(★ 必须在 makeKey 之前抓),提交/关闭后还原。
    private var capturedFrontmostApp: NSRunningApplication?
    /// ② 会话级标志(session-based,非 phase-based):showEditor/showError 起 → true,
    /// restore/dismiss → false。**只**用于「再识别时 append vs showEditor」决策,
    /// 与 phase-based 的 `isEditorActive`(BLE enter/esc 路由)严格区分,勿混用。
    private(set) var editorSessionActive = false
    /// ESC×2 短时窗判定的上一次 ESC 时间戳。
    private var lastEscapeAt: Date?
    /// BUG-001 现象 C:编辑器驻留时再次 PTT,录音态把 EditorTextView 换成草稿只读视图
    /// (NSTextView 销毁,用户光标位置丢失)→ 定稿只能末尾追加。showButtonA 进录音前
    /// 快照 selectedRange,appendText 定稿插入时恢复;会话结束清空。
    private var savedEditorSelection: NSRange?
    /// 本次会话的**顶边锚点**(屏幕坐标 y_top)。首帧定一次,之后高度变化只向下扩展、
    /// 顶边不动(修"再次 PTT 窗体上移");会话结束(关闭/提交/丢弃)复位为 nil 重新锚定。
    private var sessionTopY: CGFloat?
    /// Enter 提交回调,由 `showEditor(text:onSubmit:)` 注入(走原 InputRouter/typeText)。
    private var onSubmit: ((String) -> Void)?
    var onEditorSubmit: ((String) -> Void)?
    var onEditorDismiss: (() -> Void)?
    private var submittingEditor = false
    /// 错误态重试回调,由 `showError(_:onRetry:)` 注入(走现有 runASR 重跑)。
    private var onRetry: (() -> Void)?

    init() {
        wireStateCallbacks()
    }

    /// View → Controller 闭包接线(✕ / 重试 / Enter / ESC / 自增高)。
    private func wireStateCallbacks() {
        overlayState.onSubmit = { [weak self] in self?.submitEditor() }
        overlayState.onClose = { [weak self] in self?.confirmedDismiss() }
        overlayState.onRetry = { [weak self] in self?.onRetry?() }
        overlayState.onEscape = { [weak self] in self?.handleEscape() }
        overlayState.onHeightChange = { [weak self] _ in self?.resizeEditorPanel() }
    }

    /// 子模块 A:流式 partial → 刷新录音态草稿。仅录音态生效(进 editing 后忽略,防覆盖用户编辑)。
    private func acceptsCapsuleSession(_ session: CapsuleSessionID?) -> Bool {
        !isCapsuleMode || session == nil || session == capsuleGeneration
    }

    func updateDraft(_ s: String, session: CapsuleSessionID? = nil) {
        guard acceptsCapsuleSession(session) else { return }
        guard case .recording = overlayState.phase else { return }
        overlayState.setDraft(s)
        if isCapsuleMode { resizeCapsule() }   // 草稿变长 → 胶囊弹性变宽(到 560 后尾随滚动)
    }

    /// 「识别中」态用户中断(ESC×2 / ✕)→ app 取消在途识别任务 + 关流式会话。app 注入。
    var onCancelRecognition: (() -> Void)?

    /// 确认丢弃:录音/识别中 → 取消识别 + 收起整窗;编辑/错误态 → 还原焦点并收起。
    /// BUG-001 现象 B:录音态 ✕ 开放可点后,与识别中同语义(取消在途任务 + 关流式)。
    private func confirmedDismiss() {
        switch overlayState.phase {
        case .recording where overlayState.buttonAActive, .processing:
            onCancelRecognition?()
            if isCapsuleMode { dismissCapsule() } else { dismiss() }
            return
        default:
            break
        }
        if isCapsuleMode { dismissCapsule(); return }
        restoreFocusAndDismiss()
    }

    /// 设置识别来源角标(豆包流式/豆包云端/本地),定稿时由接线层调。
    func setSource(_ s: String, session: CapsuleSessionID? = nil) {
        guard acceptsCapsuleSession(session) else { return }
        overlayState.sourceLabel = s
    }

    /// 实时音频 RMS 电平(0~1)→ 驱动录音波形。录音中由 mic/BLE 高频回调。
    func updateLevel(_ l: Float) { overlayState.recordingLevel = l }

    // MARK: - 胶囊模式(REQ-012:识别即输入)

    /// 当前是否胶囊模式(默认 capsule)。与 app `@AppStorage("overlayMode")` 同键。
    var isCapsuleMode: Bool { (UserDefaults.standard.string(forKey: "overlayMode") ?? "capsule") == "capsule" }

    private var capsulePanel: RecordingOverlayPanel?
    /// 出错重试挂起:置真时下次识别成功走"复制"而非"自动注入"。showButtonA 复位、showError(胶囊)置真。
    private(set) var capsuleRetryPending = false
    /// 胶囊会话代际(BUG-002):showButtonA 自增;showCapsuleFinal 的 0.3s 延迟退场与
    /// dismissCapsule 的 0.22s 延迟清理都只对同代生效——否则上一会话的延迟块会把紧接着
    /// 开始的新会话胶囊隐藏并清态。
    /// ★ 不变式:每个独立新会话必须经 showButtonA 进入(retry 链 showProcessing/
    /// showError/showCapsuleCopy 是同一会话的延续,不自增);未来若新增绕过 showButtonA
    /// 的胶囊入口,必须同步自增本计数,否则旧代延迟块会打进新会话。
    private var capsuleGeneration = 0

    private func ensureCapsulePanel() {
        guard capsulePanel == nil else { return }
        let hosting = NSHostingView(rootView: CapsuleOverlayView(state: overlayState))
        let p = RecordingOverlayPanel(contentView: hosting)
        p.hasShadow = false   // ★ 关窗口矩形阴影(否则胶囊四角漏出深色直角);阴影靠材质自身
        p.onCancelOperation = { [weak self] in self?.dismissCapsule() }
        capsulePanel = p
    }

    /// 按 phase 呈现胶囊:录音/识别 passive 不抢焦;出错/复制态开鼠标以点重试/复制。
    private func presentCapsule() {
        ensureCapsulePanel()
        guard let panel = capsulePanel else { return }
        self.panel?.orderOut(nil)   // 双模互斥:先收编辑器 panel
        resizeCapsule()
        panel.level = .floating
        panel.hidesOnDeactivate = false
        if case .error = overlayState.phase {
            panel.ignoresMouseEvents = false   // 重试/复制可点
        } else {
            panel.ignoresMouseEvents = true    // 录音/识别不抢交互
        }
        panel.orderFront(nil)
        if !overlayState.capsuleVisible {
            DispatchQueue.main.async { [weak self] in self?.overlayState.capsuleVisible = true }
        }
    }

    /// 按 SwiftUI 内容 fittingSize 定宽(clamp 160–560),底部居中。
    private func resizeCapsule() {
        guard let panel = capsulePanel, let content = panel.contentView else { return }
        content.layoutSubtreeIfNeeded()
        let w = min(560, max(160, content.fittingSize.width.rounded(.up)))
        let h = max(40, content.fittingSize.height.rounded(.up))   // 随字号自适应高度
        guard let screen = NSScreen.main else { return }
        let f = screen.visibleFrame
        panel.setFrame(NSRect(x: f.midX - w / 2, y: f.origin.y + 90, width: w, height: h),
                       display: true, animate: false)
    }

    /// 胶囊定稿:显示定稿文本,自动注入由 app 负责;0.3s 后退场。
    @discardableResult
    func showCapsuleFinal(_ text: String, session: CapsuleSessionID?) -> Bool {
        guard acceptsCapsuleSession(session) else { return false }
        capsuleRetryPending = false
        overlayState.capsuleShowCopy = false
        overlayState.draft = ""
        overlayState.text = text
        overlayState.phase = .editing   // 非 error 布局(波形+文字);胶囊态下 present 走 passive
        overlayState.isProcessing = false
        presentCapsule()
        let gen = capsuleGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self, self.capsuleGeneration == gen else { return }   // 新会话已开始 → 不退场
            self.dismissCapsule()
        }
        return true
    }

    /// 出错重试成功:显示文本 + 复制(不自动注入),不自动退场(等用户复制/关闭)。
    func showCapsuleCopy(_ text: String, session: CapsuleSessionID?) {
        guard acceptsCapsuleSession(session) else { return }
        capsuleRetryPending = false
        overlayState.text = text
        overlayState.draft = ""
        overlayState.capsuleShowCopy = true
        overlayState.phase = .error("")   // 复用 error 布局(带复制+重试按钮)
        presentCapsule()
    }

    func dismissCapsule() {
        overlayState.capsuleVisible = false
        capsuleRetryPending = false
        let p = capsulePanel
        let gen = capsuleGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) { [weak self] in
            guard let self else { p?.orderOut(nil); return }
            // BUG-002:退场动画窗口内新会话已开始 → 本次延迟清理作废,否则会把新会话的
            // 面板 orderOut + 状态清零。双保险:capsuleGeneration 同步自增(showButtonA),
            // 补 capsuleVisible 异步置位(presentCapsule 的 main.async)在窗口尾部可能
            // 尚未落地的空隙。
            guard self.capsuleGeneration == gen, !self.overlayState.capsuleVisible else { return }
            p?.orderOut(nil)
            self.overlayState.capsuleShowCopy = false
            self.overlayState.draft = ""
            self.overlayState.text = ""
            self.overlayState.isProcessing = false
            self.overlayState.phase = .recording
            self.overlayState.buttonAActive = false   // 状态机卫生:会话已结束,防 stale true
        }
    }

    /// When `suppressBadge` is true, this invocation (hotkey-triggered Option+1)
    /// will NOT show the exclusive-session chip — the chip is reserved for BLE
    /// hardware-triggered recording, which is what actually routes through the
    /// exclusive session. Hotkeys always type at current cursor.
    @discardableResult
    func showButtonA(suppressBadge: Bool = false) -> CapsuleSessionID {
        capsuleGeneration &+= 1   // BUG-002:新会话开始,作废上一会话的延迟退场
        // BUG-001 现象 C:编辑器驻留时进录音,先快照光标位置(录音态会销毁 EditorTextView)。
        // 拿不到 tv / 非编辑器驻留一律置 nil,防上一会话的 stale 快照错位插入。
        if editorSessionActive, !isCapsuleMode {
            savedEditorSelection = panel?.contentView?.firstTextView?.selectedRange()
        } else {
            savedEditorSelection = nil
        }
        overlayState.phase = .recording
        overlayState.buttonAActive = true
        overlayState.isProcessing = false
        overlayState.draft = ""   // 子模块 A:新录音清残留草稿,避免上次会话草稿闪现
        // BUG-002:胶囊模式定稿已注入上屏,新录音必须清 text——dismissCapsule 的延迟清理
        // (0.3s 退场 + 0.22s 动画)落地前再次 PTT,旧定稿会被当作当前内容显示(displayText
        // 在 draft 为空时回退到 text)。编辑器模式不能清:连续 PTT 追加依赖 text 驻留。
        if isCapsuleMode { overlayState.text = "" }
        overlayState.sourceLabel = ""   // 新录音清来源角标
        overlayState.engineLabel = ""   // 新录音清引擎名
        overlayState.capsuleShowCopy = false   // 新录音清胶囊复制态
        capsuleRetryPending = false
        suppressBadgeThisShow = suppressBadge
        overlayState.exclusiveBadge = suppressBadgeThisShow ? nil : exclusiveBadgeProvider?()
        applyPhasePresentation()
        return capsuleGeneration
    }

    func showProcessing(engine: String = "", session: CapsuleSessionID? = nil) {
        guard acceptsCapsuleSession(session) else { return }
        overlayState.phase = .processing
        overlayState.isProcessing = true
        if !engine.isEmpty { overlayState.engineLabel = engine }
        applyPhasePresentation()
    }

    func dismissButtonA() {
        overlayState.buttonAActive = false
        sessionTopY = nil
        if isCapsuleMode { dismissCapsule(); return }
        panel?.orderOut(nil)
    }

    /// 空结果/太短丢弃时调:若编辑器**已有未提交的定稿**(editorSessionActive)——典型是
    /// Stick S3 松手后的杂散余包触发了一个空/太短录音——**不要关掉编辑器**,恢复回可编辑态;
    /// 否则(首次录音空结果)正常 dismiss。修"识别完没操作浮窗就消失"。
    func dismissOrRestoreEditing(session: CapsuleSessionID? = nil) {
        guard acceptsCapsuleSession(session) else { return }
        guard editorSessionActive else { dismissButtonA(); return }
        overlayState.draft = ""
        overlayState.phase = .editing
        applyPhasePresentation()   // re-makeKey + first responder,光标回编辑器
    }

    func dismiss() {
        overlayState.buttonAActive = false
        overlayState.isProcessing = false
        overlayState.phase = .recording
        overlayState.text = ""
        overlayState.draft = ""
        sessionTopY = nil
        suppressBadgeThisShow = false
        editorSessionActive = false
        savedEditorSelection = nil   // 会话结束:清光标快照
        panel?.orderOut(nil)
    }

    /// Legacy show for mic recording
    func show() {
        showButtonA()
    }

    // MARK: - BLE 外部控制(编辑器驻留时,Stick S3 enter/esc 键驱动编辑器)

    /// 编辑器/错误态是否正驻留 —— BLE 控制命令据此判断:改驱动编辑器,还是注入目标 app。
    var isEditorActive: Bool {
        switch overlayState.phase {
        case .editing, .error: return true
        case .recording, .processing: return false
        }
    }

    /// Stick S3 enter 键 → 提交当前编辑器(等价 Mac 键盘 Enter,走 onSubmit 注入链)。
    func submitEditorExternally() {
        guard isEditorActive else { return }
        submitEditor()
    }

    /// Stick S3 esc 键 → 关闭编辑器丢弃(设备侧 0x11 已是双击 esc 语义)。
    func closeEditorExternally() {
        guard isEditorActive else { return }
        restoreFocusAndDismiss()
    }

    // MARK: - 可编辑编辑器态

    /// 识别定稿 → 进入可编辑态。`capturedFrontmostApp` 在 makeKey **之前**抓取,
    /// 以便提交/关闭后还原目标终端焦点(焦点窃取头号风险)。
    func showEditor(text: String, onSubmit: @escaping (String) -> Void) {
        capturedFrontmostApp = NSWorkspace.shared.frontmostApplication   // ★ makeKey 之前
        self.onSubmit = onSubmit
        editorSessionActive = true
        suppressBadgeThisShow = false
        overlayState.exclusiveBadge = exclusiveBadgeProvider?()
        overlayState.setText(text)   // phase = .editing
        applyPhasePresentation()
    }

    /// 识别出错 → 错误态(标题栏转红 + 原因 + 重试)。同样在 makeKey 前捕获前台 app。
    func showError(_ message: String, session: CapsuleSessionID? = nil, onRetry: @escaping () -> Void) {
        if isCapsuleMode {
            guard acceptsCapsuleSession(session) else { return }
        }
        capturedFrontmostApp = NSWorkspace.shared.frontmostApplication   // ★ makeKey 之前
        self.onRetry = onRetry
        if isCapsuleMode {
            // 胶囊模式:标记重试挂起(下次识别成功走"复制"而非自动注入),清复制态,展示错误
            capsuleRetryPending = true
            overlayState.capsuleShowCopy = false
            overlayState.phase = .error(message)
            presentCapsule()
            return
        }
        editorSessionActive = true
        suppressBadgeThisShow = false
        overlayState.exclusiveBadge = exclusiveBadgeProvider?()
        overlayState.phase = .error(message)
        applyPhasePresentation()
    }

    /// ② 编辑会话开着时再识别 → 追加不清空,并切回编辑态(re-makeKey 抢焦)。
    /// 沿用首次 showEditor 注入的 `onSubmit` 闭包(不覆盖)与 `capturedFrontmostApp`
    /// 原始目标(★ 不重抓 —— T-015:还原回首次进编辑前的目标 app)。
    func appendText(_ s: String) {
        guard editorSessionActive else {
            showEditor(text: s, onSubmit: onSubmit ?? { _ in })
            return
        }
        overlayState.phase = .editing
        applyPhasePresentation()     // 录音态→编辑态:re-makeKey、makeFirstResponder(async)
        // makeFirstResponder 落定后,在**当前光标处**插入(而非字符串末尾),光标跟到插入文字后并滚动可见。
        DispatchQueue.main.async { [weak self] in self?.insertAtCursor(s) }
    }

    /// 在文本视图**当前插入点**插入文字(标准编辑框语义):光标在中间则插中间、在末尾则追加;
    /// 插入后光标移到新文字之后并 `scrollRangeToVisible` 保持可见。
    /// BUG-001 现象 C:录音态销毁过 EditorTextView(重建后光标默认在末尾),优先用
    /// showButtonA 快照的 `savedEditorSelection`(clamp 到当前文本长度);无 tv 时兜底
    /// 在快照位置做字符串级插入(而非无条件末尾追加)。
    private func insertAtCursor(_ s: String) {
        let saved = savedEditorSelection
        savedEditorSelection = nil
        guard let tv = panel?.contentView?.firstTextView else {
            insertIntoStateText(s, at: saved)
            return
        }
        var range = tv.selectedRange()
        if let saved {
            let len = (tv.string as NSString).length
            let loc = min(saved.location, len)
            range = NSRange(location: loc, length: min(saved.length, len - loc))
        }
        if tv.shouldChangeText(in: range, replacementString: s) {
            tv.replaceCharacters(in: range, with: s)
            tv.didChangeText()   // 触发 textDidChange → 同步 @Binding text
        }
        let caret = NSRange(location: range.location + (s as NSString).length, length: 0)
        tv.setSelectedRange(caret)
        tv.scrollRangeToVisible(caret)
        resizeEditorPanel()
    }

    /// 无 NSTextView 可用时的字符串级插入:有光标快照则替换快照 range(UTF-16 语义,
    /// clamp 防越界),否则维持原末尾追加语义。
    private func insertIntoStateText(_ s: String, at saved: NSRange?) {
        guard let saved else {
            overlayState.appendText(s)
            return
        }
        let ns = overlayState.text as NSString
        let loc = min(saved.location, ns.length)
        let len = min(saved.length, ns.length - loc)
        overlayState.text = ns.replacingCharacters(in: NSRange(location: loc, length: len), with: s)
        overlayState.draft = ""
        overlayState.phase = .editing
    }

    /// 只建一次 hostingView + panel(lazy),后续所有 phase 复用同一 contentView,
    /// 不再每个 phase `new NSHostingView` —— ① 合一为单一常驻浮窗的基石。
    private func ensurePanel() {
        guard panel == nil else { return }
        let hostingView = NSHostingView(rootView: RecordingOverlayView(state: overlayState))
        let p = RecordingOverlayPanel(contentView: hostingView)
        p.onCancelOperation = { [weak self] in self?.handleEscape() }   // 识别中按 ESC → ESC×2 判定
        panel = p
    }

    /// 按 `overlayState.phase` 调整**同一** panel 的 level / ignoresMouseEvents / key,不重建。
    /// 录音·转录态 passive 非 key 不抢焦(不打断目标 app);编辑·错误态 makeKey 可编辑。
    /// ★ T-015:capturedFrontmostApp 必须在调用本方法(makeKey)之前已捕获。
    /// 面板宽度:随字号档(overlayFontScale)放大,上限 560、下限 160。
    /// 与 RecordingOverlayView.editorWidth 同口径,保证 SwiftUI 内容与 panel 帧一致。
    private var panelWidth: CGFloat {
        let raw = UserDefaults.standard.double(forKey: "overlayFontScale")
        let scale = CGFloat(raw > 0 ? raw : 1.0)
        let base: CGFloat = overlayState.exclusiveBadge == nil ? 300 : 380
        return min(560, max(160, base * scale))
    }

    private func applyPhasePresentation() {
        if isCapsuleMode { presentCapsule(); return }   // 胶囊模式:走底部居中胶囊,不用编辑器 panel
        ensurePanel()
        guard let panel, let content = panel.contentView else { return }
        let width = panelWidth
        content.layoutSubtreeIfNeeded()
        let height = max(content.fittingSize.height.rounded(.up), 1)   // 取整,消亚像素抖
        positionPanel(width: width, height: height)   // 原子设 frame:size+origin 一次到位,消抖

        switch overlayState.phase {
        case .recording, .processing:
            // 录音/识别中:仍是浮层、不夺 app 激活(nonactivating),但**允许点 ✕ / 收 ESC**,
            // 以便中断卡住的识别(用户报"几十秒一直识别中点不动")。makeKey 让 ESC 经
            // panel.cancelOperation 走 ESC×2 判定;ignoresMouseEvents=false 让 ✕ 可点。
            // BUG-001 现象 B:录音态原为 passive(ignoresMouseEvents=true),标题栏 ✕ 恒显示
            // 却点击穿透 = 死按钮;对齐识别中态,✕/ESC×2 可中断录音。
            panel.level = .floating
            panel.hidesOnDeactivate = false
            panel.ignoresMouseEvents = false
            panel.orderFrontRegardless()
            panel.makeKey()
        case .editing, .error:
            // 可编辑:提层级 + makeKey + 令文本视图成为 first responder。
            // ★ 不 NSApp.activate(ignoringOtherApps:) —— 那会把整个 app(含主窗)抢到前台:
            //   ① 和自己的浮窗抢焦点;② 夺走目标 app(浏览器网页输入框等)的焦点,回车还原时
            //   只激活到 app 级、网页输入框焦点不回来 → typeText 落空。
            // 走 nonactivatingPanel + key panel(Spotlight 模型):浮窗可编辑但不夺 app 激活,
            // 目标 app 始终保持前台 + 输入框焦点,提交时直接注入。orderFrontRegardless 确保
            // 后台/accessory app 也能把面板顶到最前。
            panel.level = .modalPanel
            panel.hidesOnDeactivate = false
            panel.ignoresMouseEvents = false
            panel.orderFrontRegardless()
            panel.makeKey()
            DispatchQueue.main.async { [weak self] in
                guard let self, let panel = self.panel else { return }
                if let tv = panel.contentView?.firstTextView {
                    panel.makeFirstResponder(tv)
                }
                self.resizeEditorPanel()
            }
        }
    }

    /// 编辑区高度变化 → 按 SwiftUI 内容 fittingSize 重设面板尺寸并重新居中。
    /// 仅在编辑/错误态生效(录音/转录占位高度由 applyPhasePresentation 一次性定)。
    private func resizeEditorPanel() {
        guard let panel, let content = panel.contentView else { return }
        switch overlayState.phase {
        case .editing, .error: break
        case .recording, .processing:
            // 录音态有流式草稿时也要随草稿增高;纯占位(无草稿)固定高度不动。
            guard !overlayState.draft.isEmpty else { return }
        }
        let height = content.fittingSize.height.rounded(.up)   // 取整,消亚像素抖
        guard height > 1 else { return }
        let width = panelWidth
        if abs(panel.frame.height - height) >= 1 {   // 整数阈值:同一整数高度不再反复 resize
            positionPanel(width: width, height: height)   // 原子设 frame,避免缩放+平移两步
        }
    }

    /// Enter 提交:先还原目标 app 焦点(free 模式 typeText 打到 frontmost),
    /// 待目标 app **真正激活落定**后再注入(替代固定 0.15s 延迟,消除注入竞态)。
    /// exclusive PTY 路直写 tty,等待无害。
    private func submitEditor() {
        guard let cb = onSubmit else { return }
        let edited = overlayState.text
        let target = capturedFrontmostApp   // 快照:restoreFocusAndDismiss 会清空 capturedFrontmostApp
        ClaudeCodeSessionManager.log("[inject] submit captured=\(target?.bundleIdentifier ?? "nil") frontmostNow=\(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "nil")")
        onEditorSubmit?(edited)
        submittingEditor = true
        restoreFocusAndDismiss()            // orderOut + target.activate() + 复位状态
        submittingEditor = false
        injectWhenActive(target: target) { cb(edited) }
    }

    /// ③ 等 `target` 真正成为 frontmost 再注入;已 active 则立即注入,否则监听
    /// `didActivateApplicationNotification`,带 0.5s 超时兜底。修 free 模式 typeText 落错
    /// 光标/丢字的根因:固定延迟与 `capturedFrontmostApp.activate()` 异步竞态。
    /// 内存铁律:observer 用后即 `removeObserver`,`fired` 防重入(通知+超时双触发只注一次)。
    private func injectWhenActive(target: NSRunningApplication?, _ inject: @escaping () -> Void) {
        guard let target else { inject(); return }
        if NSWorkspace.shared.frontmostApplication == target {
            // 目标本就前台(nonactivating 编辑器没夺 app 激活):面板刚 orderOut,
            // 让目标窗口下一个 runloop 重获 key(输入框重聚焦)再注入,避免落空。
            ClaudeCodeSessionManager.log("[inject] target already frontmost — inject next runloop")
            DispatchQueue.main.async { inject() }
            return
        }
        var fired = false
        var token: NSObjectProtocol?
        let done: (String) -> Void = { reason in
            guard !fired else { return }
            fired = true
            if let token { NSWorkspace.shared.notificationCenter.removeObserver(token) }
            ClaudeCodeSessionManager.log("[inject] gate fired via \(reason) frontmost=\(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "nil")")
            inject()
        }
        token = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { note in
            if (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication) == target {
                done("notification")
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { done("timeout") }
    }

    /// ESC 处理:短时窗(≈0.6s)内第二次 → 关闭丢弃;否则提示"再按一次 ESC 关闭"。
    private func handleEscape() {
        let now = Date()
        if let last = lastEscapeAt, now.timeIntervalSince(last) < 0.6 {
            lastEscapeAt = nil
            confirmedDismiss()
        } else {
            lastEscapeAt = now
            overlayState.escHintFlash = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                self?.overlayState.escHintFlash = false
            }
        }
    }

    /// 提交/关闭后:收起面板 + 还原进窗前捕获的目标 app 焦点(free 模式) + 复位状态。
    private func restoreFocusAndDismiss() {
        let shouldNotifyEditorDismiss = editorSessionActive && !submittingEditor
        panel?.orderOut(nil)
        ClaudeCodeSessionManager.log("[inject] restore activate target=\(capturedFrontmostApp?.bundleIdentifier ?? "nil") frontmostBefore=\(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "nil")")
        capturedFrontmostApp?.activate()   // free 模式还原终端焦点;exclusive PTY 无需回切
        capturedFrontmostApp = nil
        lastEscapeAt = nil
        editorSessionActive = false
        savedEditorSelection = nil         // 会话结束:清光标快照
        sessionTopY = nil                  // 会话结束:下次重新锚定顶边
        overlayState.text = ""
        overlayState.escHintFlash = false
        overlayState.phase = .recording
        overlayState.buttonAActive = false   // 状态机卫生:会话已结束,防 stale true
        if shouldNotifyEditorDismiss {
            onEditorDismiss?()
        }
    }

    /// 顶边固定 + 水平居中,**一次性原子设 frame(size+origin,animate:false)** —— 避免
    /// "先 setContentSize 贴底缩放、再 setFrameOrigin 平移"两步导致出现时内容斜向抖动。
    /// 顶边锚点按**固定上限高度**(≈标题栏+6行编辑区+内边距 ≈200)算,而非首帧实际高度,
    /// 使录音→转录→识别→编辑各 phase 的高度都从同一顶边向下展开,顶边恒定不跳。
    private func positionPanel(width: CGFloat, height: CGFloat) {
        guard let panel, let screen = NSScreen.main else { return }
        let screenFrame = screen.visibleFrame
        let x = screenFrame.midX - width / 2
        if sessionTopY == nil {
            sessionTopY = screenFrame.origin.y + 100 + 200   // 顶边锚点(固定上限高度)
        }
        var y = (sessionTopY ?? screenFrame.origin.y + 300) - height   // 顶固定,向下长
        let minY = screenFrame.origin.y + 8
        if y < minY { y = minY }                              // 极长文本触底:停在屏内
        panel.setFrame(NSRect(x: x, y: y, width: width, height: height), display: true, animate: false)
    }
}

// MARK: - NSView helper

private extension NSView {
    /// 递归找出 hostingView 内嵌的第一个 NSTextView,用于 makeFirstResponder。
    var firstTextView: NSTextView? {
        if let tv = self as? NSTextView { return tv }
        for sub in subviews {
            if let tv = sub.firstTextView { return tv }
        }
        return nil
    }
}
