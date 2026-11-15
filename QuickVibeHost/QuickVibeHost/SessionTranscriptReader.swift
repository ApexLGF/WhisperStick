import Foundation
import os

private let logger = Logger(subsystem: "com.vibeeverything.QuickVibeHost", category: "SessionTranscript")

// MARK: - Supporting types

struct SubagentInfo: Sendable, Equatable {
    let agentId: String
    let agentType: String
    let lastToolName: String?
}

struct TranscriptSnapshot: Sendable, Equatable {
    var model: String?
    var contextPromptTokens: Int?
    var contextLimitTokens: Int?
    var gitBranch: String?
    var cliVersion: String?
    var customTitle: String?
    var activeSubagent: SubagentInfo?
    var serviceTier: String?
    var entrypoint: String?
    var lastPromptText: String?
    var firstTimestamp: Date?
    var lastTimestamp: Date?

    /// 文件 mtime,REQ-014 30min 非活跃判定用(比 lastTimestamp 更省 + 末行缺 timestamp 时仍可靠)。
    var transcriptMtime: Date?

    /// Counts observed in the tail window. `Step 4a` replaces these with
    /// size-capped full-scan totals.
    var turnCount: Int = 0
    var compactCount: Int = 0
    var deniedToolCount: Int = 0

    /// Filled by `Step 4a`; `nil` until then.
    var totalCostUSD: Double?
    var costIsPartial: Bool = false

    /// Cumulative token totals over the cost-scan window (requestId-dedup'd).
    /// `nil` until `Step 4a` populates them.
    var totalInputTokens: Int?
    var totalCacheCreationTokens: Int?
    var totalCacheReadTokens: Int?
    var totalOutputTokens: Int?

    /// `cache_read / (input + cache_creation + cache_read)` — `nil` if denominator is 0.
    var cacheHitRatio: Double? {
        guard let input = totalInputTokens,
              let cc = totalCacheCreationTokens,
              let cr = totalCacheReadTokens else { return nil }
        let denom = input + cc + cr
        guard denom > 0 else { return nil }
        return Double(cr) / Double(denom)
    }
}

/// Static context-window data for known Claude models.
/// Pricing lives in `PricingCatalog` (auto-synced from Anthropic docs).
enum ClaudeModelCatalog {
    static let contextLimit: [String: Int] = [
        "claude-opus-4-6": 200_000,
        "claude-sonnet-4-6": 200_000,
        "claude-haiku-4-5": 200_000,
    ]

    /// Best-effort context-limit lookup — falls back to 200k for the claude-4.x family.
    static func contextLimit(for model: String?) -> Int? {
        guard let model, !model.isEmpty else { return nil }
        if let exact = contextLimit[model] { return exact }
        // Strip common suffixes before retrying
        let stripped = normalizeModelFamily(model)
        if let exact = contextLimit[stripped] { return exact }
        if model.hasPrefix("claude-"), model.contains("-4-") {
            return 200_000
        }
        return nil
    }

