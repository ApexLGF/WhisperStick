import Combine
import Foundation

enum DeviceActionContext: UInt8, Codable, CaseIterable {
    case home = 0
    case customOne = 1
    case chatGPTApp = 2
    case music = 3

    static let sceneModes: [DeviceActionContext] = [.chatGPTApp, .customOne, .music]
}

enum DeviceActionControl: UInt8 {
    case buttonB = 1
    case buttonC = 2
    case dialD = 3
}

enum DeviceActionGesture: UInt8 {
    case tap = 1
    case doubleTap = 2
    case holdStart = 3
    case holdEnd = 4
    case rotate = 5
    case repeatTick = 6
}

struct DeviceActionEvent: Equatable {
    static let applicationSwitcherContextID: UInt8 = 0xFF

    /// `0` is the home screen. Non-zero values are connection-local scene
    /// tokens assigned by the Host; they are deliberately not persisted.
    let contextID: UInt8
    let control: DeviceActionControl
    let gesture: DeviceActionGesture
    let delta: Int8

    var builtInContext: DeviceActionContext? { DeviceActionContext(rawValue: contextID) }

    init?(bytes: [UInt8]) {
        guard bytes.count >= 5, bytes[0] == 0x3C,
              let control = DeviceActionControl(rawValue: bytes[2]),
              let gesture = DeviceActionGesture(rawValue: bytes[3]) else { return nil }
        self.contextID = bytes[1]
        self.control = control
        self.gesture = gesture
        self.delta = Int8(bitPattern: bytes[4])
    }
}

enum DeviceSemanticAction: String, Codable, CaseIterable, Equatable {
    case beginApplicationSwitcher
    case endApplicationSwitcher
    case enterPreferredSceneMode
    case cycleSceneMode
    case exitActionMode
    case up
    case down
    case left
    case right
    case pageUp
    case pageDown
    case backspace
    case undo
    case chatGPTNextChat
    case chatGPTPreviousChat
    case chatGPTNewChat
    case chatGPTNewTemporaryChat
    case chatGPTToggleSidebar
    case chatGPTArchiveChat
    case workBuddyNextTask
    case workBuddyPreviousTask
    case workBuddyNewTask
    case workBuddyQuickQuestion
    case workBuddyToggleArtifacts
    case workBuddyStopTask
    case volumeDown
    case volumeUp
    case playPause
    case nextTrack
    case previousTrack
}

struct WorkBuddyShortcut: Equatable {
    let keyCode: UInt16
    let modifiers: UInt64
}

enum WorkBuddyShortcutResolver {
    private static let shift: UInt64 = 1 << 17
    private static let command: UInt64 = 1 << 20

    static func resolve(_ action: DeviceSemanticAction) -> WorkBuddyShortcut? {
        switch action {
        case .workBuddyNextTask: return WorkBuddyShortcut(keyCode: 0x1E, modifiers: command)
        case .workBuddyPreviousTask: return WorkBuddyShortcut(keyCode: 0x21, modifiers: command)
        case .workBuddyNewTask: return WorkBuddyShortcut(keyCode: 0x2D, modifiers: command)
        case .workBuddyQuickQuestion:
            return WorkBuddyShortcut(keyCode: 0x2D, modifiers: command | shift)
        case .workBuddyToggleArtifacts:
            return WorkBuddyShortcut(keyCode: 0x0B, modifiers: command | shift)
        case .workBuddyStopTask: return WorkBuddyShortcut(keyCode: 0x35, modifiers: 0)
        default: return nil
        }
    }
}

enum SceneNavigationPolicy {
    static func action(for gesture: DeviceActionGesture,
                       supportsRevisedGestures: Bool) -> DeviceSemanticAction? {
        switch (gesture, supportsRevisedGestures) {
        case (.tap, true): return .cycleSceneMode
        case (.holdStart, true): return .exitActionMode
        case (.tap, false): return .exitActionMode
        case (.holdStart, false): return .cycleSceneMode
        default: return nil
        }
    }
}

struct RunningApplicationDescriptor: Equatable {
    let processIdentifier: Int32
    let bundleIdentifier: String
    let name: String
    let isEligible: Bool
}

struct RunningApplicationSelection: Equatable {
    let applications: [RunningApplicationDescriptor]
    let selectedIndex: Int

    func moving(by delta: Int8) -> RunningApplicationSelection {
        guard !applications.isEmpty else { return self }
        let count = applications.count
        let next = (selectedIndex - Int(delta) % count + count) % count
        return RunningApplicationSelection(applications: applications, selectedIndex: next)
    }
}

enum ApplicationFocusRestorePolicy {
    static func shouldRestore(snapshotProcessIdentifier: Int32,
                              targetProcessIdentifier: Int32,
                              frontmostProcessIdentifier: Int32?,
                              elementSubrole: String?) -> Bool {
        guard snapshotProcessIdentifier == targetProcessIdentifier,
              frontmostProcessIdentifier == targetProcessIdentifier else { return false }
        return elementSubrole != "AXSecureTextField"
    }
}

/// Pure list construction shared by the AppKit controller and command-line
/// tests. A bundle appears once, MRU entries come first, and the previously
/// active app is selected by default to preserve the familiar Cmd-Tab result.
enum RunningApplicationListBuilder {
    static let maximumCount = 32

    static func build(applications: [RunningApplicationDescriptor],
                      recentBundleIdentifiers: [String],
                      frontmostBundleIdentifier: String?,
                      excludedBundleIdentifier: String?) -> RunningApplicationSelection {
        let excluded = excludedBundleIdentifier?.lowercased()
        var byBundle: [String: RunningApplicationDescriptor] = [:]
        for app in applications where app.isEligible && !app.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let key = app.bundleIdentifier.lowercased()
            guard !key.isEmpty, key != excluded, byBundle[key] == nil else { continue }
            byBundle[key] = app
        }

