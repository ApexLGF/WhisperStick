import Foundation
import CoreGraphics
import SQLite3

struct WorkBuddySessionRecord: Identifiable, Sendable, Equatable {
    let id: String
    let title: String
    let status: String
    let cwd: String
    let model: String?
    let projectID: String?
    let transport: String
    let createdAt: Date
    let lastActivity: Date
    let contextUsed: Int?
    let contextLimit: Int?
    let historicalCredits: Double
    let transcriptPath: String?
}

struct WorkBuddyCreditSummary: Sendable, Equatable {
    let todayCredits: Double?
    let historicalCredits: Double
    let updatedAt: Date?
}

struct WorkBuddySnapshot: Sendable, Equatable {
    let sessions: [WorkBuddySessionRecord]
    let credits: WorkBuddyCreditSummary
}

enum WorkBuddyActivityState: Equatable, Sendable {
    case thinking
    case toolRunning
    case waitingForInput
    case idle
}

enum WorkBuddyLeaseState: Equatable, Sendable {
    case inactive
    case active
    case grace
    case orphaned
    case stale
    case unknown

    var isDeviceActive: Bool {
        switch self {
        case .active, .grace, .unknown: return true
        case .inactive, .orphaned, .stale: return false
        }
    }
}

enum WorkBuddyLeaseEvent: Equatable, Sendable {
    case started
    case cancelled
}

enum WorkBuddyLeaseTransition {
    static func event(previous: WorkBuddyLeaseState,
                      current: WorkBuddyLeaseState) -> WorkBuddyLeaseEvent? {
        guard previous != current else { return nil }
        if current == .orphaned { return .cancelled }
        if current == .active, previous == .inactive || previous == .orphaned {
            return .started
        }
        return nil
    }
}

/// WorkBuddy can reuse a local project session while leaving its durable
/// database status as `terminated`. A live per-session worker plus recent
/// progress is therefore a stronger signal than that stale terminal value.
/// The bounded window prevents an idle lingering worker from keeping a card
/// active forever.
enum WorkBuddyEffectiveActivityPolicy {
    static let localResumeWindow: TimeInterval = 30 * 60

    static func shouldTrack(databaseWorking: Bool,
                            transport: String,
                            workerAlive: Bool?,
                            lastProgressAt: Date,
                            now: Date) -> Bool {
        if databaseWorking { return true }
        guard transport.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "local",
              workerAlive == true else { return false }
        return now.timeIntervalSince(lastProgressAt) < localResumeWindow
    }
}

enum WorkBuddyTranscriptLifecycleEvent: Equatable, Sendable {
    case started
    case completed
}

enum WorkBuddyTranscriptLifecycleMapper {
    static func outcome(previous: WorkBuddyActivityState,
                        current: WorkBuddyActivityState) -> WorkBuddyTranscriptLifecycleEvent? {
        guard previous != current else { return nil }
        switch (previous, current) {
        case (.idle, .thinking), (.idle, .toolRunning):
            return .started
        case (.thinking, .idle), (.toolRunning, .idle):
            return .completed
        default:
            return nil
        }
    }
}

/// Combines WorkBuddy's durable database status, transcript progress and its
/// per-session worker process. Recent database/JSONL progress is authoritative:
/// newer WorkBuddy releases use a prewarm pool whose processes do not expose a
/// session ID, so a negative process probe alone cannot end a live task.
struct WorkBuddyLeaseTracker: Sendable {
    struct Configuration: Sendable {
        let missingWorkerGrace: TimeInterval
        let liveWorkerStaleAfter: TimeInterval

        static let production = Configuration(
            missingWorkerGrace: 15,
            liveWorkerStaleAfter: 30 * 60
        )
    }

    private let configuration: Configuration
    private var missingWorkerSince: [String: Date] = [:]

    init(configuration: Configuration = .production) {
        self.configuration = configuration
    }

