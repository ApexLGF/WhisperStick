import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// 重设计后的设备 TAB：根据 `BLEManager.deviceLifecycle` 呈现空态 / 已记忆设备卡片
/// (Stick S3 或 MicPad),下方展示设备操作与「输入模式介绍」(自由 / 直通)。
/// 旧 `DeviceTab` 仍作为 legacy UI 保留，由 `useNewDeviceTabUI` 开关切换。
struct NewDeviceTab: View {
    @EnvironmentObject var bleManager: BLEManager
    @EnvironmentObject var toastCenter: FallbackToastCenter

    @State private var showDiscovery = false
    /// 单设备约束触发的"替换确认":已记忆一台设备时,再点「添加设备」先弹确认。
    /// 值为当前已记忆设备名(nil 表示对话框关闭)。
    @State private var pendingReplaceLabel: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                deviceSection
                if VibePanelBLE.isPadName(bleManager.memorizedDeviceName) {
                    deviceTabSection(icon: "slider.horizontal.3", title: AppL10n.tr("设备偏好")) {
                        MicPadDevicePreferencesSection()
                    }
                    if DeviceType.isMicStickName(bleManager.memorizedDeviceName) {
                        deviceTabSection(icon: "square.stack.3d.up", title: AppL10n.tr("情景模式")) {
                            SceneModeBindingSection()
                        }
                    }
                    deviceTabSection(icon: "waveform", title: AppL10n.tr("语音操作")) {
                        MicPadVoiceModeSection()
                    }
                }
                deviceTabSection(icon: "keyboard", title: AppL10n.tr("输入模式介绍")) {
                    InputModeIntroSection()
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 12)
        }
        .sheet(isPresented: $showDiscovery) {
            DeviceDiscoverySheet()
        }
        .confirmationDialog(
            AppL10n.tr("替换现有设备？"),
            isPresented: Binding(
                get: { pendingReplaceLabel != nil },
                set: { if !$0 { pendingReplaceLabel = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingReplaceLabel
        ) { _ in
            Button(AppL10n.tr("替换设备"), role: .destructive) {
                replaceExistingDevice()
            }
            Button(AppL10n.tr("取消"), role: .cancel) {
                pendingReplaceLabel = nil
            }
        } message: { label in
            Text(AppL10n.format("您当前已记忆设备「%@」。继续添加新设备将断开并清除旧设备记忆，同时只能记忆一台外接设备。", label))
        }
    }

    private func deviceTabSection<Content: View>(
        icon: String,
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        deviceTabSection(icon: icon, title: title, accessory: { EmptyView() }, content: content)
    }

    private func deviceTabSection<Accessory: View, Content: View>(
        icon: String,
        title: String,
        @ViewBuilder accessory: () -> Accessory,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 18)
                Text(title)
                    .font(.headline)
                Spacer()
                accessory()
            }
            content()
                .deviceTabPanel()
        }
    }

    @ViewBuilder
    private var deviceSection: some View {
        let hasStickMemory: Bool = {
            switch bleManager.deviceLifecycle {
            case .noMemory: return false
            default: return true
            }
        }()

        if !hasStickMemory {
            NoDeviceEmptyState(
                onAdd: handleAddTap,
                intro: { addMoreDevicesIntro }
            )
            .deviceTabPanel()
        } else {
            // REQ-013 ①改:已有记忆设备时隐藏整个"添加设备"区(标题+介绍+按钮);
            // 换设备路径 = 卡片「移除设备」→ 回空态 → 添加区重现(单设备约束)
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .frame(width: 18, height: 18)
                    Text(AppL10n.tr("已记忆设备"))
                        .font(.headline)
                }
                if VibePanelBLE.isPadName(bleManager.memorizedDeviceName) {
                    micPadFamilyDeviceRow
                } else {
                    StickS3DeviceCard()
                }
            }
        }
    }

    @ViewBuilder
    private var micPadFamilyDeviceRow: some View {
        MicPadDeviceCard()
    }

    private func handleAddTap() {
        if let label = currentMemorizedLabel() {
            pendingReplaceLabel = label
        } else {
            showDiscovery = true
        }
    }

    /// 返回当前已记忆的设备名；nil 表示没有任何设备被记忆。
    /// 单设备约束：只要有一台设备被记忆，添加第二台都要弹替换确认。
    private func currentMemorizedLabel() -> String? {
        if case .noMemory = bleManager.deviceLifecycle {
            return nil
        }
        return bleManager.memorizedDeviceName ?? "Stick S3"
    }

    /// 替换流程：断开 + 清记忆旧设备，然后打开发现面板。
    private func replaceExistingDevice() {
        if case .noMemory = bleManager.deviceLifecycle {
            // nothing to forget
        } else {
            bleManager.forgetDevice()
        }
        pendingReplaceLabel = nil
        showDiscovery = true
    }

    @ViewBuilder
    private var addMoreDevicesIntro: some View {
        HStack(spacing: 6) {
            deviceTypeBadge(AppL10n.tr("VE 语音棒"), icon: "waveform")
        }
    }

    private func deviceTypeBadge(_ title: String, icon: String) -> some View {
        Label(title, systemImage: icon)
            .font(.caption2)
            .fontWeight(.medium)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.primary.opacity(0.06))
            )
    }
}