        var ordered: [RunningApplicationDescriptor] = []
        var used = Set<String>()
        for bundleID in recentBundleIdentifiers {
            let key = bundleID.lowercased()
            guard let app = byBundle[key], used.insert(key).inserted else { continue }
            ordered.append(app)
        }
        ordered.append(contentsOf: byBundle.values
            .filter { used.insert($0.bundleIdentifier.lowercased()).inserted }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending })
        ordered = Array(ordered.prefix(maximumCount))

        let frontmost = frontmostBundleIdentifier?.lowercased()
        let selected = ordered.firstIndex { $0.bundleIdentifier.lowercased() != frontmost } ?? 0
        return RunningApplicationSelection(applications: ordered, selectedIndex: selected)
    }
}

struct ApplicationSwitcherPresentation: Equatable {
    let requestID: UInt8
    let title: String
    let applicationNames: [String]
    let selectedIndex: UInt8
    let footer: String

    static func make(requestID: UInt8, applicationNames: [String], selectedIndex: Int,
                     language: DeviceDisplayLanguage) -> ApplicationSwitcherPresentation {
        let title: String
        let footer: String
        switch language {
        case .english:
            title = "Switch Apps"
            footer = "D Rotate/Press  C Cancel"
        case .simplifiedChinese:
            title = "切换应用"
            footer = "D 旋转/单击  C 取消"
        case .traditionalChinese:
            title = "切換 App"
            footer = "D 旋轉/單擊  C 取消"
        }
        let capped = Array(applicationNames.prefix(RunningApplicationListBuilder.maximumCount))
        let safeSelection = capped.isEmpty ? 0 : min(max(0, selectedIndex), capped.count - 1)
        return ApplicationSwitcherPresentation(requestID: requestID,
                                                title: title,
                                                applicationNames: capped,
                                                selectedIndex: UInt8(safeSelection),
                                                footer: footer)
    }
}

enum ApplicationSwitcherFrameEncoder {
    static let frameType: UInt8 = 0x5B

    static func encode(_ presentation: ApplicationSwitcherPresentation) -> [[UInt8]] {
        var start: [UInt8] = [frameType, presentation.requestID, 0,
                              UInt8(presentation.applicationNames.count), presentation.selectedIndex]
        appendUTF8(presentation.title, maxBytes: 24, to: &start)
        appendUTF8(presentation.footer, maxBytes: 48, to: &start)
        var frames = [start]
        for (index, name) in presentation.applicationNames.enumerated() {
            var item: [UInt8] = [frameType, presentation.requestID, 1, UInt8(index)]
            appendUTF8(name, maxBytes: 48, to: &item)
            frames.append(item)
        }
        frames.append([frameType, presentation.requestID, 2])
        return frames
    }

    static func exit(requestID: UInt8) -> [UInt8] {
        [frameType, requestID, 3]
    }

    private static func appendUTF8(_ text: String, maxBytes: Int, to bytes: inout [UInt8]) {
        var field: [UInt8] = []
        for character in text {
            let next = Array(String(character).utf8)
            if field.count + next.count > maxBytes { break }
            field.append(contentsOf: next)
        }
        bytes.append(UInt8(field.count))
        bytes.append(contentsOf: field)
    }
}

/// Pure mapping kept independent from AppKit so the protocol contract can be
/// exhaustively tested without launching the Host application.
enum DeviceActionResolver {
    static func resolve(_ event: DeviceActionEvent) -> DeviceSemanticAction? {
        // A rotate event must carry at least one encoder detent. Rejecting zero
        // avoids turning malformed/empty frames into an arbitrary direction.
        if event.gesture == .rotate && event.delta == 0 { return nil }

        guard let context = event.builtInContext else { return nil }
        switch (context, event.control, event.gesture) {
        case (.home, .buttonC, .holdStart): return .beginApplicationSwitcher
        case (.home, .buttonC, .holdEnd): return .endApplicationSwitcher
        case (.home, .dialD, .holdStart): return .enterPreferredSceneMode

        case (.customOne, .buttonB, .tap): return .up
        case (.customOne, .buttonB, .doubleTap): return .pageUp
        case (.customOne, .buttonB, .repeatTick): return .backspace
        case (.customOne, .buttonC, .tap): return .down
        case (.customOne, .buttonC, .doubleTap): return .pageDown
        case (.customOne, .buttonC, .holdStart): return .undo
        case (.customOne, .dialD, .tap): return .exitActionMode
        case (.customOne, .dialD, .holdStart): return .cycleSceneMode
        case (.customOne, .dialD, .rotate): return event.delta >= 0 ? .left : .right

        case (.chatGPTApp, .buttonB, .tap): return .chatGPTNextChat
        case (.chatGPTApp, .buttonB, .doubleTap): return .chatGPTNewChat
        case (.chatGPTApp, .buttonB, .holdStart): return .chatGPTNewTemporaryChat
        case (.chatGPTApp, .buttonC, .tap): return .chatGPTPreviousChat
        case (.chatGPTApp, .buttonC, .doubleTap): return .chatGPTToggleSidebar
        case (.chatGPTApp, .buttonC, .holdStart): return .chatGPTArchiveChat
        case (.chatGPTApp, .dialD, .tap): return .exitActionMode
        case (.chatGPTApp, .dialD, .holdStart): return .cycleSceneMode
        case (.chatGPTApp, .dialD, .rotate): return event.delta > 0 ? .pageUp : .pageDown

        case (.music, .buttonB, .tap): return .playPause
        case (.music, .buttonC, .tap): return .nextTrack
        case (.music, .buttonC, .holdStart): return .previousTrack
        case (.music, .dialD, .tap): return .exitActionMode
        case (.music, .dialD, .holdStart): return .cycleSceneMode
        case (.music, .dialD, .rotate): return event.delta > 0 ? .volumeUp : .volumeDown
        default: return nil
        }
    }

