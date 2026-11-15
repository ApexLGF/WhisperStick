import AppKit
import Combine
import Foundation
import SwiftUI

enum PromptTemplateProvider: String, Codable, CaseIterable, Identifiable, Sendable {
    case any
    case codex
    case claudeCode
    case general
    var id: String { rawValue }
}

enum PromptWorkPhase: String, Codable, CaseIterable, Identifiable, Sendable {
    case starting
    case implementing
    case debugging
    case verifying
    case completing
    var id: String { rawValue }
}

enum PromptContextSignal: String, Codable, CaseIterable, Identifiable, Sendable {
    case dirty
    case error
    case ahead
    var id: String { rawValue }
}

enum PromptTemplateCategory: String, Codable, CaseIterable, Identifiable, Sendable {
    case planning
    case action
    case review
    case debug
    case test
    case finish
    case external
    var id: String { rawValue }
}

struct PromptLocalizedText: Codable, Equatable, Sendable {
    var english: String
    var simplifiedChinese: String
    var traditionalChinese: String

    func value(for language: DeviceDisplayLanguage) -> String {
        switch language {
        case .english: return english
        case .simplifiedChinese: return simplifiedChinese
        case .traditionalChinese: return traditionalChinese
        }
    }
}

struct PromptTemplateDefinition: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var category: PromptTemplateCategory
    var providers: [PromptTemplateProvider]
    var phases: [PromptWorkPhase]
    var signals: [PromptContextSignal]
    var priority: Int
    var title: PromptLocalizedText
    var body: PromptLocalizedText
    var isEnabled: Bool = true
    var isUserDefined: Bool = false

    enum CodingKeys: String, CodingKey {
        case id, category, providers, phases, signals, priority, title, body, isEnabled, isUserDefined
    }

    init(id: String, category: PromptTemplateCategory, providers: [PromptTemplateProvider],
         phases: [PromptWorkPhase], signals: [PromptContextSignal], priority: Int,
         title: PromptLocalizedText, body: PromptLocalizedText,
         isEnabled: Bool = true, isUserDefined: Bool = false) {
        self.id = id; self.category = category; self.providers = providers; self.phases = phases
        self.signals = signals; self.priority = priority; self.title = title; self.body = body
        self.isEnabled = isEnabled; self.isUserDefined = isUserDefined
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        category = try values.decode(PromptTemplateCategory.self, forKey: .category)
        providers = try values.decode([PromptTemplateProvider].self, forKey: .providers)
        phases = try values.decode([PromptWorkPhase].self, forKey: .phases)
        signals = try values.decodeIfPresent([PromptContextSignal].self, forKey: .signals) ?? []
        priority = try values.decodeIfPresent(Int.self, forKey: .priority) ?? 50
        title = try values.decode(PromptLocalizedText.self, forKey: .title)
        body = try values.decode(PromptLocalizedText.self, forKey: .body)
        isEnabled = try values.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        isUserDefined = try values.decodeIfPresent(Bool.self, forKey: .isUserDefined) ?? false
    }

    func supports(_ provider: PromptTemplateProvider) -> Bool {
        // Built-in programming templates historically used `any`. Keep that
        // meaning for Agent contexts, but do not leak them into ordinary apps.
        // User templates explicitly set to `any` remain available everywhere.
        if provider == .general {
            return providers.contains(.general) || (isUserDefined && providers.contains(.any))
        }
        return providers.contains(.any) || providers.contains(provider)
    }

    var isValid: Bool {
        !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !title.english.isEmpty && title.english.utf8.count <= 24 &&
        !title.simplifiedChinese.isEmpty && title.simplifiedChinese.utf8.count <= 24 &&
        !title.traditionalChinese.isEmpty && title.traditionalChinese.utf8.count <= 24 &&
        !body.english.isEmpty && !body.simplifiedChinese.isEmpty && !body.traditionalChinese.isEmpty &&
        body.english.count <= 2048 && body.simplifiedChinese.count <= 2048 &&
        body.traditionalChinese.count <= 2048 && !providers.isEmpty && !phases.isEmpty
    }
}

struct PromptTemplateDocument: Codable, Equatable {
    static let schemaVersion = 1
    var schemaVersion: Int
    var templates: [PromptTemplateDefinition]
}