// MARK: - 情景模式管理

struct SceneModeBindingSection: View {
    @EnvironmentObject var store: SceneModeStore
    @EnvironmentObject var bleManager: BLEManager
    @State private var showManager = false

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(AppL10n.format("已启用 %@/%@ 个情景模式",
                                    String(store.enabledCount), String(store.totalCount)))
                    .font(.subheadline.weight(.medium))
                Text(AppL10n.tr("长按 D 根据当前前台 App 打开优先模式；在模式内长按 D 循环切换。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if bleManager.connectionState == .connected && !bleManager.supportsDynamicSceneModes {
                    Text(AppL10n.tr("更新设备固件后可使用新增的自定义情景模式。"))
                        .font(.caption).foregroundStyle(.orange)
                }
            }
            Spacer()
            Button(AppL10n.tr("管理情景模式…")) { showManager = true }
        }
        .sheet(isPresented: $showManager) {
            SceneModeManagerView()
                .environmentObject(store)
        }
    }
}

private struct SceneModeManagerView: View {
    @EnvironmentObject var store: SceneModeStore
    @Environment(\.dismiss) private var dismiss
    @State private var editingMode: SceneModeDefinition?
    @State private var showAI = false
    @State private var message: String?
    @State private var pendingImport: PendingSceneImport?
    @State private var pendingDelete: SceneModeDefinition?

    private let columns = [GridItem(.adaptive(minimum: 270), spacing: 14)]

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(AppL10n.tr("情景模式管理")).font(.title2.bold())
                    Text(AppL10n.format("已启用 %@/%@", String(store.enabledCount), String(store.totalCount)))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(AppL10n.tr("导入…"), action: importScenes)
                Button(AppL10n.tr("导出全部…")) { exportScenes(modeIDs: nil) }
                Button(AppL10n.tr("AI 制作…")) { showAI = true }
                Button {
                    if let mode = store.addMode() { editingMode = mode }
                } label: {
                    Label(AppL10n.tr("新建"), systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                Button(AppL10n.tr("完成")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(18)

            Divider()

            ScrollView {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
                    ForEach(store.modes.sorted(by: { $0.order < $1.order })) { mode in
                        SceneModeCard(mode: mode,
                                      onEdit: { editingMode = mode },
                                      onDuplicate: { _ = store.duplicate(id: mode.id) },
                                      onDelete: { pendingDelete = mode },
                                      onExport: { exportScenes(modeIDs: [mode.id]) },
                                      onRestore: { store.restoreBuiltIn(id: mode.id) },
                                      onMoveUp: { store.move(id: mode.id, offset: -1) },
                                      onMoveDown: { store.move(id: mode.id, offset: 1) })
                    }
                }
                .padding(18)
            }

            if let message {
                Text(message).font(.caption).foregroundStyle(.secondary).padding(.bottom, 10)
            }
        }
        .frame(minWidth: 760, idealWidth: 880, minHeight: 560, idealHeight: 680)
        .sheet(item: $editingMode) { mode in
            SceneModeEditorView(mode: mode)
                .environmentObject(store)
        }
        .sheet(isPresented: $showAI) { SceneModeAIMakerView(importAction: importScenes) }
        .sheet(item: $pendingImport) { pending in
            SceneModeImportPreviewView(pending: pending) {
                do {
                    let count = try store.importData(pending.data)
                    message = AppL10n.format("已导入 %@ 个情景模式", String(count))
                } catch {
                    message = AppL10n.format("导入失败：%@", error.localizedDescription)
                }
                pendingImport = nil
            } onCancel: {
                pendingImport = nil
            }
        }
        .confirmationDialog(AppL10n.tr("删除这个情景模式？"),
                            isPresented: Binding(get: { pendingDelete != nil },
                                                 set: { if !$0 { pendingDelete = nil } }),
                            titleVisibility: .visible) {
            Button(AppL10n.tr("删除"), role: .destructive) {
                if let mode = pendingDelete { store.delete(id: mode.id) }
                pendingDelete = nil
            }
            Button(AppL10n.tr("取消"), role: .cancel) { pendingDelete = nil }
        } message: {
            Text(AppL10n.tr("删除后可通过导入备份恢复。"))
        }
    }

