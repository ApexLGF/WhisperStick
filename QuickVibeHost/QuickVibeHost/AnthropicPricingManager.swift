import Foundation
import SwiftUI
import os

/// Per-million-token pricing for a single Claude model (USD).
struct ModelPricing: Codable, Sendable, Equatable {
    let input: Double
    let output: Double
    let cacheWrite5m: Double
    let cacheWrite1h: Double
    let cacheRead: Double
}

/// Where the catalog currently in effect came from.
enum PricingCatalogSource: String, Codable, Sendable {
    case bundled
    case disk
    case remote
}

/// Snapshot of Anthropic model pricing used by `SessionTranscriptReader.computeCost`.
struct PricingCatalog: Codable, Sendable, Equatable {
    var models: [String: ModelPricing]
    var displayNameToApiId: [String: String]
    var fetchedAt: Date
    var source: PricingCatalogSource

    /// Built-in fallback table. Snapshot as of 2026-07-08 per
    /// https://platform.claude.com/docs/en/about-claude/pricing .
    /// (Opus 4.1/4、Sonnet 4、Haiku 3.5 已从官网表移除,保留旧价供历史 transcript 计费。)
    static func bundledDefaults() -> PricingCatalog {
        let models: [String: ModelPricing] = [
            "claude-fable-5":    .init(input: 10.0, output: 50.0, cacheWrite5m: 12.5,  cacheWrite1h: 20.0, cacheRead: 1.00),
            "claude-opus-4-8":   .init(input: 5.0,  output: 25.0, cacheWrite5m: 6.25,  cacheWrite1h: 10.0, cacheRead: 0.50),
            "claude-opus-4-7":   .init(input: 5.0,  output: 25.0, cacheWrite5m: 6.25,  cacheWrite1h: 10.0, cacheRead: 0.50),
            "claude-opus-4-6":   .init(input: 5.0,  output: 25.0, cacheWrite5m: 6.25,  cacheWrite1h: 10.0, cacheRead: 0.50),
            "claude-opus-4-5":   .init(input: 5.0,  output: 25.0, cacheWrite5m: 6.25,  cacheWrite1h: 10.0, cacheRead: 0.50),
            "claude-opus-4-1":   .init(input: 15.0, output: 75.0, cacheWrite5m: 18.75, cacheWrite1h: 30.0, cacheRead: 1.50),
            "claude-opus-4":     .init(input: 15.0, output: 75.0, cacheWrite5m: 18.75, cacheWrite1h: 30.0, cacheRead: 1.50),
            "claude-sonnet-4-6": .init(input: 3.0,  output: 15.0, cacheWrite5m: 3.75,  cacheWrite1h: 6.0,  cacheRead: 0.30),
            "claude-sonnet-4-5": .init(input: 3.0,  output: 15.0, cacheWrite5m: 3.75,  cacheWrite1h: 6.0,  cacheRead: 0.30),
            "claude-sonnet-4":   .init(input: 3.0,  output: 15.0, cacheWrite5m: 3.75,  cacheWrite1h: 6.0,  cacheRead: 0.30),
            "claude-haiku-4-5":  .init(input: 1.0,  output: 5.0,  cacheWrite5m: 1.25,  cacheWrite1h: 2.0,  cacheRead: 0.10),
            "claude-haiku-3-5":  .init(input: 0.80, output: 4.0,  cacheWrite5m: 1.00,  cacheWrite1h: 1.60, cacheRead: 0.08),
        ]
        let displayNameToApiId: [String: String] = [
            "Claude Fable 5":    "claude-fable-5",
            "Claude Opus 4.8":   "claude-opus-4-8",
            "Claude Opus 4.7":   "claude-opus-4-7",
            "Claude Opus 4.6":   "claude-opus-4-6",
            "Claude Opus 4.5":   "claude-opus-4-5",
            "Claude Opus 4.1":   "claude-opus-4-1",
            "Claude Opus 4":     "claude-opus-4",
            "Claude Sonnet 4.6": "claude-sonnet-4-6",
            "Claude Sonnet 4.5": "claude-sonnet-4-5",
            "Claude Sonnet 4":   "claude-sonnet-4",
            "Claude Haiku 4.5":  "claude-haiku-4-5",
            "Claude Haiku 3.5":  "claude-haiku-3-5",
        ]
        return PricingCatalog(
            models: models,
            displayNameToApiId: displayNameToApiId,
            fetchedAt: Date(timeIntervalSince1970: 0),
            source: .bundled
        )
    }
}