enum PromptTemplateStoreError: LocalizedError {
    case missingDefaults
    case invalidSchema
    case invalidTemplate(String)
    case duplicateID(String)

    var errorDescription: String? {
        switch self {
        case .missingDefaults: return "Built-in prompt templates are missing."
        case .invalidSchema: return "Unsupported prompt template schema."
        case .invalidTemplate(let id): return "Invalid prompt template: \(id)"
        case .duplicateID(let id): return "Duplicate prompt template ID: \(id)"
        }
    }
}

@MainActor
final class PromptTemplateStore: ObservableObject {
    @Published private(set) var templates: [PromptTemplateDefinition]
    @Published private(set) var lastError: String?

    private let defaults: UserDefaults
    private let fileURL: URL
    private let builtIns: [String: PromptTemplateDefinition]

    init(defaults: UserDefaults = .standard, fileURL: URL? = nil,
         builtInData: Data? = nil) {
        self.defaults = defaults
        self.fileURL = fileURL ?? Self.defaultFileURL()
        let data = builtInData ?? Self.bundledDefaultData()
        let base = (try? Self.decodeAndValidate(data ?? Data()))?.templates ?? []
        builtIns = Dictionary(uniqueKeysWithValues: base.map { ($0.id, $0) })
        if let saved = try? Data(contentsOf: self.fileURL),
           let document = try? Self.decodeAndValidate(saved) {
            templates = Self.merge(base: base, saved: document.templates)
        } else {
            templates = base
        }
        migrateLegacyPromptsIfNeeded()
        persist()
    }

    var enabledTemplates: [PromptTemplateDefinition] { templates.filter(\.isEnabled) }
    var enabledCount: Int { enabledTemplates.count }

    func update(_ template: PromptTemplateDefinition) {
        guard template.isValid else {
            lastError = PromptTemplateStoreError.invalidTemplate(template.id).localizedDescription
            return
        }
        var candidate = template
        candidate.isUserDefined = builtIns[template.id] == nil
        if let index = templates.firstIndex(where: { $0.id == template.id }) {
            templates[index] = candidate
        } else if candidate.isUserDefined {
            templates.append(candidate)
        }
        persist()
    }

    func setEnabled(_ enabled: Bool, id: String) {
        guard let index = templates.firstIndex(where: { $0.id == id }) else { return }
        templates[index].isEnabled = enabled
        persist()
    }

    func makeNewTemplate() -> PromptTemplateDefinition {
        let suffix = UUID().uuidString.lowercased()
        let template = PromptTemplateDefinition(
            id: "user-\(suffix)", category: .action, providers: [.any],
            phases: PromptWorkPhase.allCases, signals: [], priority: 60,
            title: .init(english: "Custom", simplifiedChinese: "\u{81EA}\u{5B9A}\u{4E49}", traditionalChinese: "\u{81EA}\u{8A02}"),
            body: .init(english: "Enter an instruction.", simplifiedChinese: "\u{8BF7}\u{8F93}\u{5165}\u{6307}\u{4EE4}\u{3002}",
                        traditionalChinese: "\u{8ACB}\u{8F38}\u{5165}\u{6307}\u{4EE4}\u{3002}"),
            isEnabled: true, isUserDefined: true
        )
        return template
    }

    func duplicate(id: String) -> PromptTemplateDefinition? {
        guard var copy = templates.first(where: { $0.id == id }) else { return nil }
        copy.id = "user-\(UUID().uuidString.lowercased())"
        copy.isUserDefined = true
        copy.title.english += " Copy"
        copy.title.simplifiedChinese += "\u{526F}\u{672C}"
        copy.title.traditionalChinese += "\u{526F}\u{672C}"
        guard copy.isValid else { return nil }
        templates.append(copy)
        persist()
        return copy
    }

    func delete(id: String) {
        guard builtIns[id] == nil else { return }
        templates.removeAll { $0.id == id }
        persist()
    }

    func restore(id: String) {
        guard let original = builtIns[id], let index = templates.firstIndex(where: { $0.id == id }) else { return }
        templates[index] = original
        persist()
    }

    func isBuiltIn(id: String) -> Bool { builtIns[id] != nil }

