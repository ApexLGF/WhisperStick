import AppKit
import Combine
import CryptoKit
import Foundation

enum AppUpdateState: Equatable {
    case idle
    case checking
    case upToDate
    case available(AppVersion)
    case downloading(Double)
    case verifying
    case ready(URL)
    case failed(String)
}

@MainActor
final class AppUpdateManager: NSObject, ObservableObject, URLSessionDownloadDelegate {
    static let manifestURL = URL(string: "https://vibeeverything.cc/compatibility.json")!
    private static let baseURL = URL(string: "https://vibeeverything.cc")!
    private static let automaticCheckDateKey = "appUpdate.lastAutomaticCheck"
    private static let automaticCheckInterval: TimeInterval = 24 * 60 * 60

    @Published private(set) var state: AppUpdateState = .idle

    private var availableRelease: AppRelease?
    private var downloadTask: URLSessionDownloadTask?
    private var readyDMGURL: URL?
    private lazy var downloadSession = URLSession(
        configuration: .default,
        delegate: self,
        delegateQueue: .main
    )

    var currentVersion: AppVersion {
        AppVersion(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0")!
    }

    // Developer builds only check the official distribution when explicitly requested.
    func checkForUpdates(force: Bool = false) {
        guard force else { return }
        guard state != .checking,
              downloadTask == nil,
              force || canRunAutomaticCheck else { return }

        if !force {
            UserDefaults.standard.set(Date(), forKey: Self.automaticCheckDateKey)
        }

        state = .checking
        var request = URLRequest(url: Self.manifestURL)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 20
        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            Task { @MainActor [weak self] in
                self?.handleManifest(data: data, response: response, error: error)
            }
        }.resume()
    }