/// Owns the pricing catalog used to compute per-session cost.
///
/// Resolution order at launch: disk cache → bundled defaults.
/// Then `refreshIfStale()` fires in background to pull from the docs page
/// and update `@Published catalog`. All consumers observe `$catalog`.
@MainActor
final class AnthropicPricingManager: ObservableObject {
    @Published private(set) var catalog: PricingCatalog
    @Published private(set) var isFetching: Bool = false
    @Published private(set) var lastFetchError: String?
    @Published private(set) var consecutiveFailureDays: Int = 0

    private let cacheURL: URL
    private let refreshInterval: TimeInterval = 24 * 3600
    private var refreshTask: Task<Void, Never>?
    private var refreshTimer: Timer?

    private static let log = Logger(subsystem: "com.vibe.quickvibehost", category: "pricing")
    private static let primaryURL = URL(string: "https://platform.claude.com/docs/en/about-claude/pricing")!
    private static let fallbackURL = URL(string: "https://claude.com/pricing")!
    nonisolated private static let fetchTimeout: TimeInterval = 10

    init() {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!
        let dir = appSupport.appendingPathComponent("QuickVibeHost", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.cacheURL = dir.appendingPathComponent("pricing-cache.json")

        if let disk = Self.loadFromDisk(url: cacheURL) {
            self.catalog = disk
            Self.log.info("pricing: loaded from disk cache (fetchedAt=\(disk.fetchedAt.description, privacy: .public))")
        } else {
            self.catalog = PricingCatalog.bundledDefaults()
            Self.log.info("pricing: using bundled defaults (no disk cache)")
        }

        // Kick off stale check + 24h timer. Failure doesn't block startup.
        Task { await self.refreshIfStale() }
        scheduleTimer()
    }

    deinit {
        refreshTimer?.invalidate()
    }

    // MARK: - Public API

    /// User-initiated refresh (Settings "立即抓取" button). Ignores the staleness gate.
    func refreshNow() async {
        await performFetch(force: true)
    }

    /// Startup + 24h timer entry — skips fetch if the on-disk catalog is under
    /// `refreshInterval` old.
    private func refreshIfStale() async {
        if catalog.source == .remote || catalog.source == .disk {
            let age = Date().timeIntervalSince(catalog.fetchedAt)
            if age < refreshInterval { return }
        }
        await performFetch(force: false)
    }

    private func scheduleTimer() {
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refreshIfStale() }
        }
    }

    // MARK: - Fetch pipeline

    private func performFetch(force: Bool) async {
        guard !isFetching else { return }
        isFetching = true
        defer { isFetching = false }

        do {
            let fetched = try await fetchRemote()
            catalog = fetched
            lastFetchError = nil
            consecutiveFailureDays = 0
            try? saveToDisk(fetched)
            Self.log.info("pricing: remote fetch OK — \(fetched.models.count) models")
        } catch {
            let msg = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            // Count roughly by day (not ticks): bump when the last success was > refreshInterval ago.
            let age = Date().timeIntervalSince(catalog.fetchedAt)
            if age > refreshInterval { consecutiveFailureDays += 1 }
            var display = msg
            if consecutiveFailureDays >= 7 {
                display += AppL10n.format(" — 已连续 %@ 天失败，请检查 Anthropic 官网页面结构或手动更新", String(consecutiveFailureDays))
            }
            lastFetchError = display
            Self.log.error("pricing: remote fetch failed — \(msg, privacy: .public)")
        }
    }

    private func fetchRemote() async throws -> PricingCatalog {
        var lastError: Error = PricingError.parse("no source tried")

        for source in [Self.primaryURL, Self.fallbackURL] {
            do {
                let html = try await Task.detached { try Self.curlFetch(source) }.value
                let parsed = try parsePricingHTML(html)
                guard parsed.count >= 3 else {
                    lastError = PricingError.parse("only \(parsed.count) models parsed — below minimum")
                    continue
                }
                // Merge: start from current catalog (preserve rates for models we couldn't parse)
                // and overwrite with parsed values.
                var merged = catalog.models
                for (id, rates) in parsed { merged[id] = rates }
                let result = PricingCatalog(
                    models: merged,
                    displayNameToApiId: catalog.displayNameToApiId,
                    fetchedAt: Date(),
                    source: .remote
                )
                return result
            } catch {
                lastError = error
                continue
            }
        }
        throw lastError
    }

    /// 经 /usr/bin/curl 抓取(2026-07-08 起):Anthropic 边缘按 TLS 客户端指纹路由,
    /// URLSession 指纹请求 docs 页会被发到 Webflow 营销站(200 但无定价表 → 恒解析 0),
    /// 系统 curl 拿到真 docs 页(Anthropic 域名边缘按 TLS 客户端指纹路由,URLSession 被拒)。
    nonisolated private static func curlFetch(_ url: URL) throws -> String {
        let marker = "\n__HTTP_STATUS__:"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        p.arguments = ["-s", "-L", "-m", "\(Int(fetchTimeout))",
                       "-A", "Mozilla/5.0 (Macintosh) QuickVibeHost",
                       "-w", "\(marker)%{http_code}", url.absoluteString]
        let outPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = FileHandle.nullDevice
        try p.run()
        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard let raw = String(data: data, encoding: .utf8) else {
            throw PricingError.parse("non-utf8 response")
        }
        guard let markerRange = raw.range(of: marker, options: .backwards) else {
            throw PricingError.httpStatus(-1)   // curl 失败(超时/断网),无 -w 尾巴
        }
        let status = Int(raw[markerRange.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)) ?? -1
        guard 200..<300 ~= status else { throw PricingError.httpStatus(status) }
        return String(raw[..<markerRange.lowerBound])
    }

    // MARK: - HTML parsing

    /// Extract per-model pricing from the docs page HTML.
    ///
    /// The docs page (`platform.claude.com/docs/.../pricing`) renders a table
    /// with display-name rows:
    ///   Model | Base Input | 5m Cache Writes | 1h Cache Writes | Cache Hits | Output
    ///
    /// Strategy: for each display name in the bundled catalog's
    /// `displayNameToApiId` map, locate it in the page and capture the next
    /// 5 `$N.NN` numbers in the column order above. Sanity-check against the
    /// known multiplier relationships and drop anything that looks wrong.
    ///
    /// Direct API-ID matches (e.g., future raw table) are also tried as a
    /// fallback.
    nonisolated func parsePricingHTML(_ html: String) throws -> [String: ModelPricing] {
        let normalized = html.replacingOccurrences(of: "&nbsp;", with: " ")
        var result: [String: ModelPricing] = [:]
        let defaults = PricingCatalog.bundledDefaults()

        // Pass 0: docs 表格行通用发现 —— 不依赖内置名单,新模型(Fable 5 / Opus 4.8 …)
        // 上线即自动入账。api id 由显示名推导:lowercase + 空格/点 → "-"。
        for (displayName, p) in extractTableRows(normalized) {
            let apiId = displayName.lowercased()
                .replacingOccurrences(of: ".", with: "-")
                .replacingOccurrences(of: " ", with: "-")
            result[apiId] = p
        }
        // Pass 1: match display names (docs page style).
        for (displayName, apiId) in defaults.displayNameToApiId where result[apiId] == nil {
            if let p = tryExtractFromNeighborhood(normalized, needle: displayName) {
                result[apiId] = p
            }
        }
        // Pass 2: fallback — raw API IDs (in case a future page format uses them).
        for apiId in defaults.models.keys where result[apiId] == nil {
            if let p = tryExtractFromNeighborhood(normalized, needle: apiId) {
                result[apiId] = p
            }
        }
        return result
    }

    /// docs 页定价表行:`<td>Claude Xxx</td>` 后跟 ≥5 个含 `$N` 的单元格
    /// (列序 input / 5m / 1h / read / output,与 tryExtractFromNeighborhood 一致)。
    /// 同名多行(如 long-context 加价表)只取首行 = 标准价。
    private nonisolated func extractTableRows(_ text: String) -> [(String, ModelPricing)] {
        let pattern = #"<td[^>]*>(Claude [A-Za-z0-9. ]+?)</td>((?:<td[^>]*>[^<]*</td>){4,})"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        var out: [(String, ModelPricing)] = []
        var seen = Set<String>()
        re.enumerateMatches(in: text, range: NSRange(text.startIndex..., in: text)) { match, _, _ in
            guard let m = match,
                  let nameRange = Range(m.range(at: 1), in: text),
                  let cellsRange = Range(m.range(at: 2), in: text) else { return }
            let name = String(text[nameRange]).trimmingCharacters(in: .whitespaces)
            guard !seen.contains(name) else { return }
            let numbers = extractDollarNumbers(from: String(text[cellsRange]))
            guard numbers.count >= 5 else { return }
            let p = ModelPricing(
                input: numbers[0],
                output: numbers[4],
                cacheWrite5m: numbers[1],
                cacheWrite1h: numbers[2],
                cacheRead: numbers[3]
            )
            guard sanityCheck(p) else { return }
            seen.insert(name)
            out.append((name, p))
        }
        return out
    }

    /// Search `text` for `needle`, then from the match endpoint read up to
    /// `N` dollar-prefixed numbers and assemble a `ModelPricing` using the
    /// docs-page column order: input, cacheWrite5m, cacheWrite1h, cacheRead, output.
    /// Returns `nil` on failure or sanity-check miss.
    private nonisolated func tryExtractFromNeighborhood(_ text: String, needle: String) -> ModelPricing? {
        guard let range = text.range(of: needle) else { return nil }
        let tailStart = range.upperBound
        let tailEnd = text.index(tailStart, offsetBy: 2000, limitedBy: text.endIndex) ?? text.endIndex
        let slice = String(text[tailStart..<tailEnd])
        let numbers = extractDollarNumbers(from: slice)
        guard numbers.count >= 5 else { return nil }
        let p = ModelPricing(
            input: numbers[0],
            output: numbers[4],          // docs page column 5 (last)
            cacheWrite5m: numbers[1],    // column 2
            cacheWrite1h: numbers[2],    // column 3
            cacheRead: numbers[3]        // column 4
        )
        return sanityCheck(p) ? p : nil
    }

    private nonisolated func extractDollarNumbers(from text: String) -> [Double] {
        let pattern = #"\$\s*([0-9]+(?:\.[0-9]+)?)"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        var out: [Double] = []
        re.enumerateMatches(in: text, range: range) { match, _, _ in
            guard let m = match, m.numberOfRanges >= 2,
                  let r = Range(m.range(at: 1), in: text),
                  let v = Double(text[r]) else { return }
            out.append(v)
        }
        return out
    }

    private nonisolated func sanityCheck(_ p: ModelPricing) -> Bool {
        guard p.input > 0, p.output > 0 else { return false }
        let tol = 0.10
        let expect5m = p.input * 1.25
        let expectRead = p.input * 0.1
        if abs(p.cacheWrite5m - expect5m) / expect5m > tol { return false }
        if abs(p.cacheRead - expectRead) / max(expectRead, 0.001) > tol { return false }
        return true
    }

    // MARK: - Disk persistence

    private func saveToDisk(_ catalog: PricingCatalog) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(catalog)
        try data.write(to: cacheURL, options: [.atomic])
    }

    private static func loadFromDisk(url: URL) -> PricingCatalog? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            var decoded = try decoder.decode(PricingCatalog.self, from: data)
            // Force source to .disk regardless of what was persisted — the JSON on disk
            // was written when source was .remote, but right now we're reading from disk.
            decoded.source = .disk
            return decoded
        } catch {
            Self.log.error("pricing: failed to decode disk cache: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}

enum PricingError: LocalizedError {
    case httpStatus(Int)
    case parse(String)

    var errorDescription: String? {
        switch self {
        case .httpStatus(let code): return "HTTP \(code)"
        case .parse(let msg):       return AppL10n.format("解析失败：%@", msg)
        }
    }
}