    nonisolated static func decodeAndValidate(_ data: Data) throws -> PromptTemplateDocument {
        guard !data.isEmpty else { throw PromptTemplateStoreError.missingDefaults }
        let document = try JSONDecoder().decode(PromptTemplateDocument.self, from: data)
        guard document.schemaVersion == PromptTemplateDocument.schemaVersion else {
            throw PromptTemplateStoreError.invalidSchema
        }
        var ids = Set<String>()
        for template in document.templates {
            guard template.isValid else { throw PromptTemplateStoreError.invalidTemplate(template.id) }
            guard ids.insert(template.id).inserted else { throw PromptTemplateStoreError.duplicateID(template.id) }
        }
        return document
    }

    nonisolated static func merge(base: [PromptTemplateDefinition],
                                  saved: [PromptTemplateDefinition]) -> [PromptTemplateDefinition] {
        let savedByID = Dictionary(uniqueKeysWithValues: saved.map { ($0.id, $0) })
        var result = base.map { original -> PromptTemplateDefinition in
            guard var override = savedByID[original.id], override.isValid else { return original }
            override.isUserDefined = false
            return override
        }
        let baseIDs = Set(base.map(\.id))
        result.append(contentsOf: saved.filter { !baseIDs.contains($0.id) && $0.isValid }.map {
            var user = $0
            user.isUserDefined = true
            return user
        })
        return result
    }

    private func migrateLegacyPromptsIfNeeded() {
        let migrationKey = "promptTemplates.migratedLegacy.v1"
        guard !defaults.bool(forKey: migrationKey) else { return }
        let legacy = defaults.array(forKey: "micpadPrompts") as? [[String: String]] ?? []
        for entry in legacy {
            guard let title = entry["title"]?.trimmingCharacters(in: .whitespacesAndNewlines),
                  let body = entry["body"], !title.isEmpty, !body.isEmpty else { continue }
            let safeTitle = Self.truncatedUTF8(title, maxBytes: 24)
            templates.append(PromptTemplateDefinition(
                id: "legacy-\(UUID().uuidString.lowercased())", category: .action,
                providers: [.any], phases: PromptWorkPhase.allCases, signals: [], priority: 65,
                title: .init(english: safeTitle, simplifiedChinese: safeTitle, traditionalChinese: safeTitle),
                body: .init(english: body, simplifiedChinese: body, traditionalChinese: body),
                isEnabled: true, isUserDefined: true
            ))
        }
        defaults.set(true, forKey: migrationKey)
    }

    private func persist() {
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let document = PromptTemplateDocument(schemaVersion: PromptTemplateDocument.schemaVersion,
                                                  templates: templates)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(document).write(to: fileURL, options: .atomic)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    nonisolated private static func bundledDefaultData() -> Data? {
        if let url = Bundle.main.url(forResource: "BuiltInPromptTemplates", withExtension: "json") {
            return try? Data(contentsOf: url)
        }
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Resources/BuiltInPromptTemplates.json")
        return try? Data(contentsOf: source)
    }

    nonisolated private static func defaultFileURL() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("QuickVibeHost/PromptTemplates/templates.json")
    }

    nonisolated private static func truncatedUTF8(_ text: String, maxBytes: Int) -> String {
        var output = ""
        var count = 0
        for character in text {
            let next = String(character).utf8.count
            if count + next > maxBytes { break }
            output.append(character)
            count += next
        }
        return output
    }
}

struct PromptRecommendationContext: Codable, Equatable, Sendable {
    var provider: PromptTemplateProvider
    var phase: PromptWorkPhase
    var hasUncommittedChanges: Bool
    var hasError: Bool
    var branchAhead: Bool
    var projectName: String
    var taskSummary: String
    var changedAreas: [String]
    var foregroundAppName: String
    var foregroundAppCategory: PromptForegroundAppCategory

    var signals: Set<PromptContextSignal> {
        var value = Set<PromptContextSignal>()
        if hasUncommittedChanges { value.insert(.dirty) }
        if hasError { value.insert(.error) }
        if branchAhead { value.insert(.ahead) }
        return value
    }

    var fingerprint: String {
        [provider.rawValue, phase.rawValue, hasUncommittedChanges ? "1" : "0",
         hasError ? "1" : "0", branchAhead ? "1" : "0", projectName,
         String(taskSummary.prefix(200)), changedAreas.sorted().joined(separator: ","),
         foregroundAppName, foregroundAppCategory.rawValue]
            .joined(separator: "|")
    }
}