    private func importScenes() {
        let panel = NSOpenPanel()
        panel.title = AppL10n.tr("导入情景模式")
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try Data(contentsOf: url)
            let document = try SceneModeStore.decodeAndValidate(data)
            pendingImport = PendingSceneImport(data: data, document: document)
        } catch {
            message = AppL10n.format("导入失败：%@", error.localizedDescription)
        }
    }

    private func exportScenes(modeIDs: Set<UUID>?) {
        let panel = NSSavePanel()
        panel.title = AppL10n.tr("导出情景模式")
        panel.nameFieldStringValue = "QuickVibeHost-scenes.qvscene.json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try store.exportData(modeIDs: modeIDs).write(to: url, options: .atomic)
            message = AppL10n.tr("情景模式已导出")
        } catch {
            message = AppL10n.format("导出失败：%@", error.localizedDescription)
        }
    }
}

private struct PendingSceneImport: Identifiable {
    let id = UUID()
    let data: Data
    let document: SceneModeDocument
}

private struct SceneModeImportPreviewView: View {
    let pending: PendingSceneImport
    let onConfirm: () -> Void
    let onCancel: () -> Void

    private var importableModes: [SceneModeDefinition] {
        pending.document.modes.filter { !$0.isBuiltIn }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(AppL10n.tr("确认导入情景模式")).font(.title2.bold())
            Text(AppL10n.format("将导入 %@ 个用户情景模式；内置模式不会被外部文件覆盖。",
                                String(importableModes.count)))
                .font(.subheadline).foregroundStyle(.secondary)
            List(importableModes) { mode in
                VStack(alignment: .leading, spacing: 3) {
                    Text(mode.copy.copy(for: .selected).title).fontWeight(.medium)
                    Text(mode.appBindings.isEmpty
                         ? AppL10n.tr("未绑定 App")
                         : mode.appBindings.map(\.appName).joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary)
                    Text(AppL10n.format("配置了 %@ 个按键动作", String(mode.actions.values.filter(\.isValid).count)))
                        .font(.caption2).foregroundStyle(.secondary)
                }
                .padding(.vertical, 3)
            }
            HStack {
                Spacer()
                Button(AppL10n.tr("取消"), action: onCancel)
                Button(AppL10n.tr("确认导入"), action: onConfirm)
                    .buttonStyle(.borderedProminent)
                    .disabled(importableModes.isEmpty)
            }
        }
        .padding(20).frame(width: 560, height: 430)
    }
}

private struct SceneModeCard: View {
    @EnvironmentObject var store: SceneModeStore
    let mode: SceneModeDefinition
    let onEdit: () -> Void
    let onDuplicate: () -> Void
    let onDelete: () -> Void
    let onExport: () -> Void
    let onRestore: () -> Void
    let onMoveUp: () -> Void
    let onMoveDown: () -> Void

    private var copy: SceneModeCopy { mode.copy.copy(for: .selected) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Toggle("", isOn: Binding(get: { mode.isEnabled },
                                          set: { store.setEnabled($0, id: mode.id) }))
                    .labelsHidden()
                Text(copy.title).font(.headline).lineLimit(1)
                if mode.isBuiltIn {
                    Text(AppL10n.tr("内置")).font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(Color.accentColor.opacity(0.14)))
                }
                Spacer()
                Button(action: onMoveUp) { Image(systemName: "arrow.up") }.buttonStyle(.borderless)
                Button(action: onMoveDown) { Image(systemName: "arrow.down") }.buttonStyle(.borderless)
            }

            VStack(alignment: .leading, spacing: 7) {
                ForEach(Array(copy.lines.enumerated()), id: \.offset) { _, line in
                    Text(line.isEmpty ? "—" : line)
                        .font(.system(size: 12, design: .rounded))
                        .foregroundStyle(line.isEmpty ? .secondary : .primary)
                        .lineLimit(2)
                }
                Divider()
                Text(AppL10n.tr("D 单击退出 / 长按切换"))
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 126, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.black.opacity(0.72)))
            .foregroundStyle(.white)

            if mode.appBindings.isEmpty {
                Text(AppL10n.tr("未绑定 App")).font(.caption).foregroundStyle(.secondary)
            } else {
                Text(mode.appBindings.map(\.appName).joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }

            HStack {
                Button(AppL10n.tr("编辑"), action: onEdit)
                Button(AppL10n.tr("复制"), action: onDuplicate)
                Button(AppL10n.tr("导出"), action: onExport)
                if mode.isBuiltIn { Button(AppL10n.tr("恢复默认"), action: onRestore) }
                Spacer()
                if !mode.isBuiltIn {
                    Button(AppL10n.tr("删除"), role: .destructive, action: onDelete)
                }
            }
            .controlSize(.small)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.primary.opacity(0.055)))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.primary.opacity(0.13)))
        .opacity(mode.isEnabled ? 1 : 0.62)
    }
}