    /// Encoder ISR ticks can accumulate before the firmware loop emits a
    /// frame. Preserve that magnitude while bounding one event so a corrupted
    /// byte cannot flood the foreground application with synthetic keys.
    static func repeatCount(for event: DeviceActionEvent) -> Int {
        guard event.gesture == .rotate else { return 1 }
        return min(abs(Int(event.delta)), 8)
    }
}

struct SceneModeAppBinding: Codable, Equatable, Identifiable {
    let bundleIdentifier: String
    var appName: String
    var mode: DeviceActionContext

    var id: String { bundleIdentifier.lowercased() }
}

enum SceneModeBuiltInKind: String, Codable, CaseIterable {
    case chatGPT
    case music
    case workBuddy
}

enum SceneModeInput: String, Codable, CaseIterable, Identifiable {
    case buttonBTap
    case buttonBDoubleTap
    case buttonBHold
    case buttonBRepeat
    case buttonCTap
    case buttonCDoubleTap
    case buttonCHold
    case buttonCRepeat
    case dialClockwise
    case dialCounterClockwise

    var id: String { rawValue }

    static func resolve(event: DeviceActionEvent) -> SceneModeInput? {
        switch (event.control, event.gesture) {
        case (.buttonB, .tap): return .buttonBTap
        case (.buttonB, .doubleTap): return .buttonBDoubleTap
        case (.buttonB, .holdStart): return .buttonBHold
        case (.buttonB, .repeatTick): return .buttonBRepeat
        case (.buttonC, .tap): return .buttonCTap
        case (.buttonC, .doubleTap): return .buttonCDoubleTap
        case (.buttonC, .holdStart): return .buttonCHold
        case (.buttonC, .repeatTick): return .buttonCRepeat
        case (.dialD, .rotate):
            guard event.delta != 0 else { return nil }
            return event.delta > 0 ? .dialClockwise : .dialCounterClockwise
        default: return nil
        }
    }
}

struct SceneModeAction: Codable, Equatable {
    enum Kind: String, Codable, CaseIterable {
        case none
        case semantic
        case keyStroke
        case activateApp
    }

    var kind: Kind
    var semantic: DeviceSemanticAction?
    var keyCode: UInt16?
    var modifiers: UInt64?
    var bundleIdentifier: String?
    var displayName: String?

    static let none = SceneModeAction(kind: .none)

    static func semantic(_ action: DeviceSemanticAction) -> SceneModeAction {
        SceneModeAction(kind: .semantic, semantic: action)
    }

    static func keyStroke(keyCode: UInt16, modifiers: UInt64 = 0,
                          displayName: String? = nil) -> SceneModeAction {
        SceneModeAction(kind: .keyStroke, keyCode: keyCode, modifiers: modifiers,
                        displayName: displayName)
    }

    static func activateApp(bundleIdentifier: String, displayName: String) -> SceneModeAction {
        SceneModeAction(kind: .activateApp, bundleIdentifier: bundleIdentifier,
                        displayName: displayName)
    }

    var isValid: Bool {
        switch kind {
        case .none: return true
        case .semantic: return semantic != nil
        case .keyStroke:
            // macOS hardware key codes currently occupy the low 7-bit range.
            // Only accept the four modifier flags exposed by the recorder so
            // imported files cannot synthesize unrelated CGEvent flags.
            let allowedModifiers: UInt64 = (1 << 17) | (1 << 18) | (1 << 19) | (1 << 20)
            guard let keyCode, keyCode <= 0x7F else { return false }
            return ((modifiers ?? 0) & ~allowedModifiers) == 0
        case .activateApp:
            return !(bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        }
    }
}

struct SceneModeCopy: Codable, Equatable {
    var title: String
    var lines: [String]

    func normalized() -> SceneModeCopy {
        let padded = Array((lines + ["", "", ""]).prefix(3))
        return SceneModeCopy(title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                             lines: padded)
    }
}

struct SceneModeLocalizedCopy: Codable, Equatable {
    var english: SceneModeCopy
    var simplifiedChinese: SceneModeCopy?
    var traditionalChinese: SceneModeCopy?

    func copy(for language: DeviceDisplayLanguage) -> SceneModeCopy {
        switch language {
        case .english: return english.normalized()
        case .simplifiedChinese: return (simplifiedChinese ?? english).normalized()
        case .traditionalChinese: return (traditionalChinese ?? simplifiedChinese ?? english).normalized()
        }
    }
}

struct SceneModeAppReference: Codable, Equatable, Identifiable {
    var bundleIdentifier: String
    var appName: String

    var id: String { bundleIdentifier.lowercased() }
}

struct SceneModeDefinition: Codable, Equatable, Identifiable {
    static let maximumCount = 32
    static let chatGPTID = UUID(uuidString: "71B2D9C0-DB44-42D0-9F3D-C12507355801")!
    static let customOneID = UUID(uuidString: "71B2D9C0-DB44-42D0-9F3D-C12507355802")!
    static let musicID = UUID(uuidString: "71B2D9C0-DB44-42D0-9F3D-C12507355803")!
    static let workBuddyID = UUID(uuidString: "71B2D9C0-DB44-42D0-9F3D-C12507355804")!

    var id: UUID
    var builtInKind: SceneModeBuiltInKind?
    var isEnabled: Bool
    var order: Int
    var copy: SceneModeLocalizedCopy
    var appBindings: [SceneModeAppReference]
    var actions: [String: SceneModeAction]

    var isBuiltIn: Bool { builtInKind != nil }

    func action(for input: SceneModeInput) -> SceneModeAction? {
        guard let action = actions[input.rawValue], action.isValid, action.kind != .none else { return nil }
        return action
    }

    static func defaults() -> [SceneModeDefinition] {
        [chatGPTDefault(), customOneDefault(), musicDefault(), workBuddyDefault()]
    }

