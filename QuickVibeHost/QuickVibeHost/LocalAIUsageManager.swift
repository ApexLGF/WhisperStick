import Foundation

// Local aggregation concepts are adapted from TokenRemain (Apache-2.0).
// This implementation was rewritten for QuickVibeHost; see ThirdParty/TOKENREMAIN_NOTICE.

/// A 30-day, local-only usage snapshot produced from Claude/Codex transcript logs.
/// Costs are public API-price estimates, never subscription billing totals.
struct LocalAIUsageSnapshot: Codable, Equatable {
    struct Agent: Codable, Equatable, Identifiable {
        let id: String
        let tokens: Int64
        let estimatedCost: Double
        let unpricedModels: [String]
        let inputTokens: Int64
        let outputTokens: Int64
        let cacheCreationTokens: Int64
        let cacheReadTokens: Int64

        init(
            id: String,
            tokens: Int64,
            estimatedCost: Double,
            unpricedModels: [String],
            inputTokens: Int64 = 0,
            outputTokens: Int64 = 0,
            cacheCreationTokens: Int64 = 0,
            cacheReadTokens: Int64 = 0
        ) {
            self.id = id
            self.tokens = tokens
            self.estimatedCost = estimatedCost
            self.unpricedModels = unpricedModels
            self.inputTokens = inputTokens
            self.outputTokens = outputTokens
            self.cacheCreationTokens = cacheCreationTokens
            self.cacheReadTokens = cacheReadTokens
        }
    }

    struct AgentTotals: Equatable {
        var inputTokens: Int64 = 0
        var outputTokens: Int64 = 0
        var cacheCreationTokens: Int64 = 0
        var cacheReadTokens: Int64 = 0
        var estimatedCost: Double? = 0
        var unpricedModels: [String] = []

        var totalTokens: Int64 {
            inputTokens + outputTokens + cacheCreationTokens + cacheReadTokens
        }
    }

    struct Day: Codable, Equatable, Identifiable {
        let date: Date
        let agents: [Agent]

        var id: Date { date }
        var totalTokens: Int64 { agents.reduce(0) { $0 + $1.tokens } }
        var estimatedCost: Double? {
            guard agents.allSatisfy({ $0.unpricedModels.isEmpty }) else { return nil }
            return agents.reduce(0) { $0 + $1.estimatedCost }
        }
    }

    let days: [Day]
    let capturedAt: Date

    func day(at date: Date, calendar: Calendar = .current) -> Day? {
        let target = calendar.startOfDay(for: date)
        return days.first { calendar.isDate($0.date, inSameDayAs: target) }
    }

    func total(
        endingAt date: Date = .now,
        days count: Int,
        calendar: Calendar = .current
    ) -> (tokens: Int64, cost: Double?) {
        let end = calendar.startOfDay(for: date)
        let start = calendar.date(byAdding: .day, value: -(max(1, count) - 1), to: end) ?? end
        let selected = days.filter { $0.date >= start && $0.date <= end }
        let tokens = selected.reduce(Int64(0)) { $0 + $1.totalTokens }
        let costs = selected.map(\.estimatedCost)
        let cost = costs.allSatisfy { $0 != nil } ? costs.compactMap { $0 }.reduce(0, +) : nil
        return (tokens, cost)
    }

    func tokenTrend(
        endingAt date: Date = .now,
        days count: Int = 30,
        calendar: Calendar = .current
    ) -> [Double] {
        let count = max(2, count)
        let end = calendar.startOfDay(for: date)
        return (0..<count).map { offset in
            guard let day = calendar.date(byAdding: .day, value: offset - count + 1, to: end) else {
                return 0
            }
            return Double(self.day(at: day, calendar: calendar)?.totalTokens ?? 0)
        }
    }

    func totals(
        agentID: String,
        endingAt date: Date = .now,
        days count: Int,
        calendar: Calendar = .current
    ) -> AgentTotals {
        let id = agentID.lowercased()
        let end = calendar.startOfDay(for: date)
        let start = calendar.date(byAdding: .day, value: -(max(1, count) - 1), to: end) ?? end
        let agents = days
            .filter { $0.date >= start && $0.date <= end }
            .flatMap(\.agents)
            .filter { $0.id.lowercased() == id }
        let missing = Array(Set(agents.flatMap(\.unpricedModels))).sorted()
        return AgentTotals(
            inputTokens: agents.reduce(0) { $0 + $1.inputTokens },
            outputTokens: agents.reduce(0) { $0 + $1.outputTokens },
            cacheCreationTokens: agents.reduce(0) { $0 + $1.cacheCreationTokens },
            cacheReadTokens: agents.reduce(0) { $0 + $1.cacheReadTokens },
            estimatedCost: missing.isEmpty ? agents.reduce(0) { $0 + $1.estimatedCost } : nil,
            unpricedModels: missing
        )
    }