    mutating func evaluate(sessionID: String,
                           rawWorking: Bool,
                           workerAlive: Bool?,
                           lastProgressAt: Date,
                           now: Date) -> WorkBuddyLeaseState {
        guard rawWorking else {
            missingWorkerSince.removeValue(forKey: sessionID)
            return .inactive
        }
        // A current database timestamp or growing JSONL proves the task is
        // alive even when WorkBuddy's pooled worker cannot be mapped by PID.
        if now.timeIntervalSince(lastProgressAt) < configuration.liveWorkerStaleAfter {
            missingWorkerSince.removeValue(forKey: sessionID)
            return .active
        }
        guard let workerAlive else {
            missingWorkerSince.removeValue(forKey: sessionID)
            return .stale
        }
        if workerAlive {
            missingWorkerSince.removeValue(forKey: sessionID)
            return .stale
        }

        let firstMissing = missingWorkerSince[sessionID] ?? now
        missingWorkerSince[sessionID] = firstMissing
        return now.timeIntervalSince(firstMissing) >= configuration.missingWorkerGrace
            ? .orphaned : .grace
    }

    mutating func retain(sessionIDs: Set<String>) {
        missingWorkerSince = missingWorkerSince.filter { sessionIDs.contains($0.key) }
    }
}

enum WorkBuddyWorkerCommandParser {
    /// Parses `ps -axo args=` without retaining or logging command lines. Only
    /// the UUID immediately following WorkBuddy's `--session-id` is returned.
    static func sessionIDs(from processArguments: String) -> Set<String> {
        var result: Set<String> = []
        for line in processArguments.split(whereSeparator: \Character.isNewline) {
            let tokens = line.split(whereSeparator: \Character.isWhitespace).map(String.init)
            guard tokens.contains("--serve"),
                  tokens.contains(where: { URL(fileURLWithPath: $0).lastPathComponent == "codebuddy" })
            else { continue }
            for index in tokens.indices {
                if tokens[index] == "--session-id", tokens.indices.contains(index + 1) {
                    insertIfValid(tokens[index + 1], into: &result)
                } else if tokens[index].hasPrefix("--session-id=") {
                    insertIfValid(String(tokens[index].dropFirst("--session-id=".count)), into: &result)
                }
            }
        }
        return result
    }

    private static func insertIfValid(_ value: String, into result: inout Set<String>) {
        guard UUID(uuidString: value) != nil else { return }
        result.insert(value.lowercased())
    }
}

enum WorkBuddyTranscriptFilePolicy {
    static func shouldReset(previousFileID: UInt64?, currentFileID: UInt64?,
                            previousOffset: UInt64, currentSize: UInt64) -> Bool {
        if let previousFileID, let currentFileID, previousFileID != currentFileID {
            return true
        }
        return currentSize < previousOffset
    }

    static func consumeCompleteLines(appended: Data, previousRemainder: Data,
                                     tracker: WorkBuddyActivityTracker)
        -> (remainder: Data, tracker: WorkBuddyActivityTracker) {
        var nextTracker = tracker
        var combined = previousRemainder
        combined.append(appended)
        guard let newline = combined.lastIndex(of: 0x0A) else {
            return (combined, nextTracker)
        }
        nextTracker.ingestCompleteLines(Data(combined[...newline]))
        let next = combined.index(after: newline)
        let remainder = next < combined.endIndex ? Data(combined[next...]) : Data()
        return (remainder, nextTracker)
    }
}

struct WorkBuddyWatchCandidate: Sendable {
    let id: String
    let rawWorking: Bool
    let lease: WorkBuddyLeaseState
    let lastActivity: Date
}

enum WorkBuddyTranscriptWatchPolicy {
    static let maximumCount = 8