enum PromptForegroundAppCategory: String, Codable, Equatable, Sendable {
    case codingHost
    case aiChat
    case notes
    case mail
    case browser
    case general

    var usesRecentAgentSession: Bool { self == .codingHost || self == .aiChat }
}

struct PromptForegroundApplication: Equatable, Sendable {
    var bundleIdentifier: String
    var name: String
    var category: PromptForegroundAppCategory

    var inferredAgentProvider: PromptTemplateProvider? {
        switch bundleIdentifier.lowercased() {
        case "com.openai.chat", "com.openai.codex": return .codex
        case "com.anthropic.claudefordesktop": return .claudeCode
        default: return nil
        }
    }

    @MainActor
    static func capture() -> PromptForegroundApplication {
        let app = NSWorkspace.shared.frontmostApplication
        let bundle = app?.bundleIdentifier ?? ""
        return PromptForegroundApplication(
            bundleIdentifier: bundle,
            name: app?.localizedName ?? "",
            category: classify(bundleIdentifier: bundle)
        )
    }

    static func classify(bundleIdentifier: String) -> PromptForegroundAppCategory {
        let bundle = bundleIdentifier.lowercased()
        if codingHosts.contains(bundle) { return .codingHost }
        if aiChatApps.contains(bundle) { return .aiChat }
        if noteApps.contains(bundle) { return .notes }
        if mailApps.contains(bundle) { return .mail }
        if browserApps.contains(bundle) { return .browser }
        return .general
    }

    private static let codingHosts: Set<String> = [
        "com.openai.codex", "com.apple.terminal", "com.googlecode.iterm2",
        "dev.warp.warp-stable", "com.mitchellh.ghostty", "net.kovidgoyal.kitty",
        "org.alacritty", "com.microsoft.vscode", "com.microsoft.vscodeinsiders",
        "com.todesktop.230313mzl4w4u92", "com.exafunction.windsurf"
    ]
    private static let aiChatApps: Set<String> = [
        "com.openai.chat", "com.anthropic.claudefordesktop"
    ]
    private static let noteApps: Set<String> = [
        "com.apple.notes", "md.obsidian", "net.shinyfrog.bear", "notion.id"
    ]
    private static let mailApps: Set<String> = [
        "com.apple.mail", "com.microsoft.outlook", "com.readdle.smartemail-mac"
    ]
    private static let browserApps: Set<String> = [
        "com.apple.safari", "com.google.chrome", "com.google.chrome.canary",
        "com.microsoft.edgemac", "org.mozilla.firefox", "company.thebrowser.browser"
    ]
}

enum PromptRecommendationEngine {
    typealias LLMRanker = @Sendable (_ context: PromptRecommendationContext,
                                    _ candidates: [PromptTemplateDefinition]) async throws -> [String]

    static func candidates(context: PromptRecommendationContext,
                           templates: [PromptTemplateDefinition]) -> [PromptTemplateDefinition] {
        templates.filter { template in
            template.isEnabled && template.isValid && template.supports(context.provider) &&
            template.signals.allSatisfy { context.signals.contains($0) }
        }.sorted { score($0, context: context) > score($1, context: context) }
    }

    static func localRecommendations(context: PromptRecommendationContext,
                                     templates: [PromptTemplateDefinition], limit: Int = 8) -> [PromptTemplateDefinition] {
        diversified(Array(candidates(context: context, templates: templates).prefix(14)), limit: limit)
    }

    static func recommendations(context: PromptRecommendationContext,
                                templates: [PromptTemplateDefinition], limit: Int = 8,
                                llmRanker: LLMRanker?) async -> [PromptTemplateDefinition] {
        let eligible = Array(candidates(context: context, templates: templates).prefix(14))
        guard let llmRanker, !eligible.isEmpty,
              let ids = try? await llmRanker(context, eligible), !ids.isEmpty else {
            return diversified(eligible, limit: limit)
        }
        let byID = Dictionary(uniqueKeysWithValues: eligible.map { ($0.id, $0) })
        var seen = Set<String>()
        let ranked = ids.compactMap { id -> PromptTemplateDefinition? in
            guard seen.insert(id).inserted else { return nil }
            return byID[id]
        }
        let rankedIDs = Set(ranked.map(\.id))
        return diversified(ranked + eligible.filter { !rankedIDs.contains($0.id) }, limit: limit)
    }