    func limited(toAgentIDs allowedIDs: Set<String>) -> LocalAIUsageSnapshot {
        let normalized = Set(allowedIDs.map { $0.lowercased() })
        return LocalAIUsageSnapshot(
            days: days.map { day in
                Day(
                    date: day.date,
                    agents: day.agents.filter { normalized.contains($0.id.lowercased()) }
                )
            },
            capturedAt: capturedAt
        )
    }
}

struct LocalAIUsageService {
    enum ServiceError: LocalizedError {
        case helperMissing
        case helperTimedOut
        case helperFailed(String)
        case invalidOutput

        var errorDescription: String? {
            switch self {
            case .helperMissing:
                return AppL10n.tr("本地用量组件缺失，请重新安装最新版 QuickVibeHost。")
            case .helperTimedOut:
                return AppL10n.tr("读取本地 AI 用量超时，请稍后重试。")
            case .helperFailed(let detail):
                return AppL10n.format("读取本地 AI 用量失败：%@", detail)
            case .invalidOutput:
                return AppL10n.tr("本地 AI 用量数据格式无法识别。")
            }
        }
    }

    private struct Response: Decodable {
        let daily: [DayRow]
    }

    private struct DayRow: Decodable {
        let period: String
        let agents: [AgentRow]?
    }

    private struct AgentRow: Decodable {
        let agent: String
        let totalTokens: Int64
        let totalCost: Double
        let modelsUsed: [String]?
        let modelBreakdowns: [ModelRow]?
    }

    private struct ModelRow: Decodable {
        let modelName: String
        let cost: Double
        let inputTokens: Int64
        let outputTokens: Int64
        let cacheCreationTokens: Int64
        let cacheReadTokens: Int64

        var totalTokens: Int64 {
            inputTokens + outputTokens + cacheCreationTokens + cacheReadTokens
        }
    }

    private struct SourceResponse: Decodable {
        let daily: [SourceDayRow]
    }

    private struct SourceDayRow: Decodable {
        let date: String
        let totalTokens: Int64
        let totalCost: Double?
        let costUSD: Double?
        let modelsUsed: [String]?
        let modelBreakdowns: [ModelRow]?
        let models: [String: SourceModelRow]?
    }

    private struct SourceModelRow: Decodable {
        let inputTokens: Int64
        let outputTokens: Int64
        let cacheCreationTokens: Int64
        let cacheReadTokens: Int64

        var totalTokens: Int64 {
            inputTokens + outputTokens + cacheCreationTokens + cacheReadTokens
        }
    }

