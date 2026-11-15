import Darwin
import Foundation

/// A rollout can be left at a running event when Codex or its host exits
/// before writing `task_complete`/`turn_aborted`. Keep session discovery and
/// turn presentation separate: a stale turn becomes ready, while the session
/// itself may remain visible/attached and can immediately resume on new bytes.
enum CodexTurnLeasePolicy {
    static let productionTimeout: TimeInterval = 30 * 60

    static func shouldExpire(isRunning: Bool,
                             lastProgressAt: Date,
                             now: Date,
                             timeout: TimeInterval = productionTimeout) -> Bool {
        isRunning && now.timeIntervalSince(lastProgressAt) >= timeout
    }
}

/// Incrementally maintains the same bounded JSONL tail that the rollout parser
/// previously rebuilt from disk on every poll. Only bytes appended after the
/// last observed file offset are read during the steady state.
final class CodexJSONLTailReader {
    struct Snapshot {
        let completeTail: Data
        let bytesRead: Int
        let reset: Bool
        let hasNewCompleteLine: Bool
        /// Complete rows produced only by this incremental append. Empty for
        /// initial seed/truncate/replacement so historical events never replay.
        let newCompleteLines: Data
    }

    private struct FileIdentity: Equatable {
        let device: UInt64
        let inode: UInt64
    }

    private struct Cursor {
        var identity: FileIdentity
        var offset: UInt64
        var completeTail: Data
        var partialLine: Data
        var discardingOversizedLine: Bool
    }

    private let maxTailBytes: Int
    private var cursors: [String: Cursor] = [:]

    init(maxTailBytes: Int = 256 * 1024) {
        self.maxTailBytes = max(1, maxTailBytes)
    }

    func refresh(path: String) -> Snapshot? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let sizeNumber = attributes[.size] as? NSNumber,
              let inodeNumber = attributes[.systemFileNumber] as? NSNumber,
              let deviceNumber = attributes[.systemNumber] as? NSNumber else { return nil }

        let size = sizeNumber.uint64Value
        let identity = FileIdentity(device: deviceNumber.uint64Value, inode: inodeNumber.uint64Value)
        if var cursor = cursors[path], cursor.identity == identity, size >= cursor.offset {
            guard size > cursor.offset else {
                return Snapshot(completeTail: cursor.completeTail, bytesRead: 0,
                                reset: false, hasNewCompleteLine: false,
                                newCompleteLines: Data())
            }
            guard let appended = Self.read(path: path, offset: cursor.offset, count: size - cursor.offset) else {
                return nil
            }
            cursor.offset += UInt64(appended.count)
            let completed = Self.append(appended, to: &cursor, maxTailBytes: maxTailBytes)
            cursors[path] = cursor
            return Snapshot(completeTail: cursor.completeTail, bytesRead: appended.count,
                            reset: false, hasNewCompleteLine: !completed.isEmpty,
                            newCompleteLines: completed)
        }

        // New, replaced or truncated file. Seed from a bounded tail and discard
        // the first fragment when the read begins in the middle of a JSONL row.
        let start = size > UInt64(maxTailBytes) ? size - UInt64(maxTailBytes) : 0
        guard var seed = Self.read(path: path, offset: start, count: size - start) else { return nil }
        if start > 0 {
            guard let newline = seed.firstIndex(of: 0x0A) else {
                let cursor = Cursor(identity: identity, offset: size,
                                    completeTail: Data(), partialLine: Data(),
                                    discardingOversizedLine: true)
                cursors[path] = cursor
                return Snapshot(completeTail: Data(), bytesRead: seed.count,
                                reset: true, hasNewCompleteLine: false,
                                newCompleteLines: Data())
            }
            seed.removeSubrange(seed.startIndex...newline)
        }
        var cursor = Cursor(identity: identity, offset: size,
                            completeTail: Data(), partialLine: Data(),
                            discardingOversizedLine: false)
        _ = Self.append(seed, to: &cursor, maxTailBytes: maxTailBytes)
        cursors[path] = cursor
        return Snapshot(completeTail: cursor.completeTail, bytesRead: seed.count,
                        reset: true, hasNewCompleteLine: false,
                        newCompleteLines: Data())
    }

    func retain(paths: Set<String>) {
        cursors = cursors.filter { paths.contains($0.key) }
    }

    func remove(path: String) {
        cursors.removeValue(forKey: path)
    }

    private static func read(path: String, offset: UInt64, count: UInt64) -> Data? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: offset)
            return try handle.read(upToCount: Int(min(count, UInt64(Int.max)))) ?? Data()
        } catch {
            return nil
        }
    }

    private static func append(_ data: Data, to cursor: inout Cursor,
                               maxTailBytes: Int) -> Data {
        guard !data.isEmpty else { return Data() }
        var incoming = data
        if cursor.discardingOversizedLine {
            guard let newline = incoming.firstIndex(of: 0x0A) else { return Data() }
            incoming.removeSubrange(incoming.startIndex...newline)
            cursor.discardingOversizedLine = false
            guard !incoming.isEmpty else { return Data() }
        }
        var combined = cursor.partialLine
        combined.append(incoming)
        guard let lastNewline = combined.lastIndex(of: 0x0A) else {
            if combined.count > maxTailBytes {
                cursor.partialLine.removeAll(keepingCapacity: true)
                cursor.discardingOversizedLine = true
            } else {
                cursor.partialLine = combined
            }
            return Data()
        }

        let completeEnd = combined.index(after: lastNewline)
        let completed = Data(combined[..<completeEnd])
        cursor.completeTail.append(completed)
        cursor.partialLine = Data(combined[completeEnd...])
        trimCompleteTail(&cursor.completeTail, maxBytes: maxTailBytes)
        return completed
    }

    private static func trimCompleteTail(_ data: inout Data, maxBytes: Int) {
        guard data.count > maxBytes else { return }
        let desiredStart = data.index(data.endIndex, offsetBy: -maxBytes)
        if let newline = data[desiredStart...].firstIndex(of: 0x0A) {
            data.removeSubrange(data.startIndex...newline)
        } else {
            data.removeAll(keepingCapacity: true)
        }
    }
}