    static func chatGPTDefault() -> SceneModeDefinition {
        SceneModeDefinition(
            id: chatGPTID, builtInKind: .chatGPT, isEnabled: true, order: 0,
            copy: localizedCopy(titleKey: "action.codex.title",
                                lineKeys: ["action.codex.b", "action.codex.c", "action.codex.d"]),
            appBindings: SceneModeRegistry.chatGPTBundleIdentifiers.sorted().map {
                SceneModeAppReference(bundleIdentifier: $0, appName: "ChatGPT")
            },
            actions: actionMap([
                (.buttonBTap, .semantic(.chatGPTNextChat)),
                (.buttonBDoubleTap, .semantic(.chatGPTNewChat)),
                (.buttonBHold, .semantic(.chatGPTNewTemporaryChat)),
                (.buttonCTap, .semantic(.chatGPTPreviousChat)),
                (.buttonCDoubleTap, .semantic(.chatGPTToggleSidebar)),
                (.buttonCHold, .semantic(.chatGPTArchiveChat)),
                (.dialClockwise, .semantic(.pageUp)),
                (.dialCounterClockwise, .semantic(.pageDown)),
            ])
        )
    }

    static func customOneDefault() -> SceneModeDefinition {
        SceneModeDefinition(
            id: customOneID, builtInKind: nil, isEnabled: true, order: 1,
            copy: localizedCopy(titleKey: "action.custom_one.title",
                                lineKeys: ["action.custom_one.b", "action.custom_one.c", "action.custom_one.d"]),
            appBindings: [],
            actions: actionMap([
                (.buttonBTap, .semantic(.up)),
                (.buttonBDoubleTap, .semantic(.pageUp)),
                (.buttonBRepeat, .semantic(.backspace)),
                (.buttonCTap, .semantic(.down)),
                (.buttonCDoubleTap, .semantic(.pageDown)),
                (.buttonCHold, .semantic(.undo)),
                (.dialClockwise, .semantic(.left)),
                (.dialCounterClockwise, .semantic(.right)),
            ])
        )
    }

    static func musicDefault() -> SceneModeDefinition {
        SceneModeDefinition(
            id: musicID, builtInKind: .music, isEnabled: true, order: 2,
            copy: localizedCopy(titleKey: "action.music.title",
                                lineKeys: ["action.music.b", "action.music.c", "action.music.d"]),
            appBindings: [SceneModeAppReference(bundleIdentifier: SceneModeRegistry.appleMusicBundleIdentifier,
                                                appName: "Apple Music")],
            actions: actionMap([
                (.buttonBTap, .semantic(.playPause)),
                (.buttonCTap, .semantic(.nextTrack)),
                (.buttonCHold, .semantic(.previousTrack)),
                (.dialClockwise, .semantic(.volumeUp)),
                (.dialCounterClockwise, .semantic(.volumeDown)),
            ])
        )
    }

    static func workBuddyDefault() -> SceneModeDefinition {
        SceneModeDefinition(
            id: workBuddyID, builtInKind: .workBuddy, isEnabled: true, order: 3,
            copy: localizedCopy(titleKey: "action.workbuddy.title",
                                lineKeys: ["action.workbuddy.b", "action.workbuddy.c",
                                           "action.workbuddy.d"]),
            appBindings: [SceneModeAppReference(bundleIdentifier: SceneModeRegistry.workBuddyBundleIdentifier,
                                                appName: "WorkBuddy")],
            actions: actionMap([
                (.buttonBTap, .semantic(.workBuddyNextTask)),
                (.buttonBDoubleTap, .semantic(.workBuddyNewTask)),
                (.buttonBHold, .semantic(.workBuddyToggleArtifacts)),
                (.buttonCTap, .semantic(.workBuddyPreviousTask)),
                (.buttonCDoubleTap, .semantic(.workBuddyQuickQuestion)),
                (.buttonCHold, .semantic(.workBuddyStopTask)),
                (.dialClockwise, .semantic(.pageDown)),
                (.dialCounterClockwise, .semantic(.pageUp)),
            ])
        )
    }

    static func newUserMode(order: Int) -> SceneModeDefinition {
        SceneModeDefinition(
            id: UUID(), builtInKind: nil, isEnabled: true, order: order,
            copy: SceneModeLocalizedCopy(
                english: SceneModeCopy(title: defaultUserTitle(language: .english),
                                       lines: ["B —", "C —", "D —"]),
                simplifiedChinese: SceneModeCopy(title: defaultUserTitle(language: .simplifiedChinese),
                                                 lines: ["B —", "C —", "D —"]),
                traditionalChinese: SceneModeCopy(title: defaultUserTitle(language: .traditionalChinese),
                                                  lines: ["B —", "C —", "D —"])
            ),
            appBindings: [], actions: [:]
        )
    }

    private static func localizedCopy(titleKey: String, lineKeys: [String]) -> SceneModeLocalizedCopy {
        func value(_ language: DeviceDisplayLanguage) -> SceneModeCopy {
            SceneModeCopy(title: DeviceI18n.action(titleKey, language: language),
                          lines: lineKeys.map { DeviceI18n.action($0, language: language) })
        }
        return SceneModeLocalizedCopy(english: value(.english),
                                      simplifiedChinese: value(.simplifiedChinese),
                                      traditionalChinese: value(.traditionalChinese))
    }

    private static func actionMap(_ entries: [(SceneModeInput, SceneModeAction)]) -> [String: SceneModeAction] {
        Dictionary(uniqueKeysWithValues: entries.map { ($0.0.rawValue, $0.1) })
    }

