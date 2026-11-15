import Foundation
import Darwin
import os

private let workBuddyApprovalLogger = Logger(
    subsystem: "com.vibeeverything.QuickVibeHost",
    category: "WorkBuddyApproval"
)

enum WorkBuddyApprovalFeature {
    static let enabledKey = "workBuddyDeviceApprovalEnabled"
}

/// Pure settings merge helpers. WorkBuddy snapshots plugin configuration when
/// its agent runtime starts, so approval is registered as a formal local
/// marketplace plugin rather than as a raw user hook.
enum WorkBuddyPluginConfiguration {
    enum ConfigurationError: LocalizedError {
        case invalidField(String)

        var errorDescription: String? {
            switch self {
            case .invalidField(let field):
                return "WorkBuddy settings.json field '\(field)' has an unexpected type; it was left unchanged"
            }
        }
    }

    static let scriptName = "quickvibehost-workbuddy-approval.py"
    static let marketplaceID = "quickvibehost-approval"
    static let pluginID = "quickvibehost-approval@quickvibehost-approval"
    private static let legacyMarketplaceID = "quickvibehost-approval-poc"
    private static let legacyPluginID = "quickvibehost-approval-poc@quickvibehost-approval-poc"

    static func installing(
        into original: [String: Any], marketplacePath: String
    ) throws -> [String: Any] {
        var result = original
        removeLegacyHook(from: &result)
        if result["extraKnownMarketplaces"] != nil,
           result["extraKnownMarketplaces"] as? [String: Any] == nil {
            throw ConfigurationError.invalidField("extraKnownMarketplaces")
        }
        if result["enabledPlugins"] != nil,
           result["enabledPlugins"] as? [String: Any] == nil {
            throw ConfigurationError.invalidField("enabledPlugins")
        }
        var marketplaces = result["extraKnownMarketplaces"] as? [String: Any] ?? [:]
        marketplaces.removeValue(forKey: legacyMarketplaceID)
        marketplaces[marketplaceID] = [
            "source": [
                "source": "directory",
                "path": marketplacePath,
            ],
        ]
        result["extraKnownMarketplaces"] = marketplaces
        var enabled = result["enabledPlugins"] as? [String: Any] ?? [:]
        enabled.removeValue(forKey: legacyPluginID)
        enabled[pluginID] = true
        result["enabledPlugins"] = enabled
        return result
    }

    static func uninstalling(from original: [String: Any]) -> [String: Any] {
        var result = original
        removeLegacyHook(from: &result)
        if var marketplaces = result["extraKnownMarketplaces"] as? [String: Any] {
            marketplaces.removeValue(forKey: marketplaceID)
            marketplaces.removeValue(forKey: legacyMarketplaceID)
            if marketplaces.isEmpty {
                result.removeValue(forKey: "extraKnownMarketplaces")
            } else {
                result["extraKnownMarketplaces"] = marketplaces
            }
        }
        if var enabled = result["enabledPlugins"] as? [String: Any] {
            enabled.removeValue(forKey: pluginID)
            enabled.removeValue(forKey: legacyPluginID)
            if enabled.isEmpty {
                result.removeValue(forKey: "enabledPlugins")
            } else {
                result["enabledPlugins"] = enabled
            }
        }
        return result
    }

    static func isRegistered(_ settings: [String: Any], marketplacePath: String) -> Bool {
        guard let marketplaces = settings["extraKnownMarketplaces"] as? [String: Any],
              let marketplace = marketplaces[marketplaceID] as? [String: Any],
              let source = marketplace["source"] as? [String: Any],
              source["source"] as? String == "directory",
              source["path"] as? String == marketplacePath,
              let enabled = settings["enabledPlugins"] as? [String: Any],
              enabled[pluginID] as? Bool == true else { return false }
        return true
    }

    private static func removeLegacyHook(from settings: inout [String: Any]) {
        guard var hooks = settings["hooks"] as? [String: Any] else { return }
        for event in ["PreToolUse", "PermissionRequest"] {
            guard let entries = hooks[event] as? [[String: Any]] else { continue }
            let filtered = removingOwnedEntries(from: entries)
            if filtered.isEmpty { hooks.removeValue(forKey: event) }
            else { hooks[event] = filtered }
        }
        if hooks.isEmpty { settings.removeValue(forKey: "hooks") }
        else { settings["hooks"] = hooks }
    }

    private static func removingOwnedEntries(from entries: [[String: Any]]) -> [[String: Any]] {
        entries.compactMap { entry in
            guard var inner = entry["hooks"] as? [[String: Any]] else { return entry }
            inner.removeAll { hook in
                (hook["command"] as? String)?.contains(scriptName) == true
            }
            guard !inner.isEmpty else { return nil }
            var updated = entry
            updated["hooks"] = inner
            return updated
        }
    }

}