private struct SceneModeEditorView: View {
    @EnvironmentObject var store: SceneModeStore
    @Environment(\.dismiss) private var dismiss
    @State var mode: SceneModeDefinition
    @State private var language: DeviceDisplayLanguage = .selected
    @State private var validationMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(AppL10n.tr("编辑情景模式")).font(.title2.bold())
                Spacer()
                Button(AppL10n.tr("取消")) { dismiss() }
                Button(AppL10n.tr("保存")) { save() }.buttonStyle(.borderedProminent)
            }
            .padding(18)
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Picker(AppL10n.tr("设备显示语言"), selection: $language) {
                        ForEach(DeviceDisplayLanguage.allCases) { Text($0.displayName).tag($0) }
                    }
                    .pickerStyle(.segmented)

                    GroupBox(AppL10n.tr("设备菜单内容")) {
                        VStack(alignment: .leading, spacing: 10) {
                            sceneTextField(AppL10n.tr("标题"), index: nil, maxBytes: 24)
                            sceneTextField(AppL10n.tr("B 行"), index: 0, maxBytes: 48)
                            sceneTextField(AppL10n.tr("C 行"), index: 1, maxBytes: 48)
                            sceneTextField(AppL10n.tr("D 行"), index: 2, maxBytes: 48)
                            Label(AppL10n.tr("D 单击退出、长按切换是固定操作，不能覆盖。"),
                                  systemImage: "lock.fill")
                                .font(.caption).foregroundStyle(.secondary)
                        }.padding(6)
                    }

                    GroupBox(AppL10n.tr("按键动作")) {
                        VStack(spacing: 0) {
                            ForEach(SceneModeInput.allCases) { input in
                                SceneModeActionEditorRow(input: input, action: actionBinding(input))
                                if input != SceneModeInput.allCases.last { Divider() }
                            }
                        }.padding(6)
                    }

                    GroupBox(AppL10n.tr("关联 App")) {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(mode.appBindings) { app in
                                HStack {
                                    VStack(alignment: .leading) {
                                        Text(app.appName)
                                        Text(app.bundleIdentifier).font(.caption2.monospaced()).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Button(role: .destructive) {
                                        mode.appBindings.removeAll { $0.id == app.id }
                                    } label: { Image(systemName: "trash") }
                                }
                            }
                            Button(AppL10n.tr("添加 App…"), action: chooseBindingApp)
                        }.padding(6)
                    }

                    if let validationMessage {
                        Text(validationMessage).font(.caption).foregroundStyle(.red)
                    }
                }
                .padding(18)
            }
        }
        .frame(minWidth: 650, idealWidth: 720, minHeight: 620, idealHeight: 760)
    }

    @ViewBuilder
    private func sceneTextField(_ label: String, index: Int?, maxBytes: Int) -> some View {
        let binding = copyBinding(index: index)
        HStack(alignment: .firstTextBaseline) {
            Text(label).frame(width: 50, alignment: .trailing)
            TextField("", text: binding)
            Text("\(binding.wrappedValue.utf8.count)/\(maxBytes)")
                .font(.caption2.monospaced())
                .foregroundStyle(binding.wrappedValue.utf8.count > maxBytes ? .red : .secondary)
        }
    }

    private func copyBinding(index: Int?) -> Binding<String> {
        Binding {
            let copy = currentCopy()
            if let index { return copy.lines[index] }
            return copy.title
        } set: { newValue in
            var copy = currentCopy()
            if let index { copy.lines[index] = newValue } else { copy.title = newValue }
            setCurrentCopy(copy)
        }
    }

    private func currentCopy() -> SceneModeCopy {
        switch language {
        case .english: return mode.copy.english.normalized()
        case .simplifiedChinese: return (mode.copy.simplifiedChinese ?? mode.copy.english).normalized()
        case .traditionalChinese:
            return (mode.copy.traditionalChinese ?? mode.copy.simplifiedChinese ?? mode.copy.english).normalized()
        }
    }

    private func setCurrentCopy(_ copy: SceneModeCopy) {
        switch language {
        case .english: mode.copy.english = copy
        case .simplifiedChinese: mode.copy.simplifiedChinese = copy
        case .traditionalChinese: mode.copy.traditionalChinese = copy
        }
    }

    private func actionBinding(_ input: SceneModeInput) -> Binding<SceneModeAction> {
        Binding(get: { mode.actions[input.rawValue] ?? .none },
                set: { mode.actions[input.rawValue] = $0 })
    }

    private func chooseBindingApp() {
        guard let app = chooseSceneApplication() else { return }
        mode.appBindings.removeAll { $0.id == app.id }
        mode.appBindings.append(app)
    }

    private func save() {
        let copies = [mode.copy.english, mode.copy.simplifiedChinese, mode.copy.traditionalChinese].compactMap { $0 }
        if copies.contains(where: { $0.title.utf8.count > 24 || $0.lines.contains { $0.utf8.count > 48 } }) {
            validationMessage = AppL10n.tr("设备菜单文字超过长度限制，请缩短后再保存。")
            return
        }
        if mode.actions.values.contains(where: { !$0.isValid }) {
            validationMessage = AppL10n.tr("请完成快捷键或 App 的设置后再保存。")
            return
        }
        // The store enforces one preferred scene per Bundle ID. Saving this
        // draft moves duplicate bindings away from other cards atomically.
        let bindings = mode.appBindings
        mode.appBindings = []
        store.update(mode)
        for app in bindings { store.bind(appName: app.appName, bundleIdentifier: app.bundleIdentifier, to: mode.id) }
        dismiss()
    }
}