    private static let periodFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static let compactPeriodFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyyMMdd"
        return formatter
    }()

    private static let helperTimeout: TimeInterval = 30
    private static let supportedAgentIDs = Set(["claude", "codex"])

    static func bundledHelperURL(bundle: Bundle = .main) -> URL {
        bundle.bundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Helpers", isDirectory: true)
            .appendingPathComponent("ccusage", isDirectory: false)
    }

    func fetch(days: Int = 30, now: Date = .now) async throws -> LocalAIUsageSnapshot {
        let helper = Self.bundledHelperURL()
        guard FileManager.default.isExecutableFile(atPath: helper.path) else {
            throw ServiceError.helperMissing
        }
        let start = Calendar.current.date(byAdding: .day, value: -(max(1, days) - 1), to: now) ?? now
        let since = Self.compactPeriodFormatter.string(from: start)
        async let claudeOutput = Self.run(
            executable: helper,
            arguments: [
                "claude", "daily", "--json", "--breakdown", "--offline", "--no-color",
                "--timezone", TimeZone.current.identifier,
                "--since", since,
            ]
        )
        async let codexOutput = Self.run(
            executable: helper,
            arguments: [
                "codex", "daily", "--json", "--offline", "--no-color",
                "--timezone", TimeZone.current.identifier,
                "--since", since,
            ]
        )
        do {
            return try await Self.parse(
                sources: [
                    (agentID: "claude", data: claudeOutput),
                    (agentID: "codex", data: codexOutput),
                ],
                capturedAt: now
            )
        } catch {
            if error is CancellationError || error is ServiceError { throw error }
            throw ServiceError.invalidOutput
        }
    }

    static func parse(_ data: Data, capturedAt: Date = .now) throws -> LocalAIUsageSnapshot {
        let response = try JSONDecoder().decode(Response.self, from: data)
        let days = response.daily.compactMap { row -> LocalAIUsageSnapshot.Day? in
            guard let date = periodFormatter.date(from: row.period) else { return nil }
            let agents = (row.agents ?? []).compactMap { agent -> LocalAIUsageSnapshot.Agent? in
                let id = agent.agent.lowercased()
                guard supportedAgentIDs.contains(id) else { return nil }
                return LocalAIUsageSnapshot.Agent(
                    id: id,
                    tokens: max(0, agent.totalTokens),
                    estimatedCost: max(0, agent.totalCost),
                    unpricedModels: unpricedModels(in: agent),
                    inputTokens: max(0, agent.modelBreakdowns?.reduce(0) { $0 + $1.inputTokens } ?? 0),
                    outputTokens: max(0, agent.modelBreakdowns?.reduce(0) { $0 + $1.outputTokens } ?? 0),
                    cacheCreationTokens: max(0, agent.modelBreakdowns?.reduce(0) { $0 + $1.cacheCreationTokens } ?? 0),
                    cacheReadTokens: max(0, agent.modelBreakdowns?.reduce(0) { $0 + $1.cacheReadTokens } ?? 0)
                )
            }
            return LocalAIUsageSnapshot.Day(date: date, agents: agents)
        }
        .sorted { $0.date < $1.date }
        return LocalAIUsageSnapshot(days: days, capturedAt: capturedAt)
    }

    static func parse(
        sources: [(agentID: String, data: Data)],
        capturedAt: Date = .now
    ) throws -> LocalAIUsageSnapshot {
        var agentsByDate: [Date: [LocalAIUsageSnapshot.Agent]] = [:]
        for source in sources {
            let id = source.agentID.lowercased()
            guard supportedAgentIDs.contains(id) else { continue }
            let response = try JSONDecoder().decode(SourceResponse.self, from: source.data)
            for row in response.daily {
                guard let date = periodFormatter.date(from: row.date) else { continue }
                let cost = max(0, row.totalCost ?? row.costUSD ?? 0)
                let modelRows = row.modelBreakdowns ?? []
                let sourceRows: [SourceModelRow] = row.models.map { Array($0.values) } ?? []
                let input = !modelRows.isEmpty
                    ? modelRows.reduce(0) { $0 + $1.inputTokens }
                    : sourceRows.reduce(0) { $0 + $1.inputTokens }
                let output = !modelRows.isEmpty
                    ? modelRows.reduce(0) { $0 + $1.outputTokens }
                    : sourceRows.reduce(0) { $0 + $1.outputTokens }
                let cacheCreation = !modelRows.isEmpty
                    ? modelRows.reduce(0) { $0 + $1.cacheCreationTokens }
                    : sourceRows.reduce(0) { $0 + $1.cacheCreationTokens }
                let cacheRead = !modelRows.isEmpty
                    ? modelRows.reduce(0) { $0 + $1.cacheReadTokens }
                    : sourceRows.reduce(0) { $0 + $1.cacheReadTokens }
                let modelNames = row.modelsUsed ?? row.models.map { Array($0.keys).sorted() } ?? []
                let unpricedModels: [String]
                if !modelRows.isEmpty {
                    unpricedModels = Array(Set(modelRows.compactMap { model in
                        model.totalTokens > 0 && model.cost == 0 && model.modelName != "<synthetic>"
                            ? model.modelName
                            : nil
                    })).sorted()
                } else if row.totalTokens > 0, cost == 0 {
                    unpricedModels = modelNames
                } else {
                    unpricedModels = []
                }
                agentsByDate[date, default: []].append(.init(
                    id: id,
                    tokens: max(0, row.totalTokens),
                    estimatedCost: cost,
                    unpricedModels: unpricedModels,
                    inputTokens: max(0, input),
                    outputTokens: max(0, output),
                    cacheCreationTokens: max(0, cacheCreation),
                    cacheReadTokens: max(0, cacheRead)
                ))
            }
        }
        let days = agentsByDate.map { date, agents in
            LocalAIUsageSnapshot.Day(
                date: date,
                agents: agents.sorted { $0.id < $1.id }
            )
        }
        .sorted { $0.date < $1.date }
        return LocalAIUsageSnapshot(days: days, capturedAt: capturedAt)
    }

    private static func unpricedModels(in agent: AgentRow) -> [String] {
        let rows = agent.modelBreakdowns ?? []
        let missing = rows
            .filter { $0.totalTokens > 0 && $0.cost == 0 && $0.modelName != "<synthetic>" }
            .map(\.modelName)
        if !missing.isEmpty { return Array(Set(missing)).sorted() }
        if agent.totalTokens > 0, agent.totalCost == 0, rows.isEmpty {
            return Array(Set(agent.modelsUsed ?? [])).sorted()
        }
        return []
    }

    private static func run(executable: URL, arguments: [String]) async throws -> Data {
        try await Task.detached(priority: .utility) {
            let process = Process()
            let stdout = Pipe()
            let stderr = Pipe()
            process.executableURL = executable
            process.arguments = arguments
            process.standardOutput = stdout
            process.standardError = stderr

            do {
                try process.run()
            } catch {
                throw ServiceError.helperFailed(error.localizedDescription)
            }

            async let output = Task.detached {
                stdout.fileHandleForReading.readDataToEndOfFile()
            }.value
            async let errorOutput = Task.detached {
                stderr.fileHandleForReading.readDataToEndOfFile()
            }.value

            let deadline = Date().addingTimeInterval(helperTimeout)
            while process.isRunning && Date() < deadline {
                if Task.isCancelled {
                    process.terminate()
                    process.waitUntilExit()
                    _ = await output
                    _ = await errorOutput
                    throw CancellationError()
                }
                do {
                    try await Task.sleep(nanoseconds: 50_000_000)
                } catch {
                    process.terminate()
                    process.waitUntilExit()
                    _ = await output
                    _ = await errorOutput
                    throw error
                }
            }
            if process.isRunning {
                process.terminate()
                process.waitUntilExit()
                _ = await output
                _ = await errorOutput
                throw ServiceError.helperTimedOut
            }

            let data = await output
            let errorData = await errorOutput
            guard process.terminationStatus == 0 else {
                let detail = String(data: errorData, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                throw ServiceError.helperFailed(detail?.isEmpty == false ? detail! : "exit \(process.terminationStatus)")
            }
            return data
        }.value
    }
}