enum WorkBuddyHookInstaller {
    private enum InstallerError: LocalizedError {
        case invalidSettings

        var errorDescription: String? {
            switch self {
            case .invalidSettings:
                return "WorkBuddy settings.json is not valid JSON; it was left unchanged"
            }
        }
    }

    private static var workBuddyDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".workbuddy")
    }
    private static var marketplaceDirectory: URL {
        workBuddyDirectory.appendingPathComponent("quickvibehost/approval-marketplace")
    }
    private static var scriptURL: URL {
        marketplaceDirectory.appendingPathComponent(
            "plugin/scripts/\(WorkBuddyPluginConfiguration.scriptName)"
        )
    }
    private static var legacyScriptURL: URL {
        workBuddyDirectory.appendingPathComponent(
            "hooks/\(WorkBuddyPluginConfiguration.scriptName)"
        )
    }
    private static var settingsURL: URL {
        workBuddyDirectory.appendingPathComponent("settings.json")
    }
    private static var backupURL: URL {
        workBuddyDirectory.appendingPathComponent("settings.json.quickvibehost-backup")
    }

    static func isInstalled() -> Bool {
        guard requiredInstalledFiles.allSatisfy({ FileManager.default.fileExists(atPath: $0.path) }),
              let settings = readSettings() else { return false }
        return WorkBuddyPluginConfiguration.isRegistered(
            settings, marketplacePath: marketplaceDirectory.path
        )
    }

    static func reconcile(enabled: Bool) throws {
        if enabled { try install() } else { try uninstall() }
    }

    static func install() throws {
        let fm = FileManager.default
        let original: [String: Any]
        if fm.fileExists(atPath: settingsURL.path) {
            guard let existing = readSettings() else { throw InstallerError.invalidSettings }
            original = existing
        } else {
            original = [:]
        }
        if fm.fileExists(atPath: settingsURL.path), !fm.fileExists(atPath: backupURL.path) {
            try fm.copyItem(at: settingsURL, to: backupURL)
        }
        try installPluginFiles()
        let updated = try WorkBuddyPluginConfiguration.installing(
            into: original, marketplacePath: marketplaceDirectory.path
        )
        if !NSDictionary(dictionary: original).isEqual(to: updated) {
            try writeSettings(updated)
        }
        if fm.fileExists(atPath: legacyScriptURL.path) {
            try fm.removeItem(at: legacyScriptURL)
        }
        workBuddyApprovalLogger.info("Installed WorkBuddy approval plugin")
    }

    static func uninstall() throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: settingsURL.path) {
            guard let original = readSettings() else { throw InstallerError.invalidSettings }
            let updated = WorkBuddyPluginConfiguration.uninstalling(from: original)
            if !NSDictionary(dictionary: original).isEqual(to: updated) {
                try writeSettings(updated)
            }
        }
        if fm.fileExists(atPath: marketplaceDirectory.path) {
            try fm.removeItem(at: marketplaceDirectory)
        }
        if fm.fileExists(atPath: legacyScriptURL.path) {
            try fm.removeItem(at: legacyScriptURL)
        }
        workBuddyApprovalLogger.info("Uninstalled WorkBuddy approval plugin")
    }

    private static var requiredInstalledFiles: [URL] {
        [
            marketplaceDirectory.appendingPathComponent(".codebuddy-plugin/marketplace.json"),
            marketplaceDirectory.appendingPathComponent("plugin/.codebuddy-plugin/plugin.json"),
            marketplaceDirectory.appendingPathComponent("plugin/hooks/hooks.json"),
            scriptURL,
        ]
    }

    private static func installPluginFiles() throws {
        let fm = FileManager.default
        let resources: [(name: String, destination: String)] = [
            ("quickvibehost-workbuddy-marketplace", ".codebuddy-plugin/marketplace.json"),
            ("quickvibehost-workbuddy-plugin", "plugin/.codebuddy-plugin/plugin.json"),
            ("quickvibehost-workbuddy-hooks", "plugin/hooks/hooks.json"),
        ]
        for item in resources {
            guard let bundled = Bundle.main.url(forResource: item.name, withExtension: "json") else {
                throw NSError(
                    domain: "WorkBuddyHookInstaller", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "WorkBuddy approval plugin resource is missing: \(item.name)"]
                )
            }
            let destination = marketplaceDirectory.appendingPathComponent(item.destination)
            try fm.createDirectory(
                at: destination.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            let data = try Data(contentsOf: bundled)
            if (try? Data(contentsOf: destination)) != data {
                try data.write(to: destination, options: .atomic)
            }
        }
        guard let bundledScript = Bundle.main.url(
            forResource: "quickvibehost-workbuddy-approval", withExtension: "py"
        ) else {
            throw NSError(domain: "WorkBuddyHookInstaller", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "WorkBuddy approval hook is missing from the app bundle"])
        }
        try fm.createDirectory(at: scriptURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let scriptData = try Data(contentsOf: bundledScript)
        if (try? Data(contentsOf: scriptURL)) != scriptData {
            try scriptData.write(to: scriptURL, options: .atomic)
        }
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
    }

    private static func readSettings() -> [String: Any]? {
        guard let data = try? Data(contentsOf: settingsURL),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any] else { return nil }
        return dictionary
    }

    private static func writeSettings(_ settings: [String: Any]) throws {
        let existingMode = (try? FileManager.default.attributesOfItem(atPath: settingsURL.path)[.posixPermissions])
            as? NSNumber
        let data = try JSONSerialization.data(
            withJSONObject: settings, options: [.prettyPrinted, .sortedKeys]
        )
        var terminated = data
        terminated.append(0x0A)
        try terminated.write(to: settingsURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: existingMode ?? NSNumber(value: 0o600)],
            ofItemAtPath: settingsURL.path
        )
    }
}