    private static func score(_ template: PromptTemplateDefinition,
                              context: PromptRecommendationContext) -> Int {
        var result = template.priority
        if template.phases.contains(context.phase) { result += 35 } else { result -= 28 }
        result += template.signals.count * 18
        if template.id == "continue_task" && context.phase == .implementing { result += 18 }
        if template.id == "diagnose_error" && context.hasError { result += 30 }
        if template.id == "push_remote" && context.branchAhead { result += 30 }
        if template.category == .planning && context.hasUncommittedChanges { result -= 18 }
        switch context.foregroundAppCategory {
        case .notes:
            if template.id == "organize_notes" { result += 42 }
            if template.id == "continue_writing" { result += 22 }
        case .mail:
            if template.id == "draft_reply" { result += 48 }
            if template.id == "make_professional" { result += 22 }
        case .browser:
            if template.id == "summarize_content" { result += 42 }
            if template.id == "extract_actions" { result += 18 }
        default: break
        }
        return result
    }

    private static func diversified(_ templates: [PromptTemplateDefinition],
                                    limit: Int) -> [PromptTemplateDefinition] {
        var counts: [PromptTemplateCategory: Int] = [:]
        var selected: [PromptTemplateDefinition] = []
        for template in templates where selected.count < limit {
            guard counts[template.category, default: 0] < 2 else { continue }
            selected.append(template)
            counts[template.category, default: 0] += 1
        }
        if selected.count < limit {
            let ids = Set(selected.map(\.id))
            selected.append(contentsOf: templates.filter { !ids.contains($0.id) }.prefix(limit - selected.count))
        }
        return Array(selected.prefix(limit))
    }
}

enum FastLLMPromptRanker {
    private struct Response: Decodable { let recommendations: [Item] }
    private struct Item: Decodable { let id: String; let score: Double? }