    static func desiredSessionIDs(from candidates: [WorkBuddyWatchCandidate],
                                  maximumCount: Int = maximumCount) -> [String] {
        candidates
            .filter { candidate in
                candidate.rawWorking
                    && candidate.lease != .inactive
                    && candidate.lease != .orphaned
            }
            .sorted {
                if $0.lastActivity != $1.lastActivity {
                    return $0.lastActivity > $1.lastActivity
                }
                return $0.id < $1.id
            }
            .prefix(max(0, maximumCount))
            .map(\.id)
    }
}

/// Incrementally derives the visible activity of a WorkBuddy turn from its
/// append-only JSONL transcript. Database `status` remains the outer task
/// lifecycle; this tracker only refines the activity while that status is
/// working. A set is required because WorkBuddy can execute tools in parallel.
struct WorkBuddyActivityTracker: Sendable {
    private(set) var state: WorkBuddyActivityState?
    private var activeCallIDs: Set<String> = []
    private var waitingCallIDs: Set<String> = []

    mutating func reset() {
        state = nil
        activeCallIDs.removeAll()
        waitingCallIDs.removeAll()
    }

    mutating func ingestCompleteLines(_ data: Data) {
        for line in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
            ingestLine(Data(line))
        }
    }

    mutating func ingestLine(_ data: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String else { return }

        switch type.lowercased() {
        case "message":
            let role = (object["role"] as? String)?.lowercased()
            if role == "user" {
                // A new outer turn supersedes any stale unfinished tool IDs
                // left by an interrupted previous turn.
                activeCallIDs.removeAll()
                waitingCallIDs.removeAll()
                updateState(defaultingTo: .thinking)
            } else if role == "assistant",
                      (object["status"] as? String)?.lowercased() == "completed" {
                // Intermediate assistant messages are normally followed by a
                // function call in the same debounced batch. The final one is
                // not, so it should hand control back to the user immediately.
                // It also closes any tool IDs whose result was omitted after a
                // cancellation; the completed assistant response is the newer
                // and stronger boundary signal.
                activeCallIDs.removeAll()
                waitingCallIDs.removeAll()
                updateState(defaultingTo: .idle)
            } else {
                updateState(defaultingTo: .thinking)
            }

        case "reasoning":
            updateState(defaultingTo: .thinking)

        case "function_call":
            let callID = identifier(in: object)
            activeCallIDs.insert(callID)
            if Self.isUserInputTool(object["name"] as? String) {
                waitingCallIDs.insert(callID)
            }
            updateState(defaultingTo: .toolRunning)

        case "function_call_result":
            let callID = identifier(in: object)
            let status = (object["status"] as? String)?.lowercased() ?? "completed"
            if ["completed", "failed", "error", "cancelled", "canceled"].contains(status) {
                activeCallIDs.remove(callID)
                waitingCallIDs.remove(callID)
            }
            updateState(defaultingTo: .thinking)

        default:
            break
        }
    }

    private mutating func updateState(defaultingTo fallback: WorkBuddyActivityState) {
        if !waitingCallIDs.isEmpty {
            state = .waitingForInput
        } else if !activeCallIDs.isEmpty {
            state = .toolRunning
        } else {
            state = fallback
        }
    }

    private func identifier(in object: [String: Any]) -> String {
        if let callID = object["callId"] as? String, !callID.isEmpty { return callID }
        if let id = object["id"] as? String, !id.isEmpty { return id }
        // Malformed calls are rare, but preserving an anonymous active marker
        // is safer than falsely showing the model as thinking during a tool.
        return "anonymous-call"
    }

    private static func isUserInputTool(_ name: String?) -> Bool {
        let normalized = (name ?? "")
            .lowercased()
            .filter { $0.isLetter || $0.isNumber }
        return normalized.contains("askuser") || normalized.contains("requestuserinput")
    }
}

struct WorkBuddyFocusCandidateMetadata: Sendable {
    let role: String
    let subrole: String
    let label: String
    let domClasses: [String]
    let frame: CGRect?
    let enabled: Bool
}