private struct SceneModeActionEditorRow: View {
    let input: SceneModeInput
    @Binding var action: SceneModeAction

    var body: some View {
        HStack(spacing: 10) {
            Text(input.displayName).frame(width: 105, alignment: .leading)
            Picker("", selection: choiceBinding) {
                Text(AppL10n.tr("无动作")).tag("none")
                Divider()
                ForEach(DeviceSemanticAction.sceneAssignable, id: \.rawValue) { semantic in
                    Text(semantic.displayName).tag("semantic:\(semantic.rawValue)")
                }
                Divider()
                Text(AppL10n.tr("自定义快捷键")).tag("key")
                Text(AppL10n.tr("激活 App")).tag("app")
            }
            .labelsHidden().frame(maxWidth: .infinity)

            if action.kind == .keyStroke {
                ShortcutCaptureField(action: $action).frame(width: 145, height: 26)
            } else if action.kind == .activateApp {
                Button(action.displayName ?? AppL10n.tr("选择 App…")) {
                    if let app = chooseSceneApplication() {
                        action = .activateApp(bundleIdentifier: app.bundleIdentifier, displayName: app.appName)
                    }
                }
            }
        }
        .padding(.vertical, 7)
    }

    private var choiceBinding: Binding<String> {
        Binding {
            switch action.kind {
            case .none: return "none"
            case .semantic: return "semantic:\(action.semantic?.rawValue ?? "")"
            case .keyStroke: return "key"
            case .activateApp: return "app"
            }
        } set: { value in
            if value == "none" { action = .none }
            else if value == "key" {
                action = SceneModeAction(kind: .keyStroke, displayName: AppL10n.tr("录制快捷键"))
            }
            else if value == "app" { action = SceneModeAction(kind: .activateApp) }
            else if value.hasPrefix("semantic:"),
                    let semantic = DeviceSemanticAction(rawValue: String(value.dropFirst("semantic:".count))) {
                action = .semantic(semantic)
            }
        }
    }
}

private struct ShortcutCaptureField: NSViewRepresentable {
    @Binding var action: SceneModeAction

    func makeNSView(context: Context) -> ShortcutCaptureNSView {
        let view = ShortcutCaptureNSView()
        view.onCapture = { keyCode, modifiers, label in
            action = .keyStroke(keyCode: keyCode, modifiers: modifiers, displayName: label)
        }
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ nsView: ShortcutCaptureNSView, context: Context) {
        nsView.label = action.displayName ?? AppL10n.tr("录制快捷键")
    }
}

private final class ShortcutCaptureNSView: NSView {
    var onCapture: ((UInt16, UInt64, String) -> Void)?
    var label = "" { didSet { needsDisplay = true } }
    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        label = AppL10n.tr("请按快捷键…")
    }

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection([.control, .option, .shift, .command])
        var pieces: [String] = []
        if flags.contains(.control) { pieces.append("⌃") }
        if flags.contains(.option) { pieces.append("⌥") }
        if flags.contains(.shift) { pieces.append("⇧") }
        if flags.contains(.command) { pieces.append("⌘") }
        let key = event.charactersIgnoringModifiers?.uppercased() ?? String(format: "0x%02X", event.keyCode)
        pieces.append(key)
        label = pieces.joined()
        onCapture?(event.keyCode, UInt64(flags.rawValue), label)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlBackgroundColor.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
        NSColor.separatorColor.setStroke()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6).stroke()
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.labelColor
        ]
        let size = label.size(withAttributes: attributes)
        label.draw(at: NSPoint(x: max(6, (bounds.width - size.width) / 2),
                               y: (bounds.height - size.height) / 2), withAttributes: attributes)
    }
}