    static func rank(configuration: FastLLMConfiguration,
                     context: PromptRecommendationContext,
                     candidates: [PromptTemplateDefinition]) async throws -> [String] {
        struct Candidate: Encodable { let id: String; let category: String; let purpose: String }
        struct Request: Encodable {
            let context: PromptRecommendationContext
            let candidates: [Candidate]
        }
        let request = Request(context: context, candidates: candidates.map {
            Candidate(id: $0.id, category: $0.category.rawValue, purpose: $0.body.english)
        })
        let data = try JSONEncoder().encode(request)
        let user = String(data: data, encoding: .utf8) ?? "{}"
        let result = try await FastLLMClient(configuration: configuration).complete(
            system: """
            Select and rank at most 8 trusted instruction template IDs that are most useful as the user's next action. Use only IDs from candidates. Prefer useful diversity and the current work phase. Return strict JSON only: {"recommendations":[{"id":"...","score":0.0}]}. Do not include prose or invent IDs.
            """,
            user: user, maxTokens: 512, temperature: 0
        )
        var cleaned = result.text
        if cleaned.hasPrefix("```") {
            cleaned = cleaned.replacingOccurrences(of: "```json", with: "")
                .replacingOccurrences(of: "```", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return try JSONDecoder().decode(Response.self, from: Data(cleaned.utf8)).recommendations.map(\.id)
    }
}

enum PromptRecommendationFrameEncoder {
    static func loading(requestID: UInt8) -> [UInt8] { [0x58, requestID, 0] }

    static func ready(requestID: UInt8, titles: [String]) -> [UInt8] {
        let capped = Array(titles.prefix(8))
        var bytes: [UInt8] = [0x58, requestID, 1, UInt8(capped.count)]
        for title in capped {
            var field: [UInt8] = []
            for character in title {
                let next = Array(String(character).utf8)
                if field.count + next.count > 24 { break }
                field.append(contentsOf: next)
            }
            bytes.append(UInt8(field.count))
            bytes.append(contentsOf: field)
        }
        return bytes
    }
}

@MainActor
final class PromptRecommendationController {
    private weak var bleManager: BLEManager?
    private let store: PromptTemplateStore
    private let contextProvider: @MainActor () async -> PromptRecommendationContext
    private var task: Task<Void, Never>?
    private var activeRequestID: UInt8?
    private var activeItems: [PromptTemplateDefinition] = []
    private var cached: (key: String, date: Date, items: [PromptTemplateDefinition])?

    init(bleManager: BLEManager, store: PromptTemplateStore,
         contextProvider: @escaping @MainActor () async -> PromptRecommendationContext) {
        self.bleManager = bleManager
        self.store = store
        self.contextProvider = contextProvider
    }

    func request(_ requestID: UInt8) {
        guard LaboratoryFeatureSettings.promptRecommendationsEnabled else {
            cancel()
            return
        }
        task?.cancel()
        activeRequestID = requestID
        activeItems = []
        bleManager?.sendPromptRecommendationLoading(requestID: requestID)
        task = Task { @MainActor [weak self] in
            await self?.performRequest(requestID)
        }
    }

    private func performRequest(_ requestID: UInt8) async {
        let context = await contextProvider()
        guard !Task.isCancelled, activeRequestID == requestID else { return }
        let templates = store.enabledTemplates
        let cacheKey = context.fingerprint + "|" + templates.map {
            "\($0.id):\($0.priority):\($0.isEnabled):" +
            "\($0.title.english):\($0.title.simplifiedChinese):\($0.title.traditionalChinese):" +
            "\($0.body.english):\($0.body.simplifiedChinese):\($0.body.traditionalChinese)"
        }.joined(separator: ",")
        let items: [PromptTemplateDefinition]
        if let value = cached, value.key == cacheKey,
           Date().timeIntervalSince(value.date) < 120 {
            items = value.items
        } else {
            let configuration = FastLLMConfiguration.load()
            var ranker: PromptRecommendationEngine.LLMRanker?
            if configuration.isConfigured {
                ranker = { context, candidates in
                    try await FastLLMPromptRanker.rank(configuration: configuration,
                                                       context: context, candidates: candidates)
                }
            }
            items = await PromptRecommendationEngine.recommendations(
                context: context, templates: templates, llmRanker: ranker
            )
            cached = (cacheKey, Date(), items)
        }
        guard !Task.isCancelled, activeRequestID == requestID else { return }
        activeItems = items
        let language = DeviceDisplayLanguage.selected
        bleManager?.sendPromptRecommendations(
            requestID: requestID,
            titles: items.map { $0.title.value(for: language) }
        )
    }

    func select(requestID: UInt8, index: UInt8) {
        guard activeRequestID == requestID, Int(index) < activeItems.count else { return }
        let body = activeItems[Int(index)].body.value(for: DeviceDisplayLanguage.selected)
        guard !body.isEmpty else { return }
        InputRouter.routePromptText(body, source: .bleButtonB)
        cancel()
    }

    func cancel() {
        task?.cancel()
        task = nil
        activeRequestID = nil
        activeItems = []
    }
}

enum PromptContextCollector {
    static func collect(session: HookSession?, foreground: PromptForegroundApplication) async -> PromptRecommendationContext {
        let provider: PromptTemplateProvider = session?.id.hasPrefix("codex-") == true ? .codex
            : (session == nil ? (foreground.inferredAgentProvider ?? .general) : .claudeCode)
        let git = await GitPromptState.inspect(cwd: session?.cwd)
        let phase: PromptWorkPhase
        if session?.hasError == true { phase = .debugging }
        else if let session {
            switch session.phase {
            case .processing, .compacting, .waitingForApproval: phase = .implementing
            case .waitingForInput: phase = git.dirty ? .verifying : .starting
            case .idle, .ended: phase = git.dirty ? .completing : .starting
            }
        } else { phase = git.dirty ? .completing : .starting }
        return PromptRecommendationContext(
            provider: provider, phase: phase, hasUncommittedChanges: git.dirty,
            hasError: session?.hasError ?? false, branchAhead: git.ahead,
            projectName: session?.projectName ?? (foreground.name.isEmpty ? git.projectName : foreground.name),
            taskSummary: String((session?.transcriptSnapshot?.lastPromptText ?? "").prefix(500)),
            changedAreas: git.changedAreas,
            foregroundAppName: foreground.name,
            foregroundAppCategory: foreground.category
        )
    }
}

private struct GitPromptState: Sendable {
    var dirty = false
    var ahead = false
    var projectName = ""
    var changedAreas: [String] = []

    static func inspect(cwd: String?) async -> GitPromptState {
        guard let cwd, !cwd.isEmpty else { return GitPromptState() }
        return await Task.detached {
            var state = GitPromptState(projectName: URL(fileURLWithPath: cwd).lastPathComponent)
            let status = runGit(["status", "--porcelain"], cwd: cwd)
            state.dirty = !status.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let paths = status.split(separator: "\n").map { line in
                String(line.dropFirst(min(3, line.count))).trimmingCharacters(in: .whitespaces)
            }
            state.changedAreas = Array(Set(paths.compactMap { $0.split(separator: "/").first.map(String.init) })).sorted()
            let ahead = runGit(["rev-list", "--count", "@{upstream}..HEAD"], cwd: cwd)
            state.ahead = (Int(ahead.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0) > 0
            return state
        }.value
    }

    private static func runGit(_ arguments: [String], cwd: String) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", cwd] + arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { return "" }
        process.waitUntilExit()
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }
}

struct PromptTemplateSettingsSection: View {
    @EnvironmentObject private var store: PromptTemplateStore
    @State private var showingManager = false

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(AppL10n.tr("双击设备 B 键后，根据当前会话动态推荐最多 8 条指令。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(AppL10n.format("已启用 %@/%@", String(store.enabledCount), String(store.templates.count)))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            Button(AppL10n.tr("管理模板")) { showingManager = true }
                .controlSize(.small)
        }
        .sheet(isPresented: $showingManager) {
            PromptTemplateManagerView()
                .environmentObject(store)
        }
    }
}

private struct PromptTemplateManagerView: View {
    @EnvironmentObject private var store: PromptTemplateStore
    @Environment(\.dismiss) private var dismiss
    @State private var editing: PromptTemplateDefinition?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(AppL10n.tr("Prompt 模板管理")).font(.title2.bold())
                    Text(AppL10n.tr("内置模板可停用、编辑和恢复；自定义模板可以删除。"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button { editing = store.makeNewTemplate() } label: {
                    Label(AppL10n.tr("添加模板"), systemImage: "plus")
                }
                Button(AppL10n.tr("完成")) { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(18)
            Divider()
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), spacing: 12)], spacing: 12) {
                    ForEach(store.templates) { template in
                        promptCard(template)
                    }
                }
                .padding(18)
            }
        }
        .frame(minWidth: 720, minHeight: 560)
        .sheet(item: $editing) { template in
            PromptTemplateEditorView(template: template)
                .environmentObject(store)
        }
    }

    private func promptCard(_ template: PromptTemplateDefinition) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text(template.title.value(for: DeviceDisplayLanguage.selected))
                    .font(.headline).lineLimit(1)
                Spacer()
                Toggle("", isOn: Binding(
                    get: { template.isEnabled },
                    set: { store.setEnabled($0, id: template.id) }
                )).labelsHidden().toggleStyle(.switch).controlSize(.small)
            }
            Text(template.body.value(for: DeviceDisplayLanguage.selected))
                .font(.caption).foregroundStyle(.secondary).lineLimit(3)
                .frame(maxWidth: .infinity, minHeight: 48, alignment: .topLeading)
            HStack {
                Text(template.category.rawValue).font(.caption2).foregroundStyle(.tertiary)
                Spacer()
                Button(AppL10n.tr("编辑")) { editing = template }.controlSize(.small)
                if store.isBuiltIn(id: template.id) {
                    Button(AppL10n.tr("恢复")) { store.restore(id: template.id) }.controlSize(.small)
                } else {
                    Button(AppL10n.tr("删除"), role: .destructive) { store.delete(id: template.id) }
                        .controlSize(.small)
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.045)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.1)))
        .opacity(template.isEnabled ? 1 : 0.58)
    }
}

