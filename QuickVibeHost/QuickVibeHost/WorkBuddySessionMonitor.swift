import AppKit
import Combine
import Darwin
import Foundation

@MainActor
final class WorkBuddySessionMonitor: ObservableObject {
    @Published private(set) var sessions: [String: HookSession] = [:]
    @Published private(set) var credits = WorkBuddyCreditSummary(
        todayCredits: nil,
        historicalCredits: 0,
        updatedAt: nil
    )
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastError: String?
    var onTaskLifecycleEvent: ((TaskLifecycleSignal) -> Void)?
    weak var approvalServer: WorkBuddyApprovalServer?

    nonisolated static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: WorkBuddyDataSource.defaultDatabaseURL.path)
            || FileManager.default.fileExists(atPath: "/Applications/WorkBuddy.app")
    }

    private let source: WorkBuddyDataSource
    private var timer: Timer?
    private var directorySource: DispatchSourceFileSystemObject?
    private var directoryDescriptor: Int32 = -1
    private var databaseWatches: [String: DatabaseWatch] = [:]
    private var databaseWatchRetryTask: Task<Void, Never>?
    private var debounceWork: DispatchWorkItem?
    private var refreshPending = false
    private var observedStatuses: [String: String]?
    private var conversationFocusTask: Task<Void, Never>?
    private var workingSessionIDs: Set<String> = []
    private var leaseTracker = WorkBuddyLeaseTracker()
    private var leaseStates: [String: WorkBuddyLeaseState] = [:]
    private var transcriptWatches: [String: TranscriptWatch] = [:]
    private var transcriptDebounceTasks: [String: Task<Void, Never>] = [:]
    private var transcriptRebuildTasks: [String: Task<Void, Never>] = [:]
    private var desiredTranscriptPaths: [String: String] = [:]

    private final class DatabaseWatch {
        let path: String
        let descriptor: Int32
        let source: DispatchSourceFileSystemObject
        let fileID: UInt64?

        init(path: String, descriptor: Int32, source: DispatchSourceFileSystemObject,
             fileID: UInt64?) {
            self.path = path
            self.descriptor = descriptor
            self.source = source
            self.fileID = fileID
        }
    }

    private final class TranscriptWatch {
        let sessionID: String
        let path: String
        let descriptor: Int32
        let source: DispatchSourceFileSystemObject
        var offset: UInt64 = 0
        var remainder = Data()
        var tracker = WorkBuddyActivityTracker()
        var fileID: UInt64?
        var lastContentChangeAt: Date = .distantPast
        var readInFlight = false
        var needsAnotherRead = false

        init(sessionID: String, path: String, descriptor: Int32,
             source: DispatchSourceFileSystemObject) {
            self.sessionID = sessionID
            self.path = path
            self.descriptor = descriptor
            self.source = source
        }
    }

    private struct TranscriptReadResult: Sendable {
        let offset: UInt64
        let remainder: Data
        let tracker: WorkBuddyActivityTracker
        let fileID: UInt64?
        let identityChanged: Bool
        let modifiedAt: Date?
    }

    private static let bundleIdentifier = "com.tencent.workbuddy.mac"

    init(source: WorkBuddyDataSource = WorkBuddyDataSource()) {
        self.source = source
    }

    func start() {
        guard Self.isInstalled, timer == nil else { return }
        refresh()
        watchDirectory()
        syncDatabaseWatches()
        timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        debounceWork?.cancel()
        debounceWork = nil
        refreshPending = false
        conversationFocusTask?.cancel()
        conversationFocusTask = nil
        observedStatuses = nil
        workingSessionIDs.removeAll()
        leaseTracker = WorkBuddyLeaseTracker()
        leaseStates.removeAll()
        transcriptDebounceTasks.values.forEach { $0.cancel() }
        transcriptDebounceTasks.removeAll()
        transcriptRebuildTasks.values.forEach { $0.cancel() }
        transcriptRebuildTasks.removeAll()
        desiredTranscriptPaths.removeAll()
        transcriptWatches.values.forEach { $0.source.cancel() }
        transcriptWatches.removeAll()
        databaseWatchRetryTask?.cancel()
        databaseWatchRetryTask = nil
        databaseWatches.values.forEach { $0.source.cancel() }
        databaseWatches.removeAll()
        directorySource?.cancel()
        directorySource = nil
        // The descriptor is owned by the dispatch source and is closed by its
        // cancellation handler after any in-flight event handler has drained.
        directoryDescriptor = -1
    }

    func refresh() {
        syncDatabaseWatches()
        guard !isRefreshing else {
            refreshPending = true
            return
        }
        isRefreshing = true
        let source = source
        Task { [weak self] in
            let result = await Task.detached(priority: .utility) {
                Result { (try source.read(), Self.liveWorkerSessionIDs()) }
            }.value
            guard let self else { return }
            switch result {
            case .success(let (snapshot, liveWorkerIDs)):
                apply(snapshot, liveWorkerIDs: liveWorkerIDs, now: .now)
            case .failure(let error): record(error)
            }
            if self.refreshPending {
                self.refreshPending = false
                self.refresh()
            }
        }
    }

    var activeSessions: [HookSession] { partitioned().active }
    var inactiveSessions: [HookSession] { partitioned().inactive }

    @discardableResult
    func openConversation(id prefixedID: String) -> Bool {
        let id = prefixedID.hasPrefix("workbuddy:")
            ? String(prefixedID.dropFirst("workbuddy:".count)) : prefixedID
        guard !id.isEmpty,
              let encoded = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "workbuddy://chat/\(encoded)") else { return false }
        let opened = NSWorkspace.shared.open(url)
        guard opened else { return false }
        conversationFocusTask?.cancel()
        conversationFocusTask = Task { [weak self] in
            await self?.focusConversationInputAfterNavigation(sessionID: id)
        }
        return true
    }

    private func focusConversationInputAfterNavigation(sessionID: String) async {
        // Deep-link navigation in WorkBuddy is asynchronous. Waiting first is
        // important: an editor from the previously visible conversation can
        // remain focused briefly and would otherwise cause a false success.
        try? await Task.sleep(nanoseconds: 650_000_000)
        guard !Task.isCancelled else { return }

        var observedFrontmost = false
        for attempt in 0..<6 {
            guard !Task.isCancelled,
                  let application = NSRunningApplication.runningApplications(
                    withBundleIdentifier: Self.bundleIdentifier
                  ).first(where: { !$0.isTerminated }) else { return }

            let isFrontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
                == application.processIdentifier
            if !isFrontmost {
                // The deep link is an explicit user navigation request. Bring
                // WorkBuddy forward once, but never steal focus back if the user
                // switches away after WorkBuddy has already appeared.
                guard !observedFrontmost else {
                    ClaudeCodeSessionManager.log(
                        "[WorkBuddy] focus cancelled: user left app session=\(sessionID)"
                    )
                    return
                }
                application.unhide()
                _ = application.activate(options: [.activateAllWindows])
                try? await Task.sleep(nanoseconds: 180_000_000)
                guard !Task.isCancelled else { return }
            }
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier
                    == application.processIdentifier else {
                try? await Task.sleep(nanoseconds: 220_000_000)
                continue
            }
            observedFrontmost = true

            let appElement = AXUIElementCreateApplication(application.processIdentifier)
            let window = axElement(appElement, attribute: kAXFocusedWindowAttribute)
                ?? axElement(appElement, attribute: kAXMainWindowAttribute)
            if let focused = axElement(appElement, attribute: kAXFocusedUIElementAttribute),
               isConversationInput(focused, in: window) {
                // Confirm once more after Electron has had another render turn.
                try? await Task.sleep(nanoseconds: 140_000_000)
                guard !Task.isCancelled else { return }
                if let confirmed = axElement(appElement, attribute: kAXFocusedUIElementAttribute),
                   isConversationInput(confirmed, in: window) {
                    ClaudeCodeSessionManager.log(
                        "[WorkBuddy] input already focused session=\(sessionID) attempt=\(attempt)"
                    )
                    return
                }
            }

            if let window, let candidate = bestEditableCandidate(in: window) {
                focus(candidate, in: appElement, window: window)
                try? await Task.sleep(nanoseconds: 100_000_000)
                guard !Task.isCancelled else { return }
                if let focused = axElement(appElement, attribute: kAXFocusedUIElementAttribute),
                   isConversationInput(focused, in: window) {
                    ClaudeCodeSessionManager.log(
                        "[WorkBuddy] input focused by AX session=\(sessionID) attempt=\(attempt)"
                    )
                    return
                }

                // Some Electron contenteditable controls expose AX metadata but
                // ignore AXFocused writes. A real click is the final fallback;
                // restore the pointer immediately so navigation feels seamless.
                if attempt >= 1, clickCenter(of: candidate) {
                    try? await Task.sleep(nanoseconds: 120_000_000)
                    guard !Task.isCancelled else { return }
                    if let focused = axElement(appElement, attribute: kAXFocusedUIElementAttribute),
                       isConversationInput(focused, in: window) {
                        ClaudeCodeSessionManager.log(
                            "[WorkBuddy] input focused by click session=\(sessionID) attempt=\(attempt)"
                        )
                        return
                    }
                }
            }
            try? await Task.sleep(nanoseconds: UInt64(220 + attempt * 90) * 1_000_000)
        }
        ClaudeCodeSessionManager.log("[WorkBuddy] input focus unavailable session=\(sessionID)")
    }

    private func bestEditableCandidate(in window: AXUIElement) -> AXUIElement? {
        let windowFrame = axFrame(window)
        var queue: [(AXUIElement, Int)] = [(window, 0)]
        var best: (element: AXUIElement, score: Int)?
        var visited = 0
        while !queue.isEmpty, visited < 900 {
            let (element, depth) = queue.removeFirst()
            visited += 1
            if let score = WorkBuddyFocusPolicy.score(metadata(for: element), in: windowFrame),
               score >= 160,
               best == nil || score > best!.score {
                best = (element, score)
            }
            guard depth < 18 else { continue }
            for child in axElements(element, attribute: kAXChildrenAttribute) {
                queue.append((child, depth + 1))
            }
        }
        return best?.element
    }

    private func isConversationInput(_ element: AXUIElement, in window: AXUIElement?) -> Bool {
        guard let score = WorkBuddyFocusPolicy.score(
            metadata(for: element), in: window.flatMap(axFrame)
        ) else { return false }
        return score >= 160
    }

    private func metadata(for element: AXUIElement) -> WorkBuddyFocusCandidateMetadata {
        let role = axString(element, attribute: kAXRoleAttribute) ?? ""
        let subrole = axString(element, attribute: kAXSubroleAttribute) ?? ""
        let label = [kAXTitleAttribute, kAXDescriptionAttribute, kAXHelpAttribute, "AXPlaceholderValue"]
            .compactMap { axString(element, attribute: $0) }
            .joined(separator: " ")
        return WorkBuddyFocusCandidateMetadata(
            role: role,
            subrole: subrole,
            label: label,
            domClasses: axStrings(element, attribute: "AXDOMClassList"),
            frame: axFrame(element),
            enabled: axBool(element, attribute: kAXEnabledAttribute) ?? true
        )
    }

    private func focus(_ element: AXUIElement, in app: AXUIElement, window: AXUIElement) {
        _ = AXUIElementSetAttributeValue(window, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        _ = AXUIElementSetAttributeValue(app, kAXFocusedWindowAttribute as CFString, window)
        _ = AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        _ = AXUIElementSetAttributeValue(app, kAXFocusedUIElementAttribute as CFString, element)
    }

    private func clickCenter(of element: AXUIElement) -> Bool {
        guard let frame = axFrame(element), frame.size.width > 0, frame.size.height > 0 else { return false }
        let point = CGPoint(x: frame.origin.x + frame.size.width / 2,
                            y: frame.origin.y + frame.size.height / 2)
        let previous = CGEvent(source: nil)?.location ?? point
        guard let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown,
                                 mouseCursorPosition: point, mouseButton: .left),
              let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp,
                               mouseCursorPosition: point, mouseButton: .left) else { return false }
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                mouseCursorPosition: previous, mouseButton: .left)?.post(tap: .cghidEventTap)
        return true
    }

    private func axElements(_ element: AXUIElement, attribute: String) -> [AXUIElement] {
        guard let raw = axAttribute(element, attribute: attribute) else { return [] }
        if CFGetTypeID(raw) == AXUIElementGetTypeID() {
            return [unsafeBitCast(raw, to: AXUIElement.self)]
        }
        guard let values = raw as? [Any] else { return [] }
        return values.compactMap { value in
            let raw = value as CFTypeRef
            guard CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
            return unsafeBitCast(raw, to: AXUIElement.self)
        }
    }

    private func axFrame(_ element: AXUIElement) -> CGRect? {
        guard let positionRaw = axAttribute(element, attribute: kAXPositionAttribute),
              let sizeRaw = axAttribute(element, attribute: kAXSizeAttribute),
              CFGetTypeID(positionRaw) == AXValueGetTypeID(),
              CFGetTypeID(sizeRaw) == AXValueGetTypeID() else { return nil }
        let positionValue = unsafeBitCast(positionRaw, to: AXValue.self)
        let sizeValue = unsafeBitCast(sizeRaw, to: AXValue.self)
        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue, .cgPoint, &position),
              AXValueGetValue(sizeValue, .cgSize, &size) else { return nil }
        return CGRect(origin: position, size: size)
    }

    private func axElement(_ element: AXUIElement, attribute: String) -> AXUIElement? {
        guard let raw = axAttribute(element, attribute: attribute),
              CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
        return unsafeBitCast(raw, to: AXUIElement.self)
    }

    private func axString(_ element: AXUIElement, attribute: String) -> String? {
        axAttribute(element, attribute: attribute) as? String
    }

    private func axStrings(_ element: AXUIElement, attribute: String) -> [String] {
        if let value = axAttribute(element, attribute: attribute) as? String {
            return [value]
        }
        return axAttribute(element, attribute: attribute) as? [String] ?? []
    }

    private func axBool(_ element: AXUIElement, attribute: String) -> Bool? {
        axAttribute(element, attribute: attribute) as? Bool
    }

    private func axAttribute(_ element: AXUIElement, attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return value
    }

    private func apply(_ snapshot: WorkBuddySnapshot,
                       liveWorkerIDs: Set<String>?,
                       now: Date) {
        let previousCount = sessions.count
        let previousCredits = credits
        let previousLeaseStates = leaseStates
        var mapped: [String: HookSession] = [:]
        var nextLeaseStates: [String: WorkBuddyLeaseState] = [:]
        var nextWorkingSessionIDs: Set<String> = []
        let knownSessionIDs = Set(snapshot.sessions.map(\.id))
        leaseTracker.retain(sessionIDs: knownSessionIDs)
        for record in snapshot.sessions {
            let rawWorking = Self.isWorkingStatus(record.status)
            let transcriptProgress = transcriptWatches[record.id]?.lastContentChangeAt ?? .distantPast
            let lastProgressAt = max(record.lastActivity, transcriptProgress)
            let workerAlive = record.transport.lowercased() == "local"
                ? liveWorkerIDs.map { $0.contains(record.id.lowercased()) }
                : nil
            let shouldTrackActivity = WorkBuddyEffectiveActivityPolicy.shouldTrack(
                databaseWorking: rawWorking,
                transport: record.transport,
                workerAlive: workerAlive,
                lastProgressAt: lastProgressAt,
                now: now
            )
            let lease = leaseTracker.evaluate(
                sessionID: record.id,
                rawWorking: shouldTrackActivity,
                workerAlive: workerAlive,
                lastProgressAt: lastProgressAt,
                now: now
            )
            nextLeaseStates[record.id] = lease
            if shouldTrackActivity, lease.isDeviceActive {
                nextWorkingSessionIDs.insert(record.id)
            }
            let key = "workbuddy:\(record.id)"
            var transcript = TranscriptSnapshot(
                model: record.model,
                contextPromptTokens: record.contextUsed,
                contextLimitTokens: record.contextLimit,
                gitBranch: nil,
                cliVersion: nil,
                customTitle: record.title,
                activeSubagent: nil,
                serviceTier: nil,
                entrypoint: record.projectID == nil ? "workbuddy" : "workbuddy-project",
                lastPromptText: nil,
                firstTimestamp: record.createdAt,
                lastTimestamp: record.lastActivity,
                transcriptMtime: record.lastActivity
            )
            transcript.totalCostUSD = nil
            var session = HookSession(
                id: key,
                cwd: record.cwd,
                phase: Self.phase(for: record.status),
                pid: nil,
                tty: nil,
                lastTool: nil,
                lastActivity: record.lastActivity,
                name: record.title
            )
            session.transcriptPath = record.transcriptPath
            session.transcriptSnapshot = transcript
            session.agentId = "workbuddy"
            session.agentType = record.projectID == nil ? "task" : "project"
            if shouldTrackActivity, lease.isDeviceActive {
                Self.applyActivity(transcriptWatches[record.id]?.tracker.state, to: &session)
            } else if shouldTrackActivity {
                session.phase = .idle
                session.modelInferring = false
            }
            if let approval = approvalServer?.pendingEntry(
                sessionID: record.id, transcriptPath: record.transcriptPath
            ) {
                session.phase = .waitingForApproval(approval.context)
                session.modelInferring = false
            }
            mapped[key] = session
        }
        emitLifecycleEvents(for: snapshot.sessions)
        emitLeaseLifecycleEvents(
            for: snapshot.sessions,
            previous: previousLeaseStates,
            current: nextLeaseStates,
            now: now
        )
        leaseStates = nextLeaseStates
        workingSessionIDs = nextWorkingSessionIDs
        sessions = mapped
        syncTranscriptWatches(with: snapshot.sessions)
        credits = snapshot.credits
        lastError = nil
        isRefreshing = false
        if previousCount != mapped.count || previousCredits != snapshot.credits {
            let today = snapshot.credits.todayCredits.map { String(format: "%.2f", $0) } ?? "--"
            ClaudeCodeSessionManager.log(
                "[WorkBuddy] refreshed sessions=\(mapped.count) today=\(today) " +
                "historical=\(String(format: "%.2f", snapshot.credits.historicalCredits))"
            )
        }
    }

    private func emitLeaseLifecycleEvents(for records: [WorkBuddySessionRecord],
                                          previous: [String: WorkBuddyLeaseState],
                                          current: [String: WorkBuddyLeaseState],
                                          now: Date) {
        let recordsByID = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
        for (sessionID, state) in current {
            guard let oldState = previous[sessionID], oldState != state,
                  recordsByID[sessionID] != nil else { continue }

            guard let leaseEvent = WorkBuddyLeaseTransition.event(
                previous: oldState, current: state
            ) else { continue }
            let outcome: TaskLifecycleOutcome = leaseEvent == .started ? .started : .cancelled
            ClaudeCodeSessionManager.log(
                "[WorkBuddy] lease lifecycle id=\(sessionID) \(oldState)->\(state) outcome=\(outcome)"
            )
            onTaskLifecycleEvent?(TaskLifecycleSignal(
                provider: .workbuddy,
                sessionID: "workbuddy:\(sessionID)",
                turnID: "workbuddy-lease-\(Int64(now.timeIntervalSince1970 * 1_000))",
                outcome: outcome
            ))
        }
    }

    private func emitLifecycleEvents(for records: [WorkBuddySessionRecord]) {
        let currentStatuses = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0.status) })
        defer { observedStatuses = currentStatuses }

        // The first database read is baseline state. Never replay sounds for
        // tasks that started or completed while QuickVibeHost was not running.
        guard let previousStatuses = observedStatuses else { return }
        for record in records {
            guard let previousStatus = previousStatuses[record.id],
                  let outcome = WorkBuddyLifecycleMapper.outcome(
                    previousStatus: previousStatus,
                    currentStatus: record.status
                  ) else { continue }
            let revision = Int64(record.lastActivity.timeIntervalSince1970 * 1_000)
            ClaudeCodeSessionManager.log(
                "[WorkBuddy] lifecycle id=\(record.id) \(previousStatus)->\(record.status) outcome=\(outcome)"
            )
            onTaskLifecycleEvent?(TaskLifecycleSignal(
                provider: .workbuddy,
                sessionID: "workbuddy:\(record.id)",
                turnID: "workbuddy-\(revision)",
                outcome: outcome
            ))
        }
    }

    private func record(_ error: Error) {
        lastError = error.localizedDescription
        isRefreshing = false
        ClaudeCodeSessionManager.log("[WorkBuddy] refresh failed: \(error.localizedDescription)")
    }

    private static func phase(for status: String) -> SessionPhase {
        switch status.lowercased() {
        case "working", "running", "processing": return .processing
        case "waiting", "waiting_for_input", "awaiting_input", "needs_input":
            return .waitingForInput
        case "completed", "done", "success": return .idle
        case "terminated", "cancelled", "canceled", "failed": return .ended
        default: return .idle
        }
    }

    private static func isWorkingStatus(_ status: String) -> Bool {
        ["working", "running", "processing"].contains(
            status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        )
    }

    private static func applyActivity(_ activity: WorkBuddyActivityState?,
                                      to session: inout HookSession) {
        switch activity {
        case .thinking:
            session.phase = .processing
            session.modelInferring = true
        case .toolRunning:
            session.phase = .processing
            session.modelInferring = false
        case .waitingForInput:
            session.phase = .waitingForInput
            session.modelInferring = false
        case .idle:
            session.phase = .idle
            session.modelInferring = false
        case nil:
            // Private transcript formats may change. The durable database
            // status still gives a safe coarse "active" fallback.
            session.phase = .processing
            session.modelInferring = false
        }
    }

    private func syncTranscriptWatches(with records: [WorkBuddySessionRecord]) {
        let recordsByID = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
        let candidates = records.map { record in
            WorkBuddyWatchCandidate(
                id: record.id,
                rawWorking: workingSessionIDs.contains(record.id),
                lease: leaseStates[record.id] ?? .unknown,
                lastActivity: max(
                    record.lastActivity,
                    transcriptWatches[record.id]?.lastContentChangeAt ?? .distantPast
                )
            )
        }
        let desiredIDs = WorkBuddyTranscriptWatchPolicy.desiredSessionIDs(from: candidates)
        let desired: [String: String] = Dictionary(
            uniqueKeysWithValues: desiredIDs.compactMap { sessionID -> (String, String)? in
                guard let record = recordsByID[sessionID],
                      let path = record.transcriptPath else { return nil }
                return (sessionID, path)
            }
        )
        desiredTranscriptPaths = desired

        let invalidWatchIDs = transcriptWatches.compactMap { sessionID, watch -> String? in
            guard desired[sessionID] == watch.path,
                  let attributes = try? FileManager.default.attributesOfItem(atPath: watch.path)
            else { return sessionID }
            let currentFileID = Self.fileID(from: attributes)
            let currentSize = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
            return WorkBuddyTranscriptFilePolicy.shouldReset(
                previousFileID: watch.fileID,
                currentFileID: currentFileID,
                previousOffset: watch.offset,
                currentSize: currentSize
            ) ? sessionID : nil
        }
        for sessionID in invalidWatchIDs {
            removeTranscriptWatch(sessionID: sessionID)
        }
        for (sessionID, path) in desired where transcriptWatches[sessionID] == nil {
            addTranscriptWatch(sessionID: sessionID, path: path)
        }
    }

    private func addTranscriptWatch(sessionID: String, path: String) {
        guard desiredTranscriptPaths[sessionID] == path,
              transcriptWatches[sessionID] == nil else { return }
        let descriptor = open(path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .extend, .attrib, .rename, .delete, .revoke],
            queue: DispatchQueue.global(qos: .utility)
        )
        let watch = TranscriptWatch(
            sessionID: sessionID, path: path, descriptor: descriptor, source: source
        )
        if let attributes = try? FileManager.default.attributesOfItem(atPath: path),
           let modified = attributes[.modificationDate] as? Date {
            watch.lastContentChangeAt = modified
            watch.fileID = Self.fileID(from: attributes)
        }
        source.setEventHandler { [weak self, weak watch] in
            guard let watch else { return }
            let flags = watch.source.data
            Task { @MainActor [weak self] in
                self?.handleTranscriptEvent(sessionID: sessionID, path: path, flags: flags)
            }
        }
        source.setCancelHandler { close(descriptor) }
        transcriptWatches[sessionID] = watch
        source.resume()
        // Parse the existing file once so a monitor started in the middle of a
        // turn immediately reflects whether WorkBuddy is thinking or in a tool.
        readTranscriptChanges(sessionID: sessionID)
    }

    private func removeTranscriptWatch(sessionID: String) {
        transcriptDebounceTasks.removeValue(forKey: sessionID)?.cancel()
        transcriptWatches.removeValue(forKey: sessionID)?.source.cancel()
    }

    private func handleTranscriptEvent(sessionID: String, path: String,
                                       flags: DispatchSource.FileSystemEvent) {
        if flags.contains(.delete) || flags.contains(.rename) || flags.contains(.revoke) {
            removeTranscriptWatch(sessionID: sessionID)
            scheduleTranscriptRebuild(sessionID: sessionID, path: path)
            return
        }
        scheduleTranscriptRead(sessionID: sessionID)
    }

    private func scheduleTranscriptRebuild(sessionID: String, path: String) {
        transcriptRebuildTasks.removeValue(forKey: sessionID)?.cancel()
        transcriptRebuildTasks[sessionID] = Task { [weak self] in
            defer { self?.transcriptRebuildTasks.removeValue(forKey: sessionID) }
            let delays: [UInt64] = [150_000_000, 350_000_000, 750_000_000]
            for delay in delays {
                try? await Task.sleep(nanoseconds: delay)
                guard !Task.isCancelled, let self,
                      self.desiredTranscriptPaths[sessionID] == path else { return }
                if self.transcriptWatches[sessionID] != nil { return }
                self.addTranscriptWatch(sessionID: sessionID, path: path)
                if self.transcriptWatches[sessionID] != nil { return }
            }
        }
    }

    private func scheduleTranscriptRead(sessionID: String) {
        transcriptDebounceTasks.removeValue(forKey: sessionID)?.cancel()
        transcriptDebounceTasks[sessionID] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard !Task.isCancelled else { return }
            self?.transcriptDebounceTasks.removeValue(forKey: sessionID)
            self?.readTranscriptChanges(sessionID: sessionID)
        }
    }

    private func readTranscriptChanges(sessionID: String) {
        guard let watch = transcriptWatches[sessionID] else { return }
        guard !watch.readInFlight else {
            watch.needsAnotherRead = true
            return
        }
        watch.readInFlight = true
        let path = watch.path
        let previousOffset = watch.offset
        let previousRemainder = watch.remainder
        let previousTracker = watch.tracker
        let previousFileID = watch.fileID

        Task { [weak self] in
            let result = await Task.detached(priority: .utility) {
                Result<TranscriptReadResult, Error> {
                    let attributes = try FileManager.default.attributesOfItem(atPath: path)
                    let fileSize = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
                    let currentFileID = Self.fileID(from: attributes)
                    let reset = WorkBuddyTranscriptFilePolicy.shouldReset(
                        previousFileID: previousFileID,
                        currentFileID: currentFileID,
                        previousOffset: previousOffset,
                        currentSize: fileSize
                    )
                    let startOffset: UInt64 = reset ? 0 : previousOffset
                    let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
                    defer { try? handle.close() }
                    try handle.seek(toOffset: startOffset)
                    let appended = try handle.readToEnd() ?? Data()

                    var tracker = previousTracker
                    if reset { tracker.reset() }
                    let parsed = WorkBuddyTranscriptFilePolicy.consumeCompleteLines(
                        appended: appended,
                        previousRemainder: reset ? Data() : previousRemainder,
                        tracker: tracker
                    )
                    return TranscriptReadResult(
                        offset: startOffset + UInt64(appended.count),
                        remainder: parsed.remainder,
                        tracker: parsed.tracker,
                        fileID: currentFileID,
                        identityChanged: reset && previousFileID != nil
                            && currentFileID != previousFileID,
                        modifiedAt: attributes[.modificationDate] as? Date
                    )
                }
            }.value
            guard let self, let current = self.transcriptWatches[sessionID],
                  current === watch else { return }
            current.readInFlight = false
            switch result {
            case .success(let update):
                if update.offset > current.offset {
                    current.lastContentChangeAt = update.modifiedAt ?? .now
                }
                current.offset = update.offset
                current.remainder = update.remainder
                current.fileID = update.fileID
                let previousActivity = current.tracker.state
                let changed = previousActivity != update.tracker.state
                current.tracker = update.tracker
                if changed {
                    if let previousActivity, let nextActivity = update.tracker.state {
                        self.emitTranscriptLifecycleEvent(
                            sessionID: sessionID,
                            previous: previousActivity,
                            current: nextActivity,
                            revision: update.modifiedAt ?? .now
                        )
                    }
                    self.applyTranscriptActivity(sessionID: sessionID)
                }
                if self.leaseStates[sessionID] == .stale {
                    self.scheduleDebouncedRefresh()
                }
                if update.identityChanged {
                    self.removeTranscriptWatch(sessionID: sessionID)
                    self.scheduleTranscriptRebuild(sessionID: sessionID, path: path)
                    return
                }
            case .failure(let error):
                ClaudeCodeSessionManager.log(
                    "[WorkBuddy] transcript read failed id=\(sessionID): \(error.localizedDescription)"
                )
                self.removeTranscriptWatch(sessionID: sessionID)
                self.scheduleTranscriptRebuild(sessionID: sessionID, path: path)
                self.scheduleDebouncedRefresh()
            }
            if current.needsAnotherRead {
                current.needsAnotherRead = false
                self.readTranscriptChanges(sessionID: sessionID)
            }
        }
    }

    private func applyTranscriptActivity(sessionID: String) {
        guard workingSessionIDs.contains(sessionID),
              let activity = transcriptWatches[sessionID]?.tracker.state,
              var session = sessions["workbuddy:\(sessionID)"] else { return }
        let previousPhase = session.phase
        let previousInferring = session.modelInferring
        Self.applyActivity(activity, to: &session)
        guard session.phase != previousPhase || session.modelInferring != previousInferring else { return }
        sessions[session.id] = session
        ClaudeCodeSessionManager.log(
            "[WorkBuddy] activity id=\(sessionID) state=\(activity)"
        )
    }

    private func emitTranscriptLifecycleEvent(sessionID: String,
                                              previous: WorkBuddyActivityState,
                                              current: WorkBuddyActivityState,
                                              revision: Date) {
        guard let transcriptEvent = WorkBuddyTranscriptLifecycleMapper.outcome(
            previous: previous, current: current
        ) else { return }
        let outcome: TaskLifecycleOutcome = transcriptEvent == .started ? .started : .completed
        let revisionMilliseconds = Int64(revision.timeIntervalSince1970 * 1_000)
        ClaudeCodeSessionManager.log(
            "[WorkBuddy] transcript lifecycle id=\(sessionID) " +
            "\(previous)->\(current) outcome=\(outcome)"
        )
        onTaskLifecycleEvent?(TaskLifecycleSignal(
            provider: .workbuddy,
            sessionID: "workbuddy:\(sessionID)",
            turnID: "workbuddy-transcript-\(revisionMilliseconds)",
            outcome: outcome
        ))
    }

    private func partitioned() -> (active: [HookSession], inactive: [HookSession]) {
        let now = Date()
        var items: [(item: HookSession, facts: LivenessFacts, tier: SessionTier)] = []
        for session in sessions.values {
            let facts = LivenessFacts(
                lastActivity: session.lastActivity,
                startedAt: session.transcriptSnapshot?.firstTimestamp,
                phasePriority: SessionPhaseRank.priority(session.phase),
                attached: false,
                approvalPending: session.phase.isWaitingForApproval
            )
            guard var tier = SessionTierClassifier.tier(facts, now: now) else { continue }
            // WorkBuddy persists an explicit terminal status. Do not let a recent
            // timestamp promote a completed/failed task back into the active group.
            if session.phase == .ended { tier = .detached }
            let rawID = session.id.hasPrefix("workbuddy:")
                ? String(session.id.dropFirst("workbuddy:".count)) : session.id
            if let lease = leaseStates[rawID], lease == .orphaned || lease == .stale {
                tier = .detached
            }
            items.append((session, facts, tier))
        }
        return SessionGrouping.group(items, inactiveCap: SessionLivenessParams.appInactiveCap)
    }

    private func watchDirectory() {
        let path = WorkBuddyDataSource.defaultDatabaseURL.deletingLastPathComponent().path
        let descriptor = open(path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        directoryDescriptor = descriptor
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .extend, .rename],
            queue: DispatchQueue.global(qos: .utility)
        )
        source.setEventHandler { [weak self] in
            Task { @MainActor [weak self] in
                self?.syncDatabaseWatches()
                self?.scheduleDebouncedRefresh()
            }
        }
        source.setCancelHandler { close(descriptor) }
        directorySource = source
        source.resume()
    }

    private func syncDatabaseWatches() {
        let databasePath = WorkBuddyDataSource.defaultDatabaseURL.path
        let desiredPaths = Set([databasePath, databasePath + "-wal"])
        let invalidPaths = databaseWatches.compactMap { path, watch -> String? in
            let attributes = try? FileManager.default.attributesOfItem(atPath: path)
            let currentFileID = attributes.flatMap { Self.fileID(from: $0) }
            if !desiredPaths.contains(path) || attributes == nil || currentFileID != watch.fileID {
                return path
            }
            return nil
        }
        for path in invalidPaths {
            removeDatabaseWatch(path: path)
        }
        for path in desiredPaths where databaseWatches[path] == nil {
            addDatabaseWatch(path: path)
        }
    }

    private func addDatabaseWatch(path: String) {
        let descriptor = open(path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .extend, .attrib, .rename, .delete, .revoke],
            queue: DispatchQueue.global(qos: .utility)
        )
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        let watch = DatabaseWatch(
            path: path,
            descriptor: descriptor,
            source: source,
            fileID: attributes.flatMap { Self.fileID(from: $0) }
        )
        source.setEventHandler { [weak self, weak watch] in
            guard let watch else { return }
            let flags = watch.source.data
            Task { @MainActor [weak self] in
                self?.handleDatabaseEvent(path: watch.path, flags: flags)
            }
        }
        source.setCancelHandler { close(descriptor) }
        databaseWatches[path] = watch
        source.resume()
    }

    private func removeDatabaseWatch(path: String) {
        databaseWatches.removeValue(forKey: path)?.source.cancel()
    }

    private func handleDatabaseEvent(path: String,
                                     flags: DispatchSource.FileSystemEvent) {
        if flags.contains(.delete) || flags.contains(.rename) || flags.contains(.revoke) {
            removeDatabaseWatch(path: path)
            scheduleDatabaseWatchRetry()
        }
        scheduleDebouncedRefresh()
    }

    private func scheduleDatabaseWatchRetry() {
        databaseWatchRetryTask?.cancel()
        databaseWatchRetryTask = Task { [weak self] in
            let delays: [UInt64] = [150_000_000, 350_000_000, 750_000_000]
            for delay in delays {
                try? await Task.sleep(nanoseconds: delay)
                guard !Task.isCancelled, let self else { return }
                self.syncDatabaseWatches()
            }
            self?.databaseWatchRetryTask = nil
        }
    }

    private func scheduleDebouncedRefresh() {
        debounceWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in self?.refresh() }
        }
        debounceWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    nonisolated private static func fileID(from attributes: [FileAttributeKey: Any]) -> UInt64? {
        (attributes[.systemFileNumber] as? NSNumber)?.uint64Value
    }

    nonisolated private static func liveWorkerSessionIDs() -> Set<String>? {
        guard let pidResult = runProcess(
            "/usr/bin/pgrep", ["-f", "/cli/bin/codebuddy --serve"]
        ) else {
            return nil
        }
        // pgrep uses exit 1 for a successful query with no matching process.
        if pidResult.status == 1 { return [] }
        guard pidResult.status == 0 else { return nil }

        var sessionIDs: Set<String> = []
        for pid in pidResult.output.split(whereSeparator: \Character.isWhitespace) {
            guard Int32(pid) != nil,
                  let command = runProcess("/bin/ps", ["-p", String(pid), "-o", "args="]),
                  command.status == 0 else {
                // A worker can exit between pgrep and ps. Treat the whole probe
                // as unknown so that race cannot prematurely expire a lease.
                return nil
            }
            sessionIDs.formUnion(WorkBuddyWorkerCommandParser.sessionIDs(from: command.output))
        }
        return sessionIDs
    }

    nonisolated private static func runProcess(_ executable: String,
                                               _ arguments: [String])
        -> (status: Int32, output: String)? {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard let text = String(data: data, encoding: .utf8) else { return nil }
            return (process.terminationStatus, text)
        } catch {
            return nil
        }
    }
}