private struct SceneModeAIMakerView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var request = ""
    let importAction: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(AppL10n.tr("AI 制作情景模式")).font(.title2.bold())
            Text(AppL10n.tr("描述你希望的按键功能。QuickVibeHost 会生成一份不含账号或设备数据的制作指令，交给任意 AI 生成配置文件。"))
                .font(.subheadline).foregroundStyle(.secondary)
            TextEditor(text: $request).font(.body).frame(minHeight: 110)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.3)))
            HStack {
                Button(AppL10n.tr("复制 AI 制作指令")) { copyAIPrompt() }
                    .buttonStyle(.borderedProminent).disabled(request.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button(AppL10n.tr("导入生成的文件…")) { importAction() }
                Spacer()
                Button(AppL10n.tr("完成")) { dismiss() }
            }
        }
        .padding(20).frame(width: 610, height: 330)
    }

    private func copyAIPrompt() {
        let prompt = """
        Create a QuickVibeHost scene-mode JSON file for this request:
        \(request)

        Return JSON only. Root format:
        {"schemaVersion":1,"modes":[{"id":"NEW UUID","builtInKind":null,"isEnabled":true,"order":0,
        "copy":{"english":{"title":"","lines":["B ...","C ...","D ..."]},
        "simplifiedChinese":{"title":"","lines":["B ...","C ...","D ..."]},
        "traditionalChinese":{"title":"","lines":["B ...","C ...","D ..."]}},
        "appBindings":[{"bundleIdentifier":"...","appName":"..."}],"actions":{}}]}
        Allowed action keys: \(SceneModeInput.allCases.map(\.rawValue).joined(separator: ", ")).
        Allowed actions are {"kind":"none"}, {"kind":"semantic","semantic":"ACTION"},
        {"kind":"keyStroke","keyCode":NUMBER,"modifiers":NUMBER,"displayName":"..."}, or
        {"kind":"activateApp","bundleIdentifier":"...","displayName":"..."}.
        Allowed semantic ACTION values: \(DeviceSemanticAction.sceneAssignable.map(\.rawValue).joined(separator: ", ")).
        Keep title within 24 UTF-8 bytes and each of exactly three lines within 48 UTF-8 bytes.
        A is reserved for voice. D press exits and D hold switches modes; do not configure them.
        """
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(prompt, forType: .string)
    }
}

private func chooseSceneApplication() -> SceneModeAppReference? {
    let panel = NSOpenPanel()
    panel.title = AppL10n.tr("选择要绑定的 App")
    panel.prompt = AppL10n.tr("选择")
    panel.allowedContentTypes = [.applicationBundle]
    panel.allowsMultipleSelection = false
    guard panel.runModal() == .OK, let url = panel.url,
          let bundle = Bundle(url: url), let bundleIdentifier = bundle.bundleIdentifier else { return nil }
    let displayName = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
        ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
        ?? url.deletingPathExtension().lastPathComponent
    return SceneModeAppReference(bundleIdentifier: bundleIdentifier, appName: displayName)
}

private extension SceneModeInput {
    var displayName: String {
        switch self {
        case .buttonBTap: return AppL10n.tr("B 单击")
        case .buttonBDoubleTap: return AppL10n.tr("B 双击")
        case .buttonBHold: return AppL10n.tr("B 长按")
        case .buttonBRepeat: return AppL10n.tr("B 长按重复")
        case .buttonCTap: return AppL10n.tr("C 单击")
        case .buttonCDoubleTap: return AppL10n.tr("C 双击")
        case .buttonCHold: return AppL10n.tr("C 长按")
        case .buttonCRepeat: return AppL10n.tr("C 长按重复")
        case .dialClockwise: return AppL10n.tr("D 顺时针")
        case .dialCounterClockwise: return AppL10n.tr("D 逆时针")
        }
    }
}

private extension DeviceSemanticAction {
    static let sceneAssignable: [DeviceSemanticAction] = [
        .up, .down, .left, .right, .pageUp, .pageDown, .backspace, .undo,
        .chatGPTNextChat, .chatGPTPreviousChat, .chatGPTNewChat,
        .chatGPTNewTemporaryChat, .chatGPTToggleSidebar, .chatGPTArchiveChat,
        .workBuddyNextTask, .workBuddyPreviousTask, .workBuddyNewTask,
        .workBuddyQuickQuestion, .workBuddyToggleArtifacts, .workBuddyStopTask,
        .volumeDown, .volumeUp, .playPause, .nextTrack, .previousTrack,
    ]