    private static func defaultUserTitle(language: DeviceDisplayLanguage) -> String {
        // Escapes keep Host-authored device copy out of the generated firmware
        // catalog; every glyph is already present in the shipped CJK font.
        switch language {
        case .english: return "Custom mode"
        case .simplifiedChinese: return "\u{81EA}\u{5B9A}\u{4E49}\u{6A21}\u{5F0F}"
        case .traditionalChinese: return "\u{81EA}\u{8A02}\u{6A21}\u{5F0F}"
        }
    }
}

struct SceneModeDocument: Codable, Equatable {
    static let currentSchemaVersion = 1
    var schemaVersion: Int
    var modes: [SceneModeDefinition]
}

enum SceneModeDocumentError: LocalizedError {
    case unsupportedSchema(Int)
    case emptyDocument
    case tooManyModes
    case duplicateModeID
    case invalidMode(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedSchema(let version): return "Unsupported scene schema version: \(version)"
        case .emptyDocument: return "The scene document contains no modes."
        case .tooManyModes: return "A maximum of \(SceneModeDefinition.maximumCount) scene modes is supported."
        case .duplicateModeID: return "The scene document contains duplicate mode identifiers."
        case .invalidMode(let reason): return "Invalid scene mode: \(reason)"
        }
    }
}

enum SceneModeRegistry {
    static let chatGPTBundleIdentifiers: Set<String> = ["com.openai.codex", "com.openai.chat"]
    static let appleMusicBundleIdentifier = "com.apple.music"
    static let workBuddyBundleIdentifier = "com.tencent.workbuddy.mac"
    static func preferredMode(frontmostBundleIdentifier: String?, isActive: Bool,
                              modes: [SceneModeDefinition]) -> SceneModeDefinition? {
        let enabled = modes.filter(\.isEnabled).sorted { $0.order < $1.order }
        guard !enabled.isEmpty else { return nil }
        if isActive,
           let bundleIdentifier = frontmostBundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines),
           !bundleIdentifier.isEmpty,
           let match = enabled.first(where: { mode in
               mode.appBindings.contains {
                   $0.bundleIdentifier.caseInsensitiveCompare(bundleIdentifier) == .orderedSame
               }
           }) {
            return match
        }
        return enabled.first(where: { $0.id == SceneModeDefinition.customOneID }) ?? enabled.first
    }

    static func nextMode(after id: UUID?, modes: [SceneModeDefinition]) -> SceneModeDefinition? {
        let enabled = modes.filter(\.isEnabled).sorted { $0.order < $1.order }
        guard !enabled.isEmpty else { return nil }
        guard let id, let index = enabled.firstIndex(where: { $0.id == id }) else { return enabled[0] }
        return enabled[(index + 1) % enabled.count]
    }
}

@MainActor
final class SceneModeStore: ObservableObject {
    nonisolated static let legacyBindingsKey = "sceneModeAppBindings.v1"

    @Published private(set) var modes: [SceneModeDefinition]
    @Published private(set) var lastError: String?
    private let defaults: UserDefaults
    private let fileURL: URL

    var enabledCount: Int { modes.filter(\.isEnabled).count }
    var totalCount: Int { modes.count }

    init(defaults: UserDefaults = .standard, fileURL: URL? = nil) {
        self.defaults = defaults
        self.fileURL = fileURL ?? Self.defaultFileURL()
        let backupURL = self.fileURL.appendingPathExtension("backup")
        if let document = [self.fileURL, backupURL].lazy.compactMap({ url -> SceneModeDocument? in
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? Self.decodeAndValidate(data)
        }).first {
            modes = Self.sanitized(document.modes)
        } else {
            modes = Self.migratedDefaults(defaults: defaults)
            persist()
        }
    }

    func addMode() -> SceneModeDefinition? {
        guard modes.count < SceneModeDefinition.maximumCount else {
            lastError = SceneModeDocumentError.tooManyModes.localizedDescription
            return nil
        }
        let mode = SceneModeDefinition.newUserMode(order: (modes.map(\.order).max() ?? -1) + 1)
        modes.append(mode)
        persist()
        return mode
    }

    func update(_ mode: SceneModeDefinition) {
        guard let index = modes.firstIndex(where: { $0.id == mode.id }) else { return }
        var candidate = mode
        if modes[index].isBuiltIn {
            candidate.id = modes[index].id
            candidate.builtInKind = modes[index].builtInKind
        }
        modes[index] = candidate
        modes = Self.sanitized(modes)
        persist()
    }

    func setEnabled(_ enabled: Bool, id: UUID) {
        guard let index = modes.firstIndex(where: { $0.id == id }) else { return }
        modes[index].isEnabled = enabled
        persist()
    }

    func delete(id: UUID) {
        guard let mode = modes.first(where: { $0.id == id }), !mode.isBuiltIn else { return }
        modes.removeAll { $0.id == id }
        normalizeOrder()
        persist()
    }

    func duplicate(id: UUID) -> SceneModeDefinition? {
        guard modes.count < SceneModeDefinition.maximumCount,
              var copy = modes.first(where: { $0.id == id }) else { return nil }
        copy.id = UUID()
        copy.builtInKind = nil
        copy.order = (modes.map(\.order).max() ?? -1) + 1
        copy.copy.english.title += " Copy"
        if copy.copy.simplifiedChinese != nil { copy.copy.simplifiedChinese?.title += " Copy" }
        if copy.copy.traditionalChinese != nil { copy.copy.traditionalChinese?.title += " Copy" }
        copy.appBindings = []
        modes.append(copy)
        persist()
        return copy
    }

    func move(fromOffsets: IndexSet, toOffset: Int) {
        var ordered = modes.sorted { $0.order < $1.order }
        let moving = fromOffsets.map { ordered[$0] }
        for index in fromOffsets.sorted(by: >) { ordered.remove(at: index) }
        let removedBefore = fromOffsets.filter { $0 < toOffset }.count
        ordered.insert(contentsOf: moving, at: max(0, min(ordered.count, toOffset - removedBefore)))
        modes = ordered
        normalizeOrder()
        persist()
    }