/// Watches the Codex sessions directory tree and the currently relevant
/// rollout files. Directory sources discover new date folders/files; file
/// sources provide low-latency append events. Events are coalesced before the
/// monitor is called, while its periodic scan remains the loss-event fallback.
final class CodexRolloutEventMonitor {
    struct ChangeBatch {
        let rolloutPaths: Set<String>
        let needsDiscoveryScan: Bool
        let titleIndexChanged: Bool
    }

    typealias Handler = (ChangeBatch) -> Void

    private let rootPath: String
    private let titleIndexPath: String
    private let debounceInterval: TimeInterval
    private let queue: DispatchQueue
    private let handler: Handler
    private var directorySources: [String: DispatchSourceFileSystemObject] = [:]
    private var rolloutSources: [String: DispatchSourceFileSystemObject] = [:]
    private var desiredRolloutPaths: Set<String> = []
    private var titleIndexSource: DispatchSourceFileSystemObject?
    private var titleParentSource: DispatchSourceFileSystemObject?
    private var pendingPaths: Set<String> = []
    private var pendingDiscovery = false
    private var pendingTitleIndex = false
    private var debounceWorkItem: DispatchWorkItem?
    private var stopped = false

    init(rootPath: String, titleIndexPath: String,
         debounceInterval: TimeInterval = 0.1,
         queue: DispatchQueue = DispatchQueue(label: "com.vibeeverything.codex-rollout-events",
                                              qos: .utility),
         handler: @escaping Handler) {
        self.rootPath = rootPath
        self.titleIndexPath = titleIndexPath
        self.debounceInterval = debounceInterval
        self.queue = queue
        self.handler = handler
    }

    func start() {
        queue.async { [weak self] in
            guard let self, !self.stopped else { return }
            self.reconcileDirectorySources()
            self.reconcileTitleParentSource()
            self.reconcileTitleIndexSource()
        }
    }

    func updateRolloutPaths(_ paths: Set<String>) {
        queue.async { [weak self] in
            guard let self, !self.stopped else { return }
            self.desiredRolloutPaths = paths
            for path in Array(self.rolloutSources.keys) where !paths.contains(path) {
                self.rolloutSources.removeValue(forKey: path)?.cancel()
            }
            for path in paths where self.rolloutSources[path] == nil {
                self.rolloutSources[path] = self.makeSource(
                    path: path,
                    mask: [.write, .extend, .rename, .delete, .revoke]
                ) { [weak self] flags in
                    guard let self else { return }
                    self.pendingPaths.insert(path)
                    if !flags.intersection([.rename, .delete, .revoke]).isEmpty {
                        self.pendingDiscovery = true
                        self.rolloutSources.removeValue(forKey: path)?.cancel()
                    }
                    self.scheduleDelivery()
                }
            }
            self.reconcileDirectorySources()
        }
    }