    var displayName: String {
        switch self {
        case .up: return AppL10n.tr("方向键 上")
        case .down: return AppL10n.tr("方向键 下")
        case .left: return AppL10n.tr("方向键 左")
        case .right: return AppL10n.tr("方向键 右")
        case .pageUp: return "Page Up"
        case .pageDown: return "Page Down"
        case .backspace: return "Delete"
        case .undo: return AppL10n.tr("撤销")
        case .chatGPTNextChat: return AppL10n.tr("ChatGPT 下一个会话")
        case .chatGPTPreviousChat: return AppL10n.tr("ChatGPT 上一个会话")
        case .chatGPTNewChat: return AppL10n.tr("ChatGPT 新建会话")
        case .chatGPTNewTemporaryChat: return AppL10n.tr("ChatGPT 临时会话")
        case .chatGPTToggleSidebar: return AppL10n.tr("ChatGPT 显示/隐藏侧栏")
        case .chatGPTArchiveChat: return AppL10n.tr("ChatGPT 归档会话")
        case .workBuddyNextTask: return AppL10n.tr("WorkBuddy 下一个任务")
        case .workBuddyPreviousTask: return AppL10n.tr("WorkBuddy 上一个任务")
        case .workBuddyNewTask: return AppL10n.tr("WorkBuddy 新建任务")
        case .workBuddyQuickQuestion: return AppL10n.tr("WorkBuddy 快速提问")
        case .workBuddyToggleArtifacts: return AppL10n.tr("WorkBuddy 显示/隐藏结果")
        case .workBuddyStopTask: return AppL10n.tr("WorkBuddy 停止任务")
        case .volumeDown: return AppL10n.tr("音量减小")
        case .volumeUp: return AppL10n.tr("音量增大")
        case .playPause: return AppL10n.tr("播放/暂停")
        case .nextTrack: return AppL10n.tr("下一曲")
        case .previousTrack: return AppL10n.tr("上一曲")
        default: return rawValue
        }
    }
}

// MARK: - MicPad 设备偏好

/// 设备硬件/按键相关设置。用户改动立即下发;连接时不主动覆盖设备 NVS。
struct MicPadDevicePreferencesSection: View {
    @EnvironmentObject var manager: VoiceInputManager
    @EnvironmentObject var bleManager: BLEManager

    @AppStorage(MicSourceMode.defaultsKey) private var micSourceModeRaw: Int = 0
    @AppStorage(BLEManager.buzzerVolumePercentKey) private var buzzerVolumePercent: Int = 60
    @AppStorage(BLEManager.buzzerMutedKey) private var buzzerMuted: Bool = false
    @AppStorage(BLEManager.ledBrightnessPercentKey) private var ledBrightnessPercent: Int = 32
    private let segmentHeight: CGFloat = 28

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            settingsRow(title: AppL10n.tr("设备提示音"), detail: AppL10n.tr("审批/任务提示")) {
                buzzerVolumeControl
                    .disabled(!isMicPadConnected)
            }

            Divider()

            settingsRow(title: AppL10n.tr("指示灯亮度"), detail: AppL10n.tr("状态灯/睡眠提示")) {
                segmentedControl(
                    [(0, AppL10n.tr("关闭")), (8, AppL10n.tr("弱")), (32, AppL10n.tr("标准")), (70, AppL10n.tr("亮"))],
                    selection: $ledBrightnessPercent
                )
                .onChange(of: ledBrightnessPercent) { _, newValue in
                    guard isMicPadConnected else { return }
                    guard !BLEManager.shouldSuppressDevicePreferenceEcho() else { return }
                    bleManager.sendLedBrightness(percent: UInt8(clamping: newValue))
                }
                .disabled(!isMicPadConnected)
            }

            Divider()

            settingsRow(title: AppL10n.tr("麦克风选择"), detail: AppL10n.tr("设备 A 键录音来源")) {
                segmentedControl(
                    [(MicSourceMode.device, AppL10n.tr("设备麦克风")), (MicSourceMode.system, AppL10n.tr("系统麦克风"))],
                    selection: micSourceBinding
                )
                .disabled(manager.audioCapture.inputDevices.isEmpty)
            }