    func move(id: UUID, offset: Int) {
        var ordered = modes.sorted { $0.order < $1.order }
        guard let from = ordered.firstIndex(where: { $0.id == id }) else { return }
        let to = min(max(0, from + offset), ordered.count - 1)
        guard from != to else { return }
        let mode = ordered.remove(at: from)
        ordered.insert(mode, at: to)
        modes = ordered
        normalizeOrder()
        persist()
    }

    func restoreBuiltIn(id: UUID) {
        guard let index = modes.firstIndex(where: { $0.id == id }), modes[index].isBuiltIn else { return }
        let enabled = modes[index].isEnabled
        let order = modes[index].order
        let replacement: SceneModeDefinition
        switch id {
        case SceneModeDefinition.chatGPTID:
            replacement = SceneModeDefinition.chatGPTDefault()
        case SceneModeDefinition.musicID:
            replacement = SceneModeDefinition.musicDefault()
        case SceneModeDefinition.workBuddyID:
            replacement = SceneModeDefinition.workBuddyDefault()
        default:
            return
        }
        modes[index] = replacement
        modes[index].isEnabled = enabled
        modes[index].order = order
        modes = Self.sanitized(modes)
        persist()
    }

    func bind(appName: String, bundleIdentifier: String, to modeID: UUID) {
        let normalized = bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty, let index = modes.firstIndex(where: { $0.id == modeID }) else { return }
        for position in modes.indices {
            modes[position].appBindings.removeAll {
                $0.bundleIdentifier.caseInsensitiveCompare(normalized) == .orderedSame
            }
        }
        modes[index].appBindings.append(SceneModeAppReference(
            bundleIdentifier: normalized,
            appName: appName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? normalized : appName
        ))
        persist()
    }

    func removeBinding(bundleIdentifier: String, from modeID: UUID) {
        guard let index = modes.firstIndex(where: { $0.id == modeID }) else { return }
        modes[index].appBindings.removeAll {
            $0.bundleIdentifier.caseInsensitiveCompare(bundleIdentifier) == .orderedSame
        }
        persist()
    }

    func exportData(modeIDs: Set<UUID>? = nil) throws -> Data {
        let selected = modeIDs.map { ids in modes.filter { ids.contains($0.id) } } ?? modes
        let document = SceneModeDocument(schemaVersion: SceneModeDocument.currentSchemaVersion,
                                         modes: selected)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(document)
    }

    @discardableResult
    func importData(_ data: Data) throws -> Int {
        let document = try Self.decodeAndValidate(data)
        var imported = 0
        for var incoming in document.modes where !incoming.isBuiltIn {
            if modes.contains(where: { $0.id == incoming.id }) { incoming.id = UUID() }
            incoming.order = (modes.map(\.order).max() ?? -1) + 1
            guard modes.count < SceneModeDefinition.maximumCount else { throw SceneModeDocumentError.tooManyModes }
            modes.append(incoming)
            imported += 1
        }
        modes = Self.sanitized(modes)
        persist()
        return imported
    }

    private func normalizeOrder() {
        modes = modes.sorted { $0.order < $1.order }.enumerated().map { offset, mode in
            var updated = mode
            updated.order = offset
            return updated
        }
    }

    private func persist() {
        do {
            let directory = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: fileURL.path) {
                let backup = fileURL.appendingPathExtension("backup")
                try? FileManager.default.removeItem(at: backup)
                try? FileManager.default.copyItem(at: fileURL, to: backup)
            }
            try exportData().write(to: fileURL, options: .atomic)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    nonisolated static func decodeAndValidate(_ data: Data) throws -> SceneModeDocument {
        let document = try JSONDecoder().decode(SceneModeDocument.self, from: data)
        guard document.schemaVersion == SceneModeDocument.currentSchemaVersion else {
            throw SceneModeDocumentError.unsupportedSchema(document.schemaVersion)
        }
        guard !document.modes.isEmpty else { throw SceneModeDocumentError.emptyDocument }
        guard document.modes.count <= SceneModeDefinition.maximumCount else {
            throw SceneModeDocumentError.tooManyModes
        }
        guard Set(document.modes.map(\.id)).count == document.modes.count else {
            throw SceneModeDocumentError.duplicateModeID
        }
        for mode in document.modes {
            let copies = [mode.copy.english, mode.copy.simplifiedChinese,
                          mode.copy.traditionalChinese].compactMap { $0 }
            guard !mode.copy.english.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw SceneModeDocumentError.invalidMode("the English title is required")
            }
            guard copies.allSatisfy({ copy in
                copy.lines.count == 3 && copy.title.utf8.count <= 24 &&
                    copy.lines.allSatisfy { $0.utf8.count <= 48 }
            }) else {
                throw SceneModeDocumentError.invalidMode("menu copy exceeds its display limits")
            }
            guard mode.actions.allSatisfy({ key, action in
                SceneModeInput(rawValue: key) != nil && action.isValid
            }) else {
                throw SceneModeDocumentError.invalidMode("an action or shortcut is unsupported")
            }
            guard mode.appBindings.allSatisfy({
                !$0.bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }) else {
                throw SceneModeDocumentError.invalidMode("an App binding has no Bundle ID")
            }
        }
        return document
    }