@MainActor
final class WorkBuddyApprovalServer: ObservableObject {
    nonisolated static let socketPath = "/tmp/quickvibehost-workbuddy.sock"
    static let deviceWindowSeconds: UInt16 = 110
    private static let maximumPendingLifetime: TimeInterval = 125

    struct Pending {
        let requestKey: String
        let sessionID: String
        let context: PermissionContext
        let transcriptPath: String?
        let clientSocket: Int32
        let receivedAt: Date
    }

    @Published private(set) var pending: [String: Pending] = [:]
    var onPendingChanged: (() -> Void)?
    var isDeviceReadyForApproval: (() -> Bool)?
    var sessionNameProvider: ((String) -> String?)?

    private var serverSocket: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var eofSources: [String: DispatchSourceRead] = [:]
    private var pruneTimer: Timer?
    private let queue = DispatchQueue(
        label: "com.vibeeverything.workbuddy-approval", qos: .userInitiated
    )

    func start() {
        guard acceptSource == nil else { return }
        queue.async { [weak self] in self?.startServer() }
        let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pruneExpired() }
        }
        RunLoop.main.add(timer, forMode: .common)
        pruneTimer = timer
    }

    func pendingEntry(sessionID: String, transcriptPath: String?) -> Pending? {
        let normalized = transcriptPath.flatMap(Self.normalizeNonemptyPath)
        return pending.values
            .filter { item in
                if let normalized,
                   let candidate = item.transcriptPath.flatMap(Self.normalizeNonemptyPath) {
                    return candidate == normalized
                }
                return item.sessionID == sessionID
            }
            .min { $0.receivedAt < $1.receivedAt }
    }

    func pendingKey(for context: PermissionContext) -> String? {
        pending.first { $0.value.context.toolUseId == context.toolUseId }?.key
    }

    func respond(requestKey: String, decision: String, reason: String? = nil) {
        guard let item = removePending(requestKey) else { return }
        var payload: [String: Any] = ["decision": decision]
        if let reason { payload["reason"] = reason }
        finish(item: item, payload: payload)
        ApprovalCoordinator.shared.resolveWorkBuddy(requestKey: requestKey, reason: .macUI)
    }

    /// Close the bridge without deciding. The hook emits no decision and
    /// WorkBuddy immediately falls back to its own native approval dialog.
    func abandon(requestKey: String) {
        guard let item = removePending(requestKey) else { return }
        finish(item: item, payload: ["decision": "ask"])
        ApprovalCoordinator.shared.resolveWorkBuddy(requestKey: requestKey, reason: .macUI)
    }

    nonisolated private func startServer() {
        unlink(Self.socketPath)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        _ = Self.socketPath.withCString { value in
            withUnsafeMutablePointer(to: &address.sun_path) { pointer in
                strcpy(UnsafeMutableRawPointer(pointer).assumingMemoryBound(to: CChar.self), value)
            }
        }
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, listen(fd, 8) == 0 else {
            close(fd)
            return
        }
        chmod(Self.socketPath, 0o700)
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptOne(server: fd) }
        source.setCancelHandler { close(fd) }
        source.resume()
        Task { @MainActor [weak self] in
            self?.serverSocket = fd
            self?.acceptSource = source
        }
        workBuddyApprovalLogger.info("WorkBuddy approval server listening")
    }

    nonisolated private func acceptOne(server: Int32) {
        let client = accept(server, nil, nil)
        guard client >= 0 else { return }
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout,
                   socklen_t(MemoryLayout<timeval>.size))
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 8192)
        while !buffer.contains(0x0A), buffer.count < 256 * 1024 {
            let count = recv(client, &chunk, chunk.count, 0)
            guard count > 0 else { break }
            buffer.append(contentsOf: chunk[0..<count])
        }
        guard let newline = buffer.firstIndex(of: 0x0A),
              let object = try? JSONSerialization.jsonObject(
                with: buffer[buffer.startIndex..<newline]
              ) as? [String: Any],
              (object["hook_schema"] as? Int) == 1,
              let hookEventName = object["hook_event_name"] as? String,
              ["PreToolUse", "PermissionRequest"].contains(hookEventName),
              let sessionID = object["session_id"] as? String, !sessionID.isEmpty,
              let toolUseID = ((object["tool_use_id"] as? String)
                ?? (object["call_id"] as? String)), !toolUseID.isEmpty else {
            close(client)
            return
        }

        Task { @MainActor [weak self] in
            guard let self else { close(client); return }
            guard UserDefaults.standard.bool(forKey: WorkBuddyApprovalFeature.enabledKey),
                  self.isDeviceReadyForApproval?() == true else {
                Self.sendJSONLine(["kind": "fallback"], to: client)
                close(client)
                return
            }
            let requestKey = "workbuddy:\(sessionID):\(toolUseID)"
            if let old = self.removePending(requestKey) {
                ApprovalCoordinator.shared.resolveWorkBuddy(
                    requestKey: requestKey, reason: .hookEOF
                )
                self.finish(item: old, payload: ["decision": "ask"])
            }
            var toolInput: [String: AnyCodable] = [:]
            if let raw = object["tool_input"] as? [String: Any] {
                for (key, value) in raw.prefix(12) {
                    toolInput[key] = AnyCodable(value)
                }
            }
            let context = PermissionContext(
                toolUseId: toolUseID,
                toolName: (object["tool_name"] as? String) ?? "?",
                toolInput: toolInput.isEmpty ? nil : toolInput,
                receivedAt: .now
            )
            let item = Pending(
                requestKey: requestKey,
                sessionID: sessionID,
                context: context,
                transcriptPath: object["transcript_path"] as? String,
                clientSocket: client,
                receivedAt: .now
            )
            self.pending[requestKey] = item
            let eof = DispatchSource.makeReadSource(fileDescriptor: client, queue: self.queue)
            eof.setEventHandler { [weak self] in
                var byte: UInt8 = 0
                if recv(client, &byte, 1, Int32(MSG_PEEK)) <= 0 {
                    Task { @MainActor [weak self] in self?.dropDeadPending(requestKey) }
                }
            }
            eof.setCancelHandler { close(client) }
            eof.resume()
            self.eofSources[requestKey] = eof
            Self.sendJSONLine([
                "kind": "pending",
                "wait_seconds": Int(Self.deviceWindowSeconds),
            ], to: client)
            ApprovalCoordinator.shared.registerWorkBuddy(
                requestKey: requestKey,
                toolUseId: toolUseID,
                toolName: context.toolName,
                sessionName: self.sessionNameProvider?(sessionID) ?? "WorkBuddy",
                toolInput: context.toolInput,
                expiresInSec: Self.deviceWindowSeconds
            )
            self.onPendingChanged?()
        }
    }

    private func removePending(_ key: String) -> Pending? {
        guard let item = pending.removeValue(forKey: key) else { return nil }
        return item
    }

    private func finish(item: Pending, payload: [String: Any]) {
        let source = eofSources.removeValue(forKey: item.requestKey)
        queue.async {
            Self.sendJSONLine(payload, to: item.clientSocket)
            if let source { source.cancel() } else { close(item.clientSocket) }
        }
        onPendingChanged?()
    }

    private func dropDeadPending(_ key: String) {
        guard pending.removeValue(forKey: key) != nil else { return }
        eofSources.removeValue(forKey: key)?.cancel()
        ApprovalCoordinator.shared.resolveWorkBuddy(requestKey: key, reason: .hookEOF)
        onPendingChanged?()
    }

    private func pruneExpired() {
        guard UserDefaults.standard.bool(forKey: WorkBuddyApprovalFeature.enabledKey),
              isDeviceReadyForApproval?() == true else {
            for key in Array(pending.keys) { abandon(requestKey: key) }
            return
        }
        let cutoff = Date().addingTimeInterval(-Self.maximumPendingLifetime)
        for key in pending.values.filter({ $0.receivedAt < cutoff }).map(\.requestKey) {
            abandon(requestKey: key)
        }
    }

    nonisolated private static func normalizeNonemptyPath(_ path: String) -> String? {
        guard !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }

    nonisolated private static func sendJSONLine(_ object: [String: Any], to fd: Int32) {
        guard var data = try? JSONSerialization.data(withJSONObject: object) else { return }
        data.append(0x0A)
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var sent = 0
            while sent < raw.count {
                let count = Darwin.send(fd, base.advanced(by: sent), raw.count - sent, 0)
                if count <= 0 { return }
                sent += count
            }
        }
    }
}