/// Pure policy kept separate from Accessibility traversal so candidate ranking
/// can be tested without granting the test process Accessibility permission.
enum WorkBuddyFocusPolicy {
    static func isEditable(_ candidate: WorkBuddyFocusCandidateMetadata) -> Bool {
        guard candidate.enabled, candidate.subrole != "AXSecureTextField" else { return false }
        if ["AXTextArea", "AXTextField", "AXComboBox"].contains(candidate.role) {
            return true
        }
        // WorkBuddy's project/local conversation editor is lazy: before its
        // first click Electron exposes only the surrounding AXGroup. Clicking
        // this semantic container materializes the real AXTextArea. Restrict
        // the exception to WorkBuddy's own composer class so arbitrary groups
        // (sidebar, transcript, browser content) can never become candidates.
        return candidate.role == "AXGroup" && candidate.domClasses.contains { cssClass in
            cssClass.lowercased().contains("input-area-container")
        }
    }

    static func score(_ candidate: WorkBuddyFocusCandidateMetadata,
                      in windowFrame: CGRect?) -> Int? {
        guard isEditable(candidate) else { return nil }
        let isLazyComposer = candidate.role == "AXGroup"
            && candidate.domClasses.contains { $0.lowercased().contains("input-area-container") }
        var value = isLazyComposer ? 240 : (candidate.role == "AXTextArea" ? 120 : 80)
        let label = candidate.label.lowercased()
        if ["message", "prompt", "ask", "输入", "提问", "发送消息"].contains(where: label.contains) {
            value += 120
        }
        if ["search", "搜索", "查找"].contains(where: label.contains) {
            value -= 160
        }
        if let frame = candidate.frame {
            guard frame.size.width >= 100, frame.size.height >= 18 else { return nil }
            if frame.size.width >= 240 { value += 25 }
            if frame.size.height >= 32 { value += 15 }
            if let windowFrame,
               frame.origin.y + frame.size.height / 2 >=
                windowFrame.origin.y + windowFrame.size.height / 2 { value += 60 }
        }
        return value
    }
}

enum WorkBuddyDataError: LocalizedError {
    case databaseUnavailable
    case queryFailed(String)

    var errorDescription: String? {
        switch self {
        case .databaseUnavailable:
            return "WorkBuddy database is unavailable"
        case .queryFailed(let message):
            return "WorkBuddy query failed: \(message)"
        }
    }
}

enum WorkBuddyCreditCalculator {
    static func credits(from json: String?) -> [String: Double] {
        guard let json, let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return object.reduce(into: [:]) { result, pair in
            let value: Double?
            switch pair.value {
            case let number as NSNumber: value = number.doubleValue
            case let string as String: value = Double(string)
            default: value = nil
            }
            if let value, value.isFinite, value >= 0 {
                result[pair.key] = value
            }
        }
    }

    static func total(_ credits: [String: Double]) -> Double {
        credits.values.reduce(0, +)
    }

    static func requestTimestamps(inJSONL data: Data, requestIDs: Set<String>) -> [String: Date] {
        guard !requestIDs.isEmpty else { return [:] }
        var result: [String: Date] = [:]
        data.split(separator: 0x0A, omittingEmptySubsequences: true).forEach { line in
            guard result.count < requestIDs.count,
                  let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let timestamp = numericTimestamp(object["timestamp"]),
                  let provider = object["providerData"] as? [String: Any],
                  let requestID = provider["conversationRequestId"] as? String,
                  requestIDs.contains(requestID), result[requestID] == nil else { return }
            result[requestID] = Date(timeIntervalSince1970: timestamp / 1000)
        }
        return result
    }

    private static func numericTimestamp(_ value: Any?) -> Double? {
        switch value {
        case let number as NSNumber: return number.doubleValue
        case let string as String: return Double(string)
        default: return nil
        }
    }
}