    private static func normalizeModelFamily(_ raw: String) -> String {
        var s = raw.replacingOccurrences(
            of: #"-\d{8}(-\d{4})?$"#, with: "", options: .regularExpression)
        if s.hasSuffix("-latest") { s = String(s.dropLast("-latest".count)) }
        return s
    }
}

/// Normalize an arbitrary `message.model` string into a `PricingCatalog.models` key.
///
/// Handles common shapes Claude Code emits:
///   - exact API IDs (`claude-opus-4-6`)
///   - date-pinned snapshots (`claude-haiku-4-5-20251001`)
///   - `-latest` alias
///   - human display names (via `displayNameToApiId`)
///
/// Returns `nil` if no mapping exists — caller should skip cost for that line
/// and (once per app lifetime) warn.
func normalizeModelId(_ raw: String, pricing: PricingCatalog) -> String? {
    // 1. Exact hit
    if pricing.models[raw] != nil { return raw }
    // 2. Strip trailing "-YYYYMMDD" or "-YYYYMMDD-HHMM"
    let dateStripped = raw.replacingOccurrences(
        of: #"-\d{8}(-\d{4})?$"#, with: "", options: .regularExpression)
    if dateStripped != raw, pricing.models[dateStripped] != nil { return dateStripped }
    // 3. Strip "-latest"
    if raw.hasSuffix("-latest") {
        let trimmed = String(raw.dropLast("-latest".count))
        if pricing.models[trimmed] != nil { return trimmed }
    }
    // 4. Display-name lookup
    if let api = pricing.displayNameToApiId[raw] { return api }
    return nil
}

// MARK: - Reader

/// Reads a Claude Code transcript JSONL file and extracts a per-session snapshot
/// (model, context usage, active subagent, git branch, turn count, ...).
///
/// Used by `ClaudeHookSessionStore.handleEvent` on every hook event — each call is
/// `mtime+size` cache-gated so a steady-state session only triggers one tail read
/// per transcript write.
actor SessionTranscriptReader {
    private struct CacheEntry {
        let mtime: Date
        let size: UInt64
        let snapshot: TranscriptSnapshot
    }

    /// Cost scans the whole file (size-capped), so it's expensive — throttle to
    /// avoid recomputing on every hook tick. Keyed by resolved URL.
    private struct CostCacheEntry {
        let size: UInt64
        let aggregate: CostAggregate
        let computedAt: Date
    }

    /// Everything `scanCost` returns — cost plus token totals for the UI.
    struct CostAggregate: Sendable {
        let cost: Double
        let isPartial: Bool
        let inputTokens: Int
        /// Legacy lump sum: `cacheCreation5m + cacheCreation1h`.
        let cacheCreationTokens: Int
        let cacheCreation5mTokens: Int
        let cacheCreation1hTokens: Int
        let cacheReadTokens: Int
        let outputTokens: Int
        /// Model IDs encountered in the scan that weren't present in the pricing catalog.
        /// The actor dedupes against its lifetime set before warning.
        let unknownModels: [String]
    }

    private var cache: [URL: CacheEntry] = [:]
    private var costCache: [URL: CostCacheEntry] = [:]
    /// Unknown model IDs already warned about this app lifetime (dedup per actor).
    private var warnedUnknownModels: Set<String> = []

    /// One-shot head-scan outcome for a transcript's first-line timestamp.
    /// Explicit enum (not `Date?`) so a "scanned but no timestamp" result can
    /// be cached as `.missing` — assigning `nil` to a `Dictionary<K, Date?>`
    /// subscript *removes* the key, which would make us re-scan every tick.
    private enum FirstTimestampState {
        case missing
        case resolved(Date)
    }

    private struct FirstTimestampEntry {
        let state: FirstTimestampState
        /// File size at time of scan. If a later refresh sees the file shrink
        /// below this, the transcript was truncated/rebuilt — evict.
        let capturedSize: UInt64
    }

    private var firstTimestampCache: [URL: FirstTimestampEntry] = [:]

    /// Hard cap on cost-scan bytes. Real-world transcripts rarely exceed this;
    /// when they do, `costIsPartial` signals that earlier turns were skipped.
    static let costMaxScanBytes: UInt64 = 5 * 1024 * 1024

    /// Re-compute cost at most once per this interval per transcript URL.
    static let costThrottleSeconds: TimeInterval = 5

    /// Refresh and return the snapshot for a transcript path.
    /// - Parameters:
    ///   - transcriptPath: absolute path to the `*.jsonl` file, as delivered
    ///     by the hook payload (`transcript_path`) or derived via `TranscriptPath.derive`.
    ///   - pricing: current catalog (passed in by the store so we don't hardcode).
    /// - Returns: snapshot, or `nil` if the file is missing / unreadable / empty.
    func refresh(transcriptPath: String?, pricing: PricingCatalog) -> TranscriptSnapshot? {
        guard let transcriptPath, !transcriptPath.isEmpty else { return nil }
        let url = URL(fileURLWithPath: transcriptPath).resolvingSymlinksInPath()

        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) else {
            return nil
        }
        let mtime = (attrs[.modificationDate] as? Date) ?? Date(timeIntervalSince1970: 0)
        let size = (attrs[.size] as? UInt64) ?? 0

        if let cached = cache[url], cached.mtime == mtime, cached.size == size {
            return cached.snapshot
        }

        let chunk: TranscriptTailChunk?
        do {
            chunk = try ClaudeTranscriptTailReader.readTail(at: url)
        } catch {
            logger.debug("readTail failed for \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
        guard let chunk else { return nil }

        var snapshot = Self.extractSnapshot(lines: chunk.lines)
        snapshot.transcriptMtime = mtime

        // tail 窗口里算出的 firstTimestamp 只是 "末 64KB 里最早那行" 的时间；
        // 对大 transcript 会严重截短。用一次性 head-scan 的真值覆盖。
        if let trueFirst = resolveFirstTimestamp(url: url, fileSize: size) {
            snapshot.firstTimestamp = trueFirst
        }

        if let agg = computeCostIfNeeded(url: url, fileSize: size, pricing: pricing) {
            snapshot.totalCostUSD = agg.cost
            snapshot.costIsPartial = agg.isPartial
            snapshot.totalInputTokens = agg.inputTokens
            snapshot.totalCacheCreationTokens = agg.cacheCreationTokens
            snapshot.totalCacheReadTokens = agg.cacheReadTokens
            snapshot.totalOutputTokens = agg.outputTokens
        }

        cache[url] = CacheEntry(mtime: chunk.mtime, size: chunk.fileSize, snapshot: snapshot)
        return snapshot
    }

    /// Resolve the first-line timestamp for a transcript, reading the file head
    /// at most once per file lifetime. Returns `nil` if the head has been scanned
    /// but no timestamp was present (cached as `.missing`) or if the read itself
    /// failed (not cached, will retry next refresh).
    ///
    /// If the on-disk file size has shrunk below the captured size, the
    /// transcript was truncated/rebuilt — evict the stale entry and re-scan.
    private func resolveFirstTimestamp(url: URL, fileSize: UInt64) -> Date? {
        if let entry = firstTimestampCache[url], fileSize < entry.capturedSize {
            firstTimestampCache.removeValue(forKey: url)
        }
        if let entry = firstTimestampCache[url] {
            switch entry.state {
            case .resolved(let d): return d
            case .missing:         return nil
            }
        }

        let chunk: TranscriptTailChunk?
        do {
            chunk = try ClaudeTranscriptTailReader.readHead(at: url)
        } catch {
            logger.debug("readHead failed for \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
        guard let chunk else { return nil }

        let ts = Self.extractFirstTimestamp(lines: chunk.lines)
        let state: FirstTimestampState = ts.map { .resolved($0) } ?? .missing
        firstTimestampCache[url] = FirstTimestampEntry(state: state, capturedSize: fileSize)
        return ts
    }

    /// Pure extraction of the first timestamp from a sequence of JSONL lines.
    /// Returns the timestamp from the earliest line (by file order) that
    /// contains a parseable `timestamp` field; `nil` if none do.
    nonisolated static func extractFirstTimestamp(lines: [String]) -> Date? {
        let isoFractional = ISO8601DateFormatter()
        isoFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoPlain = ISO8601DateFormatter()

        for line in lines {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tsStr = obj["timestamp"] as? String else { continue }
            if let ts = isoFractional.date(from: tsStr) ?? isoPlain.date(from: tsStr) {
                return ts
            }
        }
        return nil
    }

    /// Returns the cost aggregate (possibly from cache within the throttle window)
    /// or `nil` if the scan failed. Recomputes on cache miss by re-opening the
    /// file and reading the last `costMaxScanBytes`.
    private func computeCostIfNeeded(url: URL, fileSize: UInt64, pricing: PricingCatalog) -> CostAggregate? {
        let now = Date()
        if let prev = costCache[url],
           prev.size == fileSize,
           now.timeIntervalSince(prev.computedAt) < Self.costThrottleSeconds {
            return prev.aggregate
        }
        guard let agg = try? Self.scanCost(at: url, fileSize: fileSize, pricing: pricing) else { return nil }
        costCache[url] = CostCacheEntry(size: fileSize, aggregate: agg, computedAt: now)
        warnAboutUnknownModels(agg.unknownModels)
        return agg
    }

    /// Log each never-before-seen unknown model ID exactly once per app lifetime.
    private func warnAboutUnknownModels(_ ids: [String]) {
        for id in ids where !warnedUnknownModels.contains(id) {
            warnedUnknownModels.insert(id)
            logger.warning("pricing: unknown model '\(id, privacy: .public)' — cost will be skipped for this model until pricing catalog is updated")
        }
    }

    /// Drop a cached entry — call when a session ends so the URL key doesn't linger.
    func invalidate(transcriptPath: String?) {
        guard let transcriptPath, !transcriptPath.isEmpty else { return }
        let url = URL(fileURLWithPath: transcriptPath).resolvingSymlinksInPath()
        cache.removeValue(forKey: url)
        costCache.removeValue(forKey: url)
        firstTimestampCache.removeValue(forKey: url)
    }

    /// Drop every entry — used by `ClaudeHookSessionStore.pruneDeadSessions` so
    /// the cache doesn't outlive the sessions it describes.
    func invalidateAll() {
        cache.removeAll(keepingCapacity: true)
        costCache.removeAll(keepingCapacity: true)
        firstTimestampCache.removeAll(keepingCapacity: true)
    }

    /// Clear just the cost-scan throttle cache — called when the pricing catalog
    /// changes so the next `refresh` re-runs cost with the new rates instead of
    /// being blocked by the 5s throttle window.
    func invalidateCostCache() {
        costCache.removeAll(keepingCapacity: true)
    }

    // MARK: - Pure extraction (nonisolated for testability)

    /// Parse a batch of transcript JSONL lines into a snapshot.
    ///
    /// Malformed lines are silently skipped (handles the `try?` tolerance
    /// that `ClaudeTranscriptTailReader` already provides via `isFullFile=false`
    /// dropping the first partial line).
    nonisolated static func extractSnapshot(lines: [String]) -> TranscriptSnapshot {
        var snapshot = TranscriptSnapshot()

        let isoFractional = ISO8601DateFormatter()
        isoFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoPlain = ISO8601DateFormatter()

        var seenPromptIds: Set<String> = []
        var latestSidechain: (agentId: String, agentType: String, lastTool: String?, ts: Date?)?
        var latestMainAssistantTs: Date?

        for line in lines {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }

            let type = obj["type"] as? String ?? ""

            // Timestamps
            var ts: Date?
            if let tsStr = obj["timestamp"] as? String {
                ts = isoFractional.date(from: tsStr) ?? isoPlain.date(from: tsStr)
                if let ts {
                    if snapshot.firstTimestamp == nil || ts < snapshot.firstTimestamp! {
                        snapshot.firstTimestamp = ts
                    }
                    if snapshot.lastTimestamp == nil || ts > snapshot.lastTimestamp! {
                        snapshot.lastTimestamp = ts
                    }
                }
            }

            // Top-level "last-write-wins" fields
            // Claude Code CLI 在 cwd 非 git 仓库或 detached HEAD 时会写死字面
            // 量 "HEAD"（等同 `git rev-parse --abbrev-ref HEAD` 的 fallback 输出）。
            // 该值无信息量，过滤掉以免 UI 显示误导性的分支标签。
            if let branch = obj["gitBranch"] as? String,
               !branch.isEmpty, branch != "HEAD" {
                snapshot.gitBranch = branch
            }
            if let version = obj["version"] as? String, !version.isEmpty {
                snapshot.cliVersion = version
            }
            if let entry = obj["entrypoint"] as? String, !entry.isEmpty, snapshot.entrypoint == nil {
                snapshot.entrypoint = entry
            }

            if let pid = obj["promptId"] as? String, !pid.isEmpty {
                seenPromptIds.insert(pid)
            }

            if obj["isCompactSummary"] as? Bool == true {
                snapshot.compactCount += 1
            }

            switch type {
            case "assistant":
                let isSidechain = obj["isSidechain"] as? Bool == true
                if let message = obj["message"] as? [String: Any] {
                    if let model = message["model"] as? String, !model.isEmpty {
                        snapshot.model = model
                        snapshot.contextLimitTokens = ClaudeModelCatalog.contextLimit(for: model)
                    }
                    if let usage = message["usage"] as? [String: Any] {
                        let input = usage["input_tokens"] as? Int ?? 0
                        let cacheCreation = usage["cache_creation_input_tokens"] as? Int ?? 0
                        let cacheRead = usage["cache_read_input_tokens"] as? Int ?? 0
                        snapshot.contextPromptTokens = input + cacheCreation + cacheRead
                        if let tier = usage["service_tier"] as? String, !tier.isEmpty {
                            snapshot.serviceTier = tier
                        }
                    }
                }
                if isSidechain {
                    let agentId = (obj["agentId"] as? String) ?? ""
                    let agentType = (obj["agentType"] as? String)
                        ?? (obj["agent_type"] as? String)
                        ?? "agent"
                    var toolName: String?
                    if let msg = obj["message"] as? [String: Any],
                       let blocks = msg["content"] as? [[String: Any]] {
                        for block in blocks where (block["type"] as? String) == "tool_use" {
                            toolName = block["name"] as? String
                            break
                        }
                    }
                    if let ts {
                        if latestSidechain == nil || ts >= (latestSidechain?.ts ?? .distantPast) {
                            latestSidechain = (agentId, agentType, toolName, ts)
                        }
                    } else if latestSidechain == nil {
                        latestSidechain = (agentId, agentType, toolName, nil)
                    }
                } else if let ts {
                    if latestMainAssistantTs == nil || ts > latestMainAssistantTs! {
                        latestMainAssistantTs = ts
                    }
                }

            case "user":
                if let message = obj["message"] as? [String: Any],
                   let content = message["content"] as? [[String: Any]] {
                    for block in content where (block["type"] as? String) == "tool_result" {
                        if block["is_error"] as? Bool == true {
                            snapshot.deniedToolCount += 1
                        }
                    }
                }

            case "custom-title":
                if let title = obj["title"] as? String, !title.isEmpty {
                    snapshot.customTitle = title
                }

            case "last-prompt":
                if let prompt = obj["prompt"] as? String, !prompt.isEmpty {
                    snapshot.lastPromptText = String(prompt.prefix(500))
                }

            default:
                break
            }
        }

        snapshot.turnCount = seenPromptIds.count

        // Subagent is considered "active" if the most recent sidechain line is
        // newer than the most recent main-chain assistant line (control hasn't
        // returned yet). Hook payload `agentId`/`agentType` on HookSession is
        // the authoritative realtime signal; this is only a tail-based hint.
        if let sub = latestSidechain {
            let stillInSubagent: Bool
            if let subTs = sub.ts, let mainTs = latestMainAssistantTs {
                stillInSubagent = subTs >= mainTs
            } else {
                stillInSubagent = latestMainAssistantTs == nil
            }
            if stillInSubagent {
                snapshot.activeSubagent = SubagentInfo(
                    agentId: sub.agentId,
                    agentType: sub.agentType,
                    lastToolName: sub.lastTool
                )
            }
        }

        return snapshot
    }

    nonisolated static func latestPromptText(lines: [String]) -> String? {
        var latest: String?
        for line in lines {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }

            let type = obj["type"] as? String ?? ""
            switch type {
            case "last-prompt":
                if let prompt = obj["prompt"] as? String, !prompt.isEmpty {
                    latest = prompt
                }
            case "response_item":
                guard let payload = obj["payload"] as? [String: Any],
                      (payload["role"] as? String) == "user",
                      let content = payload["content"] as? [[String: Any]]
                else { continue }
                let text = content
                    .filter { ($0["type"] as? String) == "input_text" }
                    .compactMap { $0["text"] as? String }
                    .joined()
                if !text.isEmpty { latest = text }
            case "event_msg":
                guard let payload = obj["payload"] as? [String: Any],
                      (payload["type"] as? String) == "user_message",
                      let message = payload["message"] as? String,
                      !message.isEmpty
                else { continue }
                latest = message
            default:
                break
            }
        }
        return latest
    }

    // MARK: - Cost scanning

    /// Read the tail of the file (up to `costMaxScanBytes`) and sum per-request
    /// cost from `assistant` lines. Deduplicates by `requestId` (retries share
    /// one id). When the file is larger than the cap, earlier turns are skipped
    /// and `isPartial` is `true`.
    nonisolated static func scanCost(at url: URL, fileSize: UInt64, pricing: PricingCatalog) throws -> CostAggregate {
        let chunk = try ClaudeTranscriptTailReader.readTail(at: url, maxBytes: costMaxScanBytes)
        let isPartial = fileSize > costMaxScanBytes
        guard let chunk else {
            return CostAggregate(
                cost: 0, isPartial: isPartial,
                inputTokens: 0,
                cacheCreationTokens: 0,
                cacheCreation5mTokens: 0,
                cacheCreation1hTokens: 0,
                cacheReadTokens: 0,
                outputTokens: 0,
                unknownModels: []
            )
        }
        let agg = computeCost(lines: chunk.lines, pricing: pricing)
        return CostAggregate(
            cost: agg.cost, isPartial: isPartial,
            inputTokens: agg.inputTokens,
            cacheCreationTokens: agg.cacheCreationTokens,
            cacheCreation5mTokens: agg.cacheCreation5mTokens,
            cacheCreation1hTokens: agg.cacheCreation1hTokens,
            cacheReadTokens: agg.cacheReadTokens,
            outputTokens: agg.outputTokens,
            unknownModels: agg.unknownModels
        )
    }

    /// Pure function — sum USD cost and cumulative tokens over `assistant`
    /// JSONL lines.
    ///
    /// Formula (per Anthropic docs, 2026-04 revision):
    ///   cost = input_tokens                   * pricing.input
    ///        + cache_creation_5m_tokens       * pricing.cacheWrite5m
    ///        + cache_creation_1h_tokens       * pricing.cacheWrite1h
    ///        + cache_read_tokens              * pricing.cacheRead
    ///        + output_tokens                  * pricing.output
    ///
    /// If the transcript omits the `usage.cache_creation` sub-dict (older
    /// sessions), the entire `cache_creation_input_tokens` lump is billed at
    /// the 5m rate — Claude Code's default.
    ///
    /// Unknown models contribute 0 to cost but their tokens still accumulate
    /// and their IDs are returned in `unknownModels`. `requestId` dedupes
    /// retries — first occurrence wins.
    nonisolated static func computeCost(lines: [String], pricing: PricingCatalog) -> CostAggregate {
        var seenRequestIds: Set<String> = []
        var totalCost: Double = 0
        var totalInput = 0
        var totalCC5m = 0
        var totalCC1h = 0
        var totalCacheRead = 0
        var totalOutput = 0
        var unknownModels: Set<String> = []

        for line in lines {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  (obj["type"] as? String) == "assistant",
                  let message = obj["message"] as? [String: Any],
                  let usage = message["usage"] as? [String: Any]
            else { continue }

            if let rid = obj["requestId"] as? String, !rid.isEmpty {
                if seenRequestIds.contains(rid) { continue }
                seenRequestIds.insert(rid)
            }

            let input = (usage["input_tokens"] as? Int) ?? 0
            let cacheReadTok = (usage["cache_read_input_tokens"] as? Int) ?? 0
            let output = (usage["output_tokens"] as? Int) ?? 0

            // 5m / 1h split: prefer sub-dict if present, else put all in 5m bucket.
            var cc5m = 0
            var cc1h = 0
            if let ccDict = usage["cache_creation"] as? [String: Any] {
                cc5m = (ccDict["ephemeral_5m_input_tokens"] as? Int) ?? 0
                cc1h = (ccDict["ephemeral_1h_input_tokens"] as? Int) ?? 0
            }
            if cc5m == 0 && cc1h == 0 {
                // Fallback: treat the whole lump as 5m (Claude Code default TTL).
                cc5m = (usage["cache_creation_input_tokens"] as? Int) ?? 0
            }

            totalInput += input
            totalCC5m += cc5m
            totalCC1h += cc1h
            totalCacheRead += cacheReadTok
            totalOutput += output

            let rawModel = (message["model"] as? String) ?? ""
            if rawModel.isEmpty || rawModel == "<synthetic>" { continue }

            guard let apiId = normalizeModelId(rawModel, pricing: pricing),
                  let rates = pricing.models[apiId]
            else {
                unknownModels.insert(rawModel)
                continue
            }

            let perTok = 1_000_000.0
            totalCost += Double(input)        * rates.input        / perTok
            totalCost += Double(cc5m)         * rates.cacheWrite5m / perTok
            totalCost += Double(cc1h)         * rates.cacheWrite1h / perTok
            totalCost += Double(cacheReadTok) * rates.cacheRead    / perTok
            totalCost += Double(output)       * rates.output       / perTok
        }

        return CostAggregate(
            cost: totalCost, isPartial: false,
            inputTokens: totalInput,
            cacheCreationTokens: totalCC5m + totalCC1h,
            cacheCreation5mTokens: totalCC5m,
            cacheCreation1hTokens: totalCC1h,
            cacheReadTokens: totalCacheRead,
            outputTokens: totalOutput,
            unknownModels: Array(unknownModels).sorted()
        )
    }
}
