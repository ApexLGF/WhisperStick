import AppKit
import ApplicationServices
import Combine
import Foundation
import os

private let chatGPTBundleIdentifiers = ["com.openai.codex", "com.openai.chat"]
private let chatGPTMaxTraversalDepth = 36
private let chatGPTMaxElementCount = 6_000

struct ChatGPTConversation: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let occurrence: Int
    let isSelected: Bool
}

enum ChatGPTConversationAvailability: Equatable, Sendable {
    case ready
    case appNotRunning
    case accessibilityDenied
    case sidebarUnavailable
    case scanFailed
}

/// 可单测的辅助功能候选。生产扫描只把侧栏按钮压缩成这些事实，分类规则不依赖 AXUIElement。
struct ChatGPTConversationCandidate: Equatable, Sendable {
    let role: String
    let title: String
    let descendantDescriptions: Set<String>
    let isSelected: Bool
}

enum ChatGPTConversationClassifier {
    private static let pinActions: Set<String> = [
        "Pin chat", "Pin conversation", "置顶聊天", "置頂聊天", "釘選聊天", "釘選對話",
    ]
    private static let archiveActions: Set<String> = [
        "Archive chat", "Archive conversation", "归档聊天", "歸檔聊天", "封存聊天", "封存對話",
    ]

    static func isSidebarConversation(_ candidate: ChatGPTConversationCandidate) -> Bool {
        guard candidate.role == kAXButtonRole,
              !candidate.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        return !pinActions.isDisjoint(with: candidate.descendantDescriptions)
            && !archiveActions.isDisjoint(with: candidate.descendantDescriptions)
    }

    /// ChatGPT 的统一侧栏会同时列出普通聊天与 Codex Work。Codex 的标题来自本地
    /// session_index.jsonl，先排除后再按「同名出现序号」生成本轮稳定定位键。
    static func conversations(from candidates: [ChatGPTConversationCandidate],
                              excludingCodexTitles: Set<String>) -> [ChatGPTConversation] {
        let excluded = Set(excludingCodexTitles.map(normalizeTitle))
        var occurrences: [String: Int] = [:]
        var result: [ChatGPTConversation] = []

        for candidate in candidates where isSidebarConversation(candidate) {
            let title = candidate.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalized = normalizeTitle(title)
            guard !excluded.contains(normalized) else { continue }
            let occurrence = occurrences[normalized, default: 0]
            occurrences[normalized] = occurrence + 1
            result.append(ChatGPTConversation(
                id: "chatgpt:\(normalized):\(occurrence)",
                title: title,
                occurrence: occurrence,
                isSelected: candidate.isSelected
            ))
        }
        return result
    }

    static func normalizeTitle(_ title: String) -> String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }

    /// 设备屏幕最多 12 行；普通聊天最多占 4 行，且扫描不可用时不能下发旧缓存。
    static func deviceConversations(_ conversations: [ChatGPTConversation],
                                    availability: ChatGPTConversationAvailability,
                                    limit: Int = 4) -> [ChatGPTConversation] {
        guard availability == .ready, limit > 0 else { return [] }
        return Array(conversations.prefix(limit))
    }
}

/// 普通 ChatGPT 聊天的数据源。
///
/// 只读取 ChatGPT 已加载在侧栏中的标题/选中态，并用 AXPress 打开；不读取账户凭据、
/// 私有接口或消息内容。ChatGPT UI 改版时会降级为 sidebarUnavailable，不伪造空列表。
@MainActor
final class ChatGPTConversationMonitor: ObservableObject {
    @Published private(set) var conversations: [ChatGPTConversation] = []
    @Published private(set) var availability: ChatGPTConversationAvailability = .appNotRunning
    @Published private(set) var isScanning = false
    @Published private(set) var lastUpdated: Date?

    private static let logger = Logger(
        subsystem: "com.vibeeverything.QuickVibeHost",
        category: "ChatGPTConversation"
    )
    private static let scanInterval: TimeInterval = 4

    private var timer: Timer?
    private var scanInFlight = false