    func downloadUpdate() {
        guard case .available = state, let release = availableRelease,
              let remoteURL = trustedURL(for: release.downloadURL) else { return }

        let version = release.latest
        let directory = AppUpdateStorage.updatesDirectory
        let temporaryURL = directory.appendingPathComponent("QuickVibeHost-v\(version).dmg.tmp")

        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: temporaryURL)
        } catch {
            state = .failed(AppL10n.format("无法创建更新目录：%@", error.localizedDescription))
            return
        }

        readyDMGURL = nil
        state = .downloading(0)
        let task = downloadSession.downloadTask(with: remoteURL)
        task.taskDescription = version.description
        downloadTask = task
        task.resume()
    }

    @discardableResult
    func openReadyUpdate() -> Bool {
        guard let readyDMGURL else { return false }
        guard NSWorkspace.shared.open(readyDMGURL) else {
            state = .failed(AppL10n.tr("无法打开更新包"))
            return false
        }
        return true
    }

    private var canRunAutomaticCheck: Bool {
        guard let date = UserDefaults.standard.object(forKey: Self.automaticCheckDateKey) as? Date else {
            return true
        }
        return Date().timeIntervalSince(date) >= Self.automaticCheckInterval
    }

    private func handleManifest(data: Data?, response: URLResponse?, error: Error?) {
        guard let data, error == nil else {
            state = .failed(error?.localizedDescription ?? AppL10n.tr("无法检查更新"))
            return
        }
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            state = .failed(AppL10n.tr("更新清单请求失败"))
            return
        }

        do {
            let manifest = try AppUpdateManifest.decode(data)
            guard manifest.schema == 1 else {
                throw UpdateError.invalidManifest
            }
            if manifest.app.latest > currentVersion {
                availableRelease = manifest.app
                state = .available(manifest.app.latest)
            } else {
                availableRelease = nil
                state = .upToDate
            }
        } catch {
            state = .failed(AppL10n.format("更新清单无效：%@", error.localizedDescription))
        }
    }

    private func trustedURL(for relativeURL: URL) -> URL? {
        guard relativeURL.scheme == nil,
              relativeURL.host == nil,
              relativeURL.port == nil,
              relativeURL.path.hasPrefix("/releases/") else { return nil }

        var components = URLComponents(url: Self.baseURL, resolvingAgainstBaseURL: false)
        components?.path = relativeURL.path
        components?.query = relativeURL.query
        return components?.url
    }

    private func handleDownloadFinished(taskID: Int, temporaryURL: URL) {
        guard downloadTask?.taskIdentifier == taskID,
              let release = availableRelease,
              let remoteURL = trustedURL(for: release.downloadURL) else { return }

        let version = release.latest
        let directory = AppUpdateStorage.updatesDirectory
        let finalURL = directory.appendingPathComponent("QuickVibeHost-v\(version).dmg")
        verify(
            temporaryURL: temporaryURL,
            finalURL: finalURL,
            checksumURL: remoteURL.appendingPathExtension("sha256"),
            taskID: taskID
        )
    }

    private func verify(temporaryURL: URL, finalURL: URL, checksumURL: URL, taskID: Int) {
        state = .verifying
        URLSession.shared.dataTask(with: checksumURL) { [weak self] data, response, error in
            guard let data, error == nil,
                  (response as? HTTPURLResponse)?.statusCode == 200 else {
                DispatchQueue.main.async {
                    self?.finishVerification(taskID: taskID, temporaryURL: temporaryURL, finalURL: nil, error: error ?? UpdateError.checksumUnavailable)
                }
                return
            }

            DispatchQueue.global(qos: .utility).async {
                do {
                    let expected = try Self.expectedSHA256(from: data)
                    let actual = try Self.sha256Hex(at: temporaryURL)
                    guard expected.caseInsensitiveCompare(actual) == .orderedSame else {
                        throw UpdateError.checksumMismatch
                    }
                    DispatchQueue.main.async {
                        self?.finishVerification(taskID: taskID, temporaryURL: temporaryURL, finalURL: finalURL, error: nil)
                    }
                } catch {
                    DispatchQueue.main.async {
                        self?.finishVerification(taskID: taskID, temporaryURL: temporaryURL, finalURL: nil, error: error)
                    }
                }
            }
        }.resume()
    }

    private func finishVerification(taskID: Int, temporaryURL: URL, finalURL: URL?, error: Error?) {
        guard downloadTask?.taskIdentifier == taskID else { return }
        defer { downloadTask = nil }

        if let error {
            try? FileManager.default.removeItem(at: temporaryURL)
            state = .failed(AppL10n.format("更新校验失败：%@", error.localizedDescription))
            return
        }

        guard let finalURL else {
            state = .failed(AppL10n.tr("更新文件无效"))
            return
        }

        do {
            try? FileManager.default.removeItem(at: finalURL)
            try FileManager.default.moveItem(at: temporaryURL, to: finalURL)
            readyDMGURL = finalURL
            state = .ready(finalURL)
            _ = openReadyUpdate()
        } catch {
            try? FileManager.default.removeItem(at: temporaryURL)
            state = .failed(AppL10n.format("无法打开更新包：%@", error.localizedDescription))
        }
    }

    private func handleDownloadError(taskID: Int, error: Error) {
        guard downloadTask?.taskIdentifier == taskID else { return }
        downloadTask = nil
        state = .failed(AppL10n.format("下载更新失败：%@", error.localizedDescription))
    }

    private enum UpdateError: LocalizedError {
        case invalidManifest
        case checksumUnavailable
        case checksumMismatch

        var errorDescription: String? {
            switch self {
            case .invalidManifest: return AppL10n.tr("版本清单 schema 不支持")
            case .checksumUnavailable: return AppL10n.tr("服务器未提供 SHA256 校验文件")
            case .checksumMismatch: return AppL10n.tr("下载文件与服务器校验值不一致")
            }
        }
    }

    nonisolated private static func expectedSHA256(from data: Data) throws -> String {
        guard let text = String(data: data, encoding: .utf8),
              let token = text.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }).first,
              token.count == 64,
              token.allSatisfy({ $0.isHexDigit }) else {
            throw UpdateError.checksumUnavailable
        }
        return String(token)
    }

    nonisolated private static func sha256Hex(at url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var hasher = SHA256()
        while true {
            let chunk = try handle.read(upToCount: 1024 * 1024) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        let taskID = downloadTask.taskIdentifier
        let progress = totalBytesExpectedToWrite > 0
            ? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
            : 0
        Task { @MainActor [weak self] in
            guard self?.downloadTask?.taskIdentifier == taskID else { return }
            self?.state = .downloading(min(max(progress, 0), 1))
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        let taskID = downloadTask.taskIdentifier
        let temporaryURL = AppUpdateStorage.updatesDirectory.appendingPathComponent(
            "QuickVibeHost-v\(downloadTask.taskDescription ?? "unknown").dmg.tmp"
        )
        do {
            try FileManager.default.createDirectory(at: AppUpdateStorage.updatesDirectory, withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: temporaryURL)
            try FileManager.default.moveItem(at: location, to: temporaryURL)
            Task { @MainActor [weak self] in
                self?.handleDownloadFinished(taskID: taskID, temporaryURL: temporaryURL)
            }
        } catch {
            Task { @MainActor [weak self] in
                self?.handleDownloadError(taskID: taskID, error: error)
            }
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard let error else { return }
        let taskID = task.taskIdentifier
        Task { @MainActor [weak self] in
            self?.handleDownloadError(taskID: taskID, error: error)
        }
    }
}