    func stop() {
        queue.async { [self] in
            guard !stopped else { return }
            self.stopped = true
            self.debounceWorkItem?.cancel()
            self.debounceWorkItem = nil
            for source in self.directorySources.values { source.cancel() }
            for source in self.rolloutSources.values { source.cancel() }
            self.titleIndexSource?.cancel()
            self.titleParentSource?.cancel()
            self.directorySources.removeAll()
            self.rolloutSources.removeAll()
            self.titleIndexSource = nil
            self.titleParentSource = nil
        }
    }

    private func reconcileDirectorySources() {
        let fm = FileManager.default
        var wanted: Set<String> = [rootPath]
        let recentCutoff = Date().addingTimeInterval(-48 * 3600)
        let rolloutParents = Set(desiredRolloutPaths.map {
            ($0 as NSString).deletingLastPathComponent
        })
        var isDirectory: ObjCBool = false
        if fm.fileExists(atPath: rootPath, isDirectory: &isDirectory), isDirectory.boolValue {
            if let enumerator = fm.enumerator(atPath: rootPath) {
                for case let relative as String in enumerator {
                    let path = (rootPath as NSString).appendingPathComponent(relative)
                    var childIsDirectory: ObjCBool = false
                    if fm.fileExists(atPath: path, isDirectory: &childIsDirectory), childIsDirectory.boolValue {
                        let attributes = try? fm.attributesOfItem(atPath: path)
                        let modified = attributes?[.modificationDate] as? Date
                        if rolloutParents.contains(path) || (modified ?? .distantPast) >= recentCutoff {
                            wanted.insert(path)
                            var parent = (path as NSString).deletingLastPathComponent
                            while parent.hasPrefix(rootPath), parent != rootPath {
                                wanted.insert(parent)
                                parent = (parent as NSString).deletingLastPathComponent
                            }
                        }
                    }
                }
            }
        } else {
            wanted.remove(rootPath)
        }

        for path in Array(directorySources.keys) where !wanted.contains(path) {
            directorySources.removeValue(forKey: path)?.cancel()
        }
        for path in wanted where directorySources[path] == nil {
            directorySources[path] = makeSource(
                path: path,
                mask: [.write, .rename, .delete, .revoke]
            ) { [weak self] _ in
                guard let self else { return }
                self.pendingDiscovery = true
                self.reconcileDirectorySources()
                if self.titleIndexSource == nil {
                    self.reconcileTitleIndexSource()
                }
                self.scheduleDelivery()
            }
        }
    }

    private func reconcileTitleIndexSource() {
        titleIndexSource?.cancel()
        titleIndexSource = makeSource(
            path: titleIndexPath,
            mask: [.write, .extend, .rename, .delete, .revoke]
        ) { [weak self] flags in
            guard let self else { return }
            self.pendingTitleIndex = true
            if !flags.intersection([.rename, .delete, .revoke]).isEmpty {
                self.reconcileTitleIndexSource()
            }
            self.scheduleDelivery()
        }
    }

    private func reconcileTitleParentSource() {
        guard titleParentSource == nil else { return }
        let parent = (titleIndexPath as NSString).deletingLastPathComponent
        titleParentSource = makeSource(path: parent, mask: [.write, .rename, .delete, .revoke]) {
            [weak self] flags in
            guard let self else { return }
            if self.titleIndexSource == nil,
               FileManager.default.fileExists(atPath: self.titleIndexPath) {
                self.reconcileTitleIndexSource()
                self.pendingTitleIndex = true
                self.scheduleDelivery()
            }
            if !flags.intersection([.rename, .delete, .revoke]).isEmpty {
                self.titleParentSource?.cancel()
                self.titleParentSource = nil
                self.reconcileTitleParentSource()
            }
        }
    }

    private func makeSource(path: String, mask: DispatchSource.FileSystemEvent,
                            event: @escaping (DispatchSource.FileSystemEvent) -> Void)
        -> DispatchSourceFileSystemObject? {
        let descriptor = open(path, O_EVTONLY)
        guard descriptor >= 0 else { return nil }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: mask,
            queue: queue
        )
        source.setEventHandler { event(source.data) }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        return source
    }

    private func scheduleDelivery() {
        debounceWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.stopped else { return }
            let batch = ChangeBatch(rolloutPaths: self.pendingPaths,
                                    needsDiscoveryScan: self.pendingDiscovery,
                                    titleIndexChanged: self.pendingTitleIndex)
            self.pendingPaths.removeAll()
            self.pendingDiscovery = false
            self.pendingTitleIndex = false
            self.debounceWorkItem = nil
            self.handler(batch)
        }
        debounceWorkItem = work
        queue.asyncAfter(deadline: .now() + debounceInterval, execute: work)
    }
}