private struct PromptTemplateEditorView: View {
    @EnvironmentObject private var store: PromptTemplateStore
    @Environment(\.dismiss) private var dismiss
    @State var template: PromptTemplateDefinition
    @State private var language: DeviceDisplayLanguage = .simplifiedChinese

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(AppL10n.tr("编辑 Prompt 模板")).font(.title2.bold())
            Picker(AppL10n.tr("语言"), selection: $language) {
                Text("English").tag(DeviceDisplayLanguage.english)
                Text(AppL10n.tr("简体中文")).tag(DeviceDisplayLanguage.simplifiedChinese)
                Text(AppL10n.tr("繁體中文")).tag(DeviceDisplayLanguage.traditionalChinese)
            }.pickerStyle(.segmented)
            Text(AppL10n.tr("设备标题（最多 24 字节）")).font(.caption)
            TextField("", text: localizedTitle).textFieldStyle(.roundedBorder)
            Text(AppL10n.tr("插入内容（不会自动回车）")).font(.caption)
            TextEditor(text: localizedBody)
                .font(.body).frame(minHeight: 180)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
            HStack {
                Picker(AppL10n.tr("分类"), selection: $template.category) {
                    ForEach(PromptTemplateCategory.allCases) { Text($0.rawValue).tag($0) }
                }.frame(width: 180)
                Stepper(AppL10n.format("优先级 %@", String(template.priority)),
                        value: $template.priority, in: 0...100)
                Spacer()
            }
            DisclosureGroup(AppL10n.tr("推荐条件")) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(AppL10n.tr("适用 Agent")).font(.caption).foregroundStyle(.secondary)
                    HStack {
                        templateToggle(AppL10n.tr("全部"), value: .any, selection: $template.providers)
                        templateToggle("Codex", value: .codex, selection: $template.providers)
                        templateToggle("Claude Code", value: .claudeCode, selection: $template.providers)
                        templateToggle(AppL10n.tr("通用 App"), value: .general, selection: $template.providers)
                    }
                    Text(AppL10n.tr("适用阶段")).font(.caption).foregroundStyle(.secondary)
                    HStack {
                        ForEach(PromptWorkPhase.allCases) { phase in
                            templateToggle(phase.rawValue, value: phase, selection: $template.phases)
                        }
                    }
                    Text(AppL10n.tr("必要信号（可不选）")).font(.caption).foregroundStyle(.secondary)
                    HStack {
                        ForEach(PromptContextSignal.allCases) { signal in
                            templateToggle(signal.rawValue, value: signal, selection: $template.signals)
                        }
                    }
                }
                .padding(.top, 6)
            }
            if !template.isValid {
                Text(AppL10n.tr("请填写三种语言；标题 UTF-8 长度不超过 24 字节，正文不超过 2048 字。"))
                    .font(.caption).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button(AppL10n.tr("取消")) { dismiss() }
                Button(AppL10n.tr("保存")) { store.update(template); dismiss() }
                    .disabled(!template.isValid).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20).frame(width: 560)
    }

    private var localizedTitle: Binding<String> {
        Binding(get: {
            switch language {
            case .english: return template.title.english
            case .simplifiedChinese: return template.title.simplifiedChinese
            case .traditionalChinese: return template.title.traditionalChinese
            }
        }, set: { value in
            switch language {
            case .english: template.title.english = value
            case .simplifiedChinese: template.title.simplifiedChinese = value
            case .traditionalChinese: template.title.traditionalChinese = value
            }
        })
    }

    private var localizedBody: Binding<String> {
        Binding(get: {
            switch language {
            case .english: return template.body.english
            case .simplifiedChinese: return template.body.simplifiedChinese
            case .traditionalChinese: return template.body.traditionalChinese
            }
        }, set: { value in
            switch language {
            case .english: template.body.english = value
            case .simplifiedChinese: template.body.simplifiedChinese = value
            case .traditionalChinese: template.body.traditionalChinese = value
            }
        })
    }

    private func templateToggle<T: Hashable>(_ title: String, value: T,
                                              selection: Binding<[T]>) -> some View {
        Toggle(title, isOn: Binding(
            get: { selection.wrappedValue.contains(value) },
            set: { enabled in
                if enabled {
                    if !selection.wrappedValue.contains(value) { selection.wrappedValue.append(value) }
                } else {
                    selection.wrappedValue.removeAll { $0 == value }
                }
            }
        )).toggleStyle(.checkbox).controlSize(.small)
    }
}