/// Read-only adapter for WorkBuddy's local session index. The schema is private,
/// so every query is defensive and a failed read leaves the previous UI snapshot intact.
final class WorkBuddyDataSource: @unchecked Sendable {
    static let defaultDatabaseURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".workbuddy/workbuddy.db")
    static let defaultProjectsRoot = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".workbuddy/projects")

    private struct CreditCacheEntry {
        let usageUpdatedAt: Int64
        let dayStart: Date
        let todayCredits: Double?
    }

    private let databaseURL: URL
    private let projectsRoot: URL
    private let calendar: Calendar
    private let lock = NSLock()
    private var transcriptPaths: [String: String] = [:]
    private var creditCache: [String: CreditCacheEntry] = [:]

    init(databaseURL: URL = defaultDatabaseURL,
         projectsRoot: URL = defaultProjectsRoot,
         calendar: Calendar = .current) {
        self.databaseURL = databaseURL
        self.projectsRoot = projectsRoot
        self.calendar = calendar
    }

    func read(now: Date = .now) throws -> WorkBuddySnapshot {
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(databaseURL.path, &db, flags, nil) == SQLITE_OK, let db else {
            if let db { sqlite3_close(db) }
            throw WorkBuddyDataError.databaseUnavailable
        }
        defer { sqlite3_close(db) }

        let transportExpression = hasColumn("transport", inTable: "sessions", database: db)
            ? "COALESCE(s.transport, 'local')" : "'local'"
        let sql = """
        SELECT s.id,
               COALESCE(NULLIF(s.custom_title, ''), NULLIF(s.title, ''), 'WorkBuddy'),
               s.status, s.cwd, s.model, s.project_id,
               s.created_at, COALESCE(s.last_activity_at, s.updated_at),
               u.used, u.size, u.updated_at, u.credit_json, \(transportExpression)
          FROM sessions s
          LEFT JOIN session_usage u ON u.session_id = s.id
         WHERE s.deleted_at IS NULL
         ORDER BY COALESCE(s.last_activity_at, s.updated_at) DESC
         LIMIT 100
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw WorkBuddyDataError.queryFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }

        let dayStart = calendar.startOfDay(for: now)
        let nextDay = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart.addingTimeInterval(86_400)
        var sessions: [WorkBuddySessionRecord] = []
        var historical = 0.0
        var today = 0.0
        var todayComplete = true
        var newestUpdate: Date?

        while sqlite3_step(statement) == SQLITE_ROW {
            guard let id = text(statement, 0), !id.isEmpty else { continue }
            let creditMap = WorkBuddyCreditCalculator.credits(from: text(statement, 11))
            let sessionCredits = WorkBuddyCreditCalculator.total(creditMap)
            let usageUpdatedAt = sqlite3_column_type(statement, 10) == SQLITE_NULL
                ? 0 : sqlite3_column_int64(statement, 10)
            let attributedToday = todayCredits(
                sessionID: id,
                credits: creditMap,
                usageUpdatedAt: usageUpdatedAt,
                dayStart: dayStart,
                nextDay: nextDay
            )
            if let attributedToday {
                today += attributedToday
            } else if !creditMap.isEmpty {
                todayComplete = false
            }
            historical += sessionCredits

            let createdAt = date(milliseconds: sqlite3_column_int64(statement, 6))
            let activity = date(milliseconds: sqlite3_column_int64(statement, 7))
            let transcript = transcriptURL(for: id)?.path
            let contextUsed = optionalInt(statement, 8)
            let contextLimit = optionalInt(statement, 9)
            let updated = usageUpdatedAt > 0 ? date(milliseconds: usageUpdatedAt) : activity
            if newestUpdate == nil || updated > newestUpdate! { newestUpdate = updated }
            sessions.append(WorkBuddySessionRecord(
                id: id,
                title: text(statement, 1) ?? "WorkBuddy",
                status: text(statement, 2) ?? "unknown",
                cwd: text(statement, 3) ?? "",
                model: text(statement, 4),
                projectID: text(statement, 5),
                transport: text(statement, 12) ?? "local",
                createdAt: createdAt,
                lastActivity: activity,
                contextUsed: contextUsed,
                contextLimit: contextLimit,
                historicalCredits: sessionCredits,
                transcriptPath: transcript
            ))
        }
        guard sqlite3_errcode(db) == SQLITE_OK || sqlite3_errcode(db) == SQLITE_DONE else {
            throw WorkBuddyDataError.queryFailed(String(cString: sqlite3_errmsg(db)))
        }

        return WorkBuddySnapshot(
            sessions: sessions,
            credits: WorkBuddyCreditSummary(
                todayCredits: todayComplete ? today : nil,
                historicalCredits: historical,
                updatedAt: newestUpdate
            )
        )
    }

    private func todayCredits(sessionID: String, credits: [String: Double],
                              usageUpdatedAt: Int64, dayStart: Date, nextDay: Date) -> Double? {
        guard !credits.isEmpty else { return 0 }
        lock.lock()
        if let cached = creditCache[sessionID], cached.usageUpdatedAt == usageUpdatedAt,
           cached.dayStart == dayStart {
            lock.unlock()
            return cached.todayCredits
        }
        lock.unlock()

        guard let url = transcriptURL(for: sessionID),
              let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) else {
            // The database and JSONL are written independently. A DB event may
            // arrive first, so do not cache an incomplete attribution result.
            return nil
        }
        let timestamps = WorkBuddyCreditCalculator.requestTimestamps(
            inJSONL: data, requestIDs: Set(credits.keys)
        )
        guard timestamps.count == credits.count else {
            // Retry on the next filesystem event/10-second fallback scan after
            // WorkBuddy finishes appending the matching transcript entries.
            return nil
        }
        let value = credits.reduce(0.0) { partial, pair in
            guard let timestamp = timestamps[pair.key], timestamp >= dayStart, timestamp < nextDay else {
                return partial
            }
            return partial + pair.value
        }
        cache(sessionID: sessionID, usageUpdatedAt: usageUpdatedAt,
              dayStart: dayStart, todayCredits: value)
        return value
    }

    private func cache(sessionID: String, usageUpdatedAt: Int64,
                       dayStart: Date, todayCredits: Double) {
        lock.lock()
        creditCache[sessionID] = CreditCacheEntry(
            usageUpdatedAt: usageUpdatedAt,
            dayStart: dayStart,
            todayCredits: todayCredits
        )
        lock.unlock()
    }

    private func transcriptURL(for sessionID: String) -> URL? {
        lock.lock()
        if let path = transcriptPaths[sessionID] {
            lock.unlock()
            return URL(fileURLWithPath: path)
        }
        lock.unlock()

        guard let enumerator = FileManager.default.enumerator(
            at: projectsRoot,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }
        let target = sessionID + ".jsonl"
        for case let url as URL in enumerator where url.lastPathComponent == target {
            lock.lock()
            transcriptPaths[sessionID] = url.path
            lock.unlock()
            return url
        }
        return nil
    }

    private func text(_ statement: OpaquePointer, _ column: Int32) -> String? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL,
              let value = sqlite3_column_text(statement, column) else { return nil }
        return String(cString: value)
    }

    private func hasColumn(_ column: String, inTable table: String,
                           database: OpaquePointer) -> Bool {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "PRAGMA table_info(\(table))", -1, &statement, nil)
                == SQLITE_OK,
              let statement else { return false }
        defer { sqlite3_finalize(statement) }
        while sqlite3_step(statement) == SQLITE_ROW {
            if text(statement, 1) == column { return true }
        }
        return false
    }

    private func optionalInt(_ statement: OpaquePointer, _ column: Int32) -> Int? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL else { return nil }
        return Int(sqlite3_column_int64(statement, column))
    }

    private func date(milliseconds: Int64) -> Date {
        Date(timeIntervalSince1970: Double(milliseconds) / 1000)
    }
}