    nonisolated static func sanitized(_ input: [SceneModeDefinition]) -> [SceneModeDefinition] {
        var seenIDs = Set<UUID>()
        var seenApps = Set<String>()
        var output: [SceneModeDefinition] = []
        for var mode in input.sorted(by: { $0.order < $1.order }) {
            guard !seenIDs.contains(mode.id), output.count < SceneModeDefinition.maximumCount else { continue }
            seenIDs.insert(mode.id)
            if mode.id == SceneModeDefinition.chatGPTID {
                mode.builtInKind = .chatGPT
            } else if mode.id == SceneModeDefinition.musicID {
                mode.builtInKind = .music
            } else if mode.id == SceneModeDefinition.workBuddyID {
                mode.builtInKind = .workBuddy
            } else {
                mode.builtInKind = nil
            }
            mode.copy = SceneModeLocalizedCopy(
                english: mode.copy.english.normalized(),
                simplifiedChinese: mode.copy.simplifiedChinese?.normalized(),
                traditionalChinese: mode.copy.traditionalChinese?.normalized()
            )
            mode.copy = migratedSceneNavigationCopy(mode.copy)
            mode.actions = mode.actions.filter {
                SceneModeInput(rawValue: $0.key) != nil && $0.value.isValid
            }
            mode.appBindings = mode.appBindings.compactMap { app in
                let bundle = app.bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
                let key = bundle.lowercased()
                guard !bundle.isEmpty, !seenApps.contains(key) else { return nil }
                seenApps.insert(key)
                let name = app.appName.trimmingCharacters(in: .whitespacesAndNewlines)
                return SceneModeAppReference(bundleIdentifier: bundle, appName: name.isEmpty ? bundle : name)
            }
            output.append(mode)
        }
        for var required in [SceneModeDefinition.chatGPTDefault(), SceneModeDefinition.musicDefault(),
                             SceneModeDefinition.workBuddyDefault()]
            where !output.contains(where: { $0.id == required.id }) {
            if output.count >= SceneModeDefinition.maximumCount,
               let removable = output.lastIndex(where: { !$0.isBuiltIn }) {
                output.remove(at: removable)
                seenApps = Set(output.flatMap(\.appBindings).map { $0.bundleIdentifier.lowercased() })
            }
            required.appBindings.removeAll { seenApps.contains($0.bundleIdentifier.lowercased()) }
            required.appBindings.forEach { seenApps.insert($0.bundleIdentifier.lowercased()) }
            if required.id == SceneModeDefinition.workBuddyID,
               let musicIndex = output.firstIndex(where: { $0.id == SceneModeDefinition.musicID }) {
                output.insert(required, at: musicIndex + 1)
            } else {
                output.append(required)
            }
        }
        return output.enumerated().map { index, mode in
            var updated = mode
            updated.order = index
            return updated
        }
    }

    nonisolated private static func migratedSceneNavigationCopy(
        _ copy: SceneModeLocalizedCopy
    ) -> SceneModeLocalizedCopy {
        func migrate(_ value: SceneModeCopy?) -> SceneModeCopy? {
            guard var value else { return nil }
            let replacements = [
                "D CW:Left CCW:Right Press:Exit Hold:Switch": "D CW:Left CCW:Right Tap:Switch Hold:Exit",
                "D PgUp/PgDown Press:Exit Hold:Switch": "D PgUp/PgDown Tap:Switch Hold:Exit",
                "D 顺转左逆转右/单击退出/长按切换": "D 顺转左逆转右/单击切换/长按退出",
                "D PgUp/PgDown/单击退出/长按切换": "D PgUp/PgDown/单击切换/长按退出",
                "D 順轉左逆轉右/單擊退出/長按切換": "D 順轉左逆轉右/單擊切換/長按退出",
                "D PgUp/PgDown/單擊退出/長按切換": "D PgUp/PgDown/單擊切換/長按退出",
            ]
            value.lines = value.lines.map { replacements[$0] ?? $0 }
            return value
        }
        return SceneModeLocalizedCopy(english: migrate(copy.english)!,
                                      simplifiedChinese: migrate(copy.simplifiedChinese),
                                      traditionalChinese: migrate(copy.traditionalChinese))
    }

    nonisolated private static func defaultFileURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("QuickVibeHost/SceneModes/scene-modes.json")
    }

    nonisolated private static func migratedDefaults(defaults: UserDefaults) -> [SceneModeDefinition] {
        var result = SceneModeDefinition.defaults()
        guard let data = defaults.data(forKey: legacyBindingsKey),
              let legacy = try? JSONDecoder().decode([SceneModeAppBinding].self, from: data) else {
            return result
        }
        for binding in legacy {
            let id: UUID
            switch binding.mode {
            case .chatGPTApp: id = SceneModeDefinition.chatGPTID
            case .music: id = SceneModeDefinition.musicID
            default: id = SceneModeDefinition.customOneID
            }
            for index in result.indices {
                result[index].appBindings.removeAll {
                    $0.bundleIdentifier.caseInsensitiveCompare(binding.bundleIdentifier) == .orderedSame
                }
            }
            if let index = result.firstIndex(where: { $0.id == id }) {
                result[index].appBindings.append(SceneModeAppReference(
                    bundleIdentifier: binding.bundleIdentifier, appName: binding.appName))
            }
        }
        return sanitized(result)
    }
}

struct DeviceActionModePresentation {
    let id: UInt8
    let title: String
    let lines: [String]
    let footer: String

    static func customOne(language: DeviceDisplayLanguage) -> DeviceActionModePresentation {
        DeviceActionModePresentation(
            id: DeviceActionContext.customOne.rawValue,
            title: DeviceI18n.action("action.custom_one.title", language: language),
            lines: [
                DeviceI18n.action("action.custom_one.b", language: language),
                DeviceI18n.action("action.custom_one.c", language: language),
                DeviceI18n.action("action.custom_one.d", language: language),
            ],
            footer: DeviceI18n.action("action.gesture_order", language: language)
        )
    }

    static func chatGPTApp(language: DeviceDisplayLanguage) -> DeviceActionModePresentation {
        DeviceActionModePresentation(
            id: DeviceActionContext.chatGPTApp.rawValue,
            title: DeviceI18n.action("action.codex.title", language: language),
            lines: [
                DeviceI18n.action("action.codex.b", language: language),
                DeviceI18n.action("action.codex.c", language: language),
                DeviceI18n.action("action.codex.d", language: language),
            ],
            footer: DeviceI18n.action("action.gesture_order", language: language)
        )
    }