@MainActor
final class LocalAIUsageManager: ObservableObject {
    enum State: Equatable {
        case idle
        case loading
        case available
        case empty
        case failed(String)
    }

    @Published private(set) var snapshot: LocalAIUsageSnapshot?
    @Published private(set) var state: State = .idle
    @Published private(set) var isRefreshing = false

    private let service: LocalAIUsageService
    private var timer: Timer?

    private var cacheURL: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("QuickVibeHost", isDirectory: true)
            .appendingPathComponent("local-ai-usage-v2.json")
    }

    init(service: LocalAIUsageService = LocalAIUsageService()) {
        self.service = service
        loadCache()
    }

    func startPolling() {
        guard timer == nil else { return }
        Task { await refresh() }
        timer = Timer.scheduledTimer(withTimeInterval: 5 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
    }

    func stopPolling() {
        timer?.invalidate()
        timer = nil
    }

    func refresh(force: Bool = false) async {
        guard !isRefreshing else { return }
        if !force, let capturedAt = snapshot?.capturedAt {
            let age = Date().timeIntervalSince(capturedAt)
            if age >= 0, age < 60 { return }
        }
        isRefreshing = true
        if snapshot == nil { state = .loading }
        defer { isRefreshing = false }

        do {
            let next = try await service.fetch()
            snapshot = next
            state = next.days.allSatisfy { $0.totalTokens == 0 } ? .empty : .available
            saveCache(next)
        } catch {
            if snapshot == nil {
                state = .failed(error.localizedDescription)
            }
        }
    }

    private func loadCache() {
        guard let data = try? Data(contentsOf: cacheURL),
              let cached = try? JSONDecoder().decode(LocalAIUsageSnapshot.self, from: data) else { return }
        let limited = cached.limited(toAgentIDs: ["claude", "codex"])
        snapshot = limited
        state = limited.days.allSatisfy { $0.totalTokens == 0 } ? .empty : .available
    }

    private func saveCache(_ value: LocalAIUsageSnapshot) {
        do {
            try FileManager.default.createDirectory(
                at: cacheURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try JSONEncoder().encode(value).write(to: cacheURL, options: .atomic)
        } catch {
            NSLog("[LocalAIUsage] cache write failed: \(error.localizedDescription)")
        }
    }
}