            if micSourceMode == .system {
                HStack(alignment: .top, spacing: 16) {
                    Text(AppL10n.tr("当前系统麦克风"))
                        .font(.subheadline)
                        .lineLimit(1)
                    Spacer()
                    Text(currentSystemMicName)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Text(AppL10n.tr("跟随系统默认输入设备。如需切换，请在 系统设置 → 声音 → 输入 中选择；蓝牙麦（AirPods 等）激活有 1-3s 延迟且限 16kHz。"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

        }
    }

    private var buzzerVolumeControl: some View {
        HStack(spacing: 10) {
            Button {
                buzzerMuted.toggle()
            } label: {
                Image(systemName: buzzerMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .foregroundStyle(buzzerMuted ? Color.secondary : Color.accentColor)
            .help(buzzerMuted ? AppL10n.tr("取消静音") : AppL10n.tr("静音"))
            .accessibilityLabel(buzzerMuted ? AppL10n.tr("取消设备提示音静音") : AppL10n.tr("设备提示音静音"))
            .onChange(of: buzzerMuted) { _, muted in
                guard isMicPadConnected else { return }
                guard !BLEManager.shouldSuppressDevicePreferenceEcho() else { return }
                bleManager.sendBuzzerVolume(pct: muted ? 0 : UInt8(clamping: buzzerVolumePercent))
            }

            Slider(
                value: Binding(
                    get: { Double(buzzerVolumePercent) },
                    set: { buzzerVolumePercent = Int(($0 / 20).rounded()) * 20 }
                ),
                in: 0...100,
                step: 20
            )
            .controlSize(.small)
            .frame(maxWidth: .infinity)
            .opacity(buzzerMuted ? 0.45 : 1)
            .onChange(of: buzzerVolumePercent) { _, newValue in
                guard isMicPadConnected else { return }
                guard !BLEManager.shouldSuppressDevicePreferenceEcho() else { return }
                guard !buzzerMuted else { return }
                bleManager.sendBuzzerVolumePreview(pct: UInt8(clamping: newValue))
            }

            Text("\(buzzerVolumePercent)%")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 34, alignment: .trailing)
        }
        .frame(maxWidth: .infinity)
    }

    private var isMicPadConnected: Bool {
        bleManager.deviceLifecycle == .memorizedConnected
    }

    private var micSourceMode: MicSourceMode {
        MicSourceMode(rawValue: micSourceModeRaw) ?? .device
    }

    private var micSourceBinding: Binding<MicSourceMode> {
        Binding(
            get: { micSourceMode },
            set: { newValue in
                DispatchQueue.main.async {
                    micSourceModeRaw = newValue.rawValue
                    QuickVibeHostApp.pushV5Config(ble: bleManager)
                }
            }
        )
    }

    private var currentSystemMicName: String {
        guard let did = manager.audioCapture.systemDefaultInputDeviceID(),
              let d = manager.audioCapture.inputDevices.first(where: { $0.id == did }) else {
            return manager.audioCapture.inputDevices.first?.name ?? AppL10n.tr("未检测到输入设备")
        }
        return d.name
    }

    private func settingsRow<Content: View>(
        title: String,
        detail: String,
        @ViewBuilder control: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.subheadline)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            control()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minHeight: 34)
    }

    private func segmentedControl<Value: Hashable>(
        _ options: [(Value, String)],
        selection: Binding<Value>
    ) -> some View {
        HStack(spacing: 0) {
            ForEach(options, id: \.0) { value, label in
                ZStack {
                    Rectangle().fill(Color.clear)
                    Text(label)
                        .fontWeight(.medium)
                }
                .frame(maxWidth: .infinity)
                .frame(height: segmentHeight)
                .contentShape(Rectangle())
                .onTapGesture {
                    selection.wrappedValue = value
                }
                .foregroundStyle(selection.wrappedValue == value ? Color.white : Color.primary)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(selection.wrappedValue == value ? Color.accentColor : Color.clear)
                )
                .accessibilityAddTraits(selection.wrappedValue == value ? .isSelected : [])
            }
        }
        .padding(2)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.primary.opacity(0.08))
        )
    }
}

// MARK: - PCB v12: 语音操作说明

/// A 键会自动区分单击、双击和长按，不再要求用户预先选择模式。
struct MicPadVoiceModeSection: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(AppL10n.tr("单击说话"), systemImage: "waveform.circle")
                .fontWeight(.semibold)
            Text(AppL10n.tr("双击 A 键开始录音，再单击 A 键停止。"))
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider()

            Label(AppL10n.tr("按住说话"), systemImage: "hand.tap")
                .fontWeight(.semibold)
            Text(AppL10n.tr("长按 A 键开始录音，松开停止。单击 A 键发送回车。"))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private extension View {
    func deviceTabPanel() -> some View {
        self
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.primary.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.primary.opacity(0.12), lineWidth: 1)
            )
    }
}