    static func music(language: DeviceDisplayLanguage,
                      nowPlaying: MusicNowPlayingMetadata? = nil) -> DeviceActionModePresentation {
        let lines: [String]
        let footer: String
        if let nowPlaying {
            lines = [
                nowPlaying.title,
                nowPlaying.artist,
                DeviceI18n.action("action.music.controls", language: language),
            ]
            footer = DeviceI18n.action("action.music.now_playing_footer", language: language)
        } else {
            lines = [
                DeviceI18n.action("action.music.b", language: language),
                DeviceI18n.action("action.music.c", language: language),
                DeviceI18n.action("action.music.d", language: language),
            ]
            footer = DeviceI18n.action("action.music.footer", language: language)
        }
        return DeviceActionModePresentation(
            id: DeviceActionContext.music.rawValue,
            title: DeviceI18n.action("action.music.title", language: language),
            lines: lines,
            footer: footer
        )
    }

    static func scene(_ mode: SceneModeDefinition, token: UInt8,
                      language: DeviceDisplayLanguage,
                      nowPlaying: MusicNowPlayingMetadata? = nil) -> DeviceActionModePresentation {
        let copy = mode.copy.copy(for: language)
        var lines = copy.lines
        if mode.builtInKind == .music, let nowPlaying {
            let controls = copy.lines.prefix(2).filter { !$0.isEmpty }.joined(separator: " ")
            lines = [nowPlaying.title, nowPlaying.artist, controls]
        }
        return DeviceActionModePresentation(
            id: token,
            title: copy.title.isEmpty ? DeviceI18n.action("action.fallback_title", language: language) : copy.title,
            lines: Array((lines + ["", "", ""]).prefix(3)),
            footer: DeviceI18n.action("action.music.footer", language: language)
        )
    }

    static func noEnabledScenes(language: DeviceDisplayLanguage) -> DeviceActionModePresentation {
        let title: String
        let body: String
        switch language {
        case .english:
            title = "No scene modes"
            body = "Enable one in QuickVibeHost"
        case .simplifiedChinese:
            title = "\u{65E0}\u{60C5}\u{666F}\u{6A21}\u{5F0F}"
            body = "\u{8BF7}\u{5728} Mac \u{8BBE}\u{7F6E}"
        case .traditionalChinese:
            title = "\u{7121}\u{60C5}\u{5883}\u{6A21}\u{5F0F}"
            body = "\u{8ACB}\u{5728} Mac \u{8A2D}\u{5B9A}"
        }
        return DeviceActionModePresentation(id: 0xFE,
                                            title: title, lines: [body, "", ""],
                                            footer: DeviceI18n.action("action.music.footer", language: language))
    }
}

struct MusicNowPlayingMetadata: Equatable, Sendable {
    let title: String
    let artist: String
}

enum DeviceActionModeFrameEncoder {
    static func encode(_ mode: DeviceActionModePresentation) -> [UInt8] {
        var bytes: [UInt8] = [0x57, mode.id]
        appendUTF8(mode.title, maxBytes: 24, to: &bytes)
        for line in Array((mode.lines + ["", ""]).prefix(3)) {
            appendUTF8(line, maxBytes: 48, to: &bytes)
        }
        appendUTF8(mode.footer, maxBytes: 48, to: &bytes)
        return bytes
    }

    static let exit: [UInt8] = [0x57, 0]

    private static func appendUTF8(_ text: String, maxBytes: Int, to bytes: inout [UInt8]) {
        var field: [UInt8] = []
        for character in text {
            let next = Array(String(character).utf8)
            if field.count + next.count > maxBytes { break }
            field.append(contentsOf: next)
        }
        bytes.append(UInt8(field.count))
        bytes.append(contentsOf: field)
    }
}

enum DeviceConfigurationFrameEncoder {
    /// 0x53 keeps its v5-compatible tail extension order: micSource, language,
    /// then Laboratory feature flags. Older firmware ignores the extra byte.
    static func encode(voiceMode: UInt8, promptTitles: [String], micSource: UInt8,
                       language: DeviceDisplayLanguage,
                       laboratoryFeatures: UInt8 = 0) -> [UInt8] {
        let capped = Array(promptTitles.prefix(8))
        var bytes: [UInt8] = [0x53, voiceMode, UInt8(capped.count)]
        for title in capped {
            var truncated = ""
            var byteCount = 0
            for character in title {
                let count = character.utf8.count
                if byteCount + count > 24 { break }
                truncated.append(character)
                byteCount += count
            }
            let utf8 = Array(truncated.utf8)
            bytes.append(UInt8(utf8.count))
            bytes.append(contentsOf: utf8)
        }
        bytes.append(micSource)
        bytes.append(language.protocolValue)
        bytes.append(laboratoryFeatures & LaboratoryFeatureSettings.knownFlags)
        return bytes
    }
}

enum LaboratoryFeatureSettings {
    static let promptRecommendationsKey = "laboratoryPromptRecommendationsEnabled"
    static let inputAssistantKey = "laboratoryInputAssistantEnabled"
    static let promptRecommendationsFlag: UInt8 = 1 << 0
    static let inputAssistantFlag: UInt8 = 1 << 1
    static let knownFlags = promptRecommendationsFlag | inputAssistantFlag

    static var promptRecommendationsEnabled: Bool {
        UserDefaults.standard.bool(forKey: promptRecommendationsKey)
    }

    static var inputAssistantEnabled: Bool {
        UserDefaults.standard.bool(forKey: inputAssistantKey)
    }

    static var protocolFlags: UInt8 {
        (promptRecommendationsEnabled ? promptRecommendationsFlag : 0)
            | (inputAssistantEnabled ? inputAssistantFlag : 0)
    }
}