    func start() {
        guard timer == nil else { return }
        rescan()
        timer = Timer.scheduledTimer(withTimeInterval: Self.scanInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.rescan() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func rescan() {
        guard !scanInFlight else { return }
        scanInFlight = true
        isScanning = true

        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = Self.scan()
            DispatchQueue.main.async {
                guard let self else { return }
                self.scanInFlight = false
                self.isScanning = false
                self.availability = result.availability
                if result.availability == .ready {
                    self.conversations = result.conversations
                    self.lastUpdated = Date()
                } else if result.availability == .appNotRunning {
                    self.conversations = []
                }
                Self.logger.debug(
                    "scan availability=\(String(describing: result.availability), privacy: .public) conversations=\(result.conversations.count)"
                )
            }
        }
    }

    func open(_ conversation: ChatGPTConversation) {
        let locator = (title: conversation.title, occurrence: conversation.occurrence)
        // ChatGPT/Codex 的侧栏按钮在应用位于后台时偶尔拒绝 AXPress。先把窗口
        // 激活，再给它一个很短的事件循环窗口，设备确认和 App 内“打开”共用此链路。
        activateChatGPT()
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.18) { [weak self] in
            let opened = Self.pressConversation(title: locator.title, occurrence: locator.occurrence)
            DispatchQueue.main.async {
                guard let self else { return }
                if opened {
                    Self.logger.notice(
                        "open succeeded title=\(locator.title, privacy: .public) occurrence=\(locator.occurrence)"
                    )
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                        self?.rescan()
                    }
                } else {
                    self.availability = .sidebarUnavailable
                    Self.logger.warning("open failed title=\(locator.title, privacy: .public) occurrence=\(locator.occurrence)")
                }
            }
        }
    }

    @discardableResult
    func openConversation(id: String) -> Bool {
        // 设备上的列表来自最近一次成功扫描。确认瞬间即使周期扫描暂时报告
        // sidebarUnavailable，也应继续用这份缓存定位；appNotRunning 时缓存会清空。
        guard let conversation = conversations.first(where: { $0.id == id }) else {
            Self.logger.warning("device open missing cached id=\(id, privacy: .public)")
            return false
        }
        Self.logger.notice("device open requested id=\(id, privacy: .public)")
        open(conversation)
        return true
    }

    private func activateChatGPT() {
        guard let app = Self.runningChatGPTApplication() else { return }
        if app.isHidden { app.unhide() }
        _ = app.activate()
    }

    private struct ScanResult {
        let availability: ChatGPTConversationAvailability
        let conversations: [ChatGPTConversation]
    }

    private struct QueueEntry {
        let element: AXUIElement
        let depth: Int
    }

    nonisolated private static func scan() -> ScanResult {
        guard AXIsProcessTrusted() else {
            return ScanResult(availability: .accessibilityDenied, conversations: [])
        }
        guard let app = runningChatGPTApplication() else {
            return ScanResult(availability: .appNotRunning, conversations: [])
        }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        guard let windows = elements(axApp, attribute: kAXWindowsAttribute), !windows.isEmpty else {
            return ScanResult(availability: .scanFailed, conversations: [])
        }

        let candidates = sidebarCandidates(in: windows)
        let conversations = ChatGPTConversationClassifier.conversations(
            from: candidates,
            excludingCodexTitles: codexWorkTitles()
        )
        return ScanResult(
            availability: conversations.isEmpty ? .sidebarUnavailable : .ready,
            conversations: conversations
        )
    }

    nonisolated private static func pressConversation(title: String, occurrence: Int) -> Bool {
        guard AXIsProcessTrusted(), let app = runningChatGPTApplication() else { return false }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        guard let windows = elements(axApp, attribute: kAXWindowsAttribute) else { return false }
        let normalizedTarget = ChatGPTConversationClassifier.normalizeTitle(title)
        var matchingIndex = 0

        for element in traversedElements(in: windows) {
            guard string(element, attribute: kAXRoleAttribute) == kAXButtonRole else { continue }
            let candidateTitle = string(element, attribute: kAXTitleAttribute)
            guard ChatGPTConversationClassifier.normalizeTitle(candidateTitle) == normalizedTarget else { continue }
            let candidate = makeCandidate(element)
            guard ChatGPTConversationClassifier.isSidebarConversation(candidate) else { continue }
            if matchingIndex == occurrence {
                if candidate.isSelected { return true }

                // ChatGPT 当前版本会对会话行的 AXPress 返回 success，却不执行导航。
                // 先保留语义点击；若选中态没有变化，再点击该行左侧标题区域。
                let pressResult = AXUIElementPerformAction(element, kAXPressAction as CFString)
                Thread.sleep(forTimeInterval: 0.10)
                if bool(element, attribute: kAXSelectedAttribute) { return true }
                let clicked = clickConversationRow(element)
                Logger(subsystem: "com.vibeeverything.QuickVibeHost",
                       category: "ChatGPTConversation").notice(
                    "AXPress result=\(pressResult.rawValue) selected=false coordinateFallback=\(clicked)"
                )
                return clicked
            }
            matchingIndex += 1
        }
        return false
    }

    /// ChatGPT 的会话行右侧包含置顶/归档按钮，坐标回退只点击左侧 35% 的标题区。
    nonisolated private static func clickConversationRow(_ element: AXUIElement) -> Bool {
        guard let origin = pointValue(element, attribute: kAXPositionAttribute),
              let size = sizeValue(element, attribute: kAXSizeAttribute),
              size.width > 1, size.height > 1 else { return false }
        let insetX = min(max(size.width * 0.35, 36), size.width - 12)
        let point = CGPoint(x: origin.x + insetX, y: origin.y + size.height * 0.5)
        guard let move = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                                 mouseCursorPosition: point, mouseButton: .left),
              let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown,
                                 mouseCursorPosition: point, mouseButton: .left),
              let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp,
                               mouseCursorPosition: point, mouseButton: .left) else { return false }
        move.post(tap: .cghidEventTap)
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }

    nonisolated private static func pointValue(_ element: AXUIElement, attribute: String) -> CGPoint? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &raw) == .success,
              let raw, CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        let value = raw as! AXValue
        var result = CGPoint.zero
        return AXValueGetValue(value, .cgPoint, &result) ? result : nil
    }

    nonisolated private static func sizeValue(_ element: AXUIElement, attribute: String) -> CGSize? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &raw) == .success,
              let raw, CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        let value = raw as! AXValue
        var result = CGSize.zero
        return AXValueGetValue(value, .cgSize, &result) ? result : nil
    }

    nonisolated private static func sidebarCandidates(in roots: [AXUIElement]) -> [ChatGPTConversationCandidate] {
        traversedElements(in: roots).compactMap { element in
            guard string(element, attribute: kAXRoleAttribute) == kAXButtonRole else { return nil }
            let title = string(element, attribute: kAXTitleAttribute)
            guard !title.isEmpty else { return nil }
            let candidate = makeCandidate(element)
            return ChatGPTConversationClassifier.isSidebarConversation(candidate) ? candidate : nil
        }
    }

    nonisolated private static func makeCandidate(_ element: AXUIElement) -> ChatGPTConversationCandidate {
        var descriptions = Set<String>()
        var queue = [QueueEntry(element: element, depth: 0)]
        var cursor = 0
        while cursor < queue.count {
            let entry = queue[cursor]
            cursor += 1
            if entry.depth > 0 {
                let description = string(entry.element, attribute: kAXDescriptionAttribute)
                if !description.isEmpty { descriptions.insert(description) }
            }
            // 真实侧栏中聊天卡的置顶/归档按钮距标题根节点最多 3 层；限制为 3 可避免
            // 把「最近」「置顶」等包住整组聊天的分区按钮误识别成一条会话。
            guard entry.depth < 3 else { continue }
            for child in elements(entry.element, attribute: kAXChildrenAttribute) ?? [] {
                queue.append(QueueEntry(element: child, depth: entry.depth + 1))
            }
        }
        return ChatGPTConversationCandidate(
            role: string(element, attribute: kAXRoleAttribute),
            title: string(element, attribute: kAXTitleAttribute),
            descendantDescriptions: descriptions,
            isSelected: bool(element, attribute: kAXSelectedAttribute)
        )
    }

    nonisolated private static func traversedElements(in roots: [AXUIElement]) -> [AXUIElement] {
        var queue = roots.map { QueueEntry(element: $0, depth: 0) }
        var cursor = 0
        var result: [AXUIElement] = []
        while cursor < queue.count && result.count < chatGPTMaxElementCount {
            let entry = queue[cursor]
            cursor += 1
            result.append(entry.element)
            guard entry.depth < chatGPTMaxTraversalDepth else { continue }
            for child in elements(entry.element, attribute: kAXChildrenAttribute) ?? [] {
                queue.append(QueueEntry(element: child, depth: entry.depth + 1))
            }
        }
        return result
    }

    nonisolated private static func string(_ element: AXUIElement, attribute: String) -> String {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return "" }
        return value as? String ?? ""
    }

    nonisolated private static func bool(_ element: AXUIElement, attribute: String) -> Bool {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return false }
        return value as? Bool ?? false
    }

    nonisolated private static func elements(_ element: AXUIElement, attribute: String) -> [AXUIElement]? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? [AXUIElement]
    }

    nonisolated private static func runningChatGPTApplication() -> NSRunningApplication? {
        for bundleIdentifier in chatGPTBundleIdentifiers {
            if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first {
                return app
            }
        }
        return nil
    }

    nonisolated private static func codexWorkTitles() -> Set<String> {
        let base = ProcessInfo.processInfo.environment["CODEX_HOME"]
            .map(URL.init(fileURLWithPath:))
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
        let index = base.appendingPathComponent("session_index.jsonl")
        guard let data = FileManager.default.contents(atPath: index.path),
              let text = String(data: data, encoding: .utf8) else { return [] }
        var titles = Set<String>()
        for line in text.split(separator: "\n") {
            guard let data = String(line).data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let title = object["thread_name"] as? String else { continue }
            titles.insert(title)
        }
        return titles
    }
}
