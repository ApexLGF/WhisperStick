import Foundation
import Combine
import CryptoKit
import os

struct EnglishASRModelFile: Codable, Equatable, Sendable {
    let name: String
    let url: String
    let sha256: String
    let size: Int64
}

struct EnglishASRModelManifest: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let engine: String
    let language: String
    let version: String
    let files: [EnglishASRModelFile]
}

/// Download/install lifecycle for the optional English Sherpa-ONNX package.
/// The model is deliberately not bundled in the DMG; users opt in from Voice settings.
@MainActor
final class EnglishASRModelManager: ObservableObject {
    static let expectedVersion = "sherpa-zipformer-en-streaming-2023-06-26-v1"
    static let manifestURL = URL(string:
        "https://www.vibeeverything.cc/models-asr/\(expectedVersion)/manifest.json"
    )!

    @Published private(set) var state: ModelDownloadState = .notDownloaded
    @Published private(set) var manifest: EnglishASRModelManifest?

    private let logger = Logger(
        subsystem: "com.vibeeverything.QuickVibeHost",
        category: "EnglishASRModel"
    )
    private let cacheFilename = "english-asr-manifest.json"
    private let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 600
        return URLSession(configuration: configuration)
    }()

    var modelsRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/QuickVibeHost/models", isDirectory: true)
    }

    var totalSize: Int64 {
        manifest?.files.reduce(0) { $0 + $1.size } ?? 0
    }

    func installedDirectory() -> URL? {
        guard state == .ready else { return nil }
        return modelsRoot.appendingPathComponent(Self.expectedVersion, isDirectory: true)
    }

    func checkLocalState() async {
        let root = modelsRoot
        let cacheURL = root.appendingPathComponent(cacheFilename)
        let expectedVersion = Self.expectedVersion
        let inspection = await Task.detached(priority: .utility) {
            Self.inspect(root: root, cacheURL: cacheURL, expectedVersion: expectedVersion)
        }.value
        switch inspection {
        case .ready(let cached):
            manifest = cached
            state = .ready
        case .notDownloaded(let reason):
            if let reason { logger.warning("\(reason, privacy: .public)") }
            manifest = nil
            state = .notDownloaded
        case .failed(let reason):
            manifest = nil
            state = .failed(AppL10n.format("本地校验失败: %@", reason))
        }
    }

    func downloadModels() async {
        state = .downloading(progress: 0)
        do {
            try FileManager.default.createDirectory(at: modelsRoot, withIntermediateDirectories: true)
            let modelManifest = try await fetchManifest()
            try validate(modelManifest)
            manifest = modelManifest

            let directory = modelsRoot.appendingPathComponent(modelManifest.version, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let total = max(modelManifest.files.reduce(Int64(0)) { $0 + $1.size }, 1)
            var completed: Int64 = 0

            for file in modelManifest.files {
                let destination = try safeDestination(for: file.name, inside: directory)
                try FileManager.default.createDirectory(
                    at: destination.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                if FileManager.default.fileExists(atPath: destination.path),
                   try await fileSHA256(destination)
                    .caseInsensitiveCompare(file.sha256) == .orderedSame {
                    completed += file.size
                    state = .downloading(progress: Double(completed) / Double(total))
                    continue
                }

                guard let url = URL(string: file.url), url.scheme == "https" else {
                    throw ModelError.invalidURL(file.name)
                }
                let temporary = destination.appendingPathExtension("tmp")
                try? FileManager.default.removeItem(at: temporary)
                let (downloaded, response) = try await session.download(from: url)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                    throw ModelError.http((response as? HTTPURLResponse)?.statusCode ?? -1)
                }
                try? FileManager.default.removeItem(at: temporary)
                try FileManager.default.moveItem(at: downloaded, to: temporary)

                state = .verifying
                let attributes = try FileManager.default.attributesOfItem(atPath: temporary.path)
                let actualSize = (attributes[.size] as? NSNumber)?.int64Value ?? -1
                guard actualSize == file.size else {
                    try? FileManager.default.removeItem(at: temporary)
                    throw ModelError.sizeMismatch(file.name)
                }
                guard try await fileSHA256(temporary)
                    .caseInsensitiveCompare(file.sha256) == .orderedSame else {
                    try? FileManager.default.removeItem(at: temporary)
                    throw ModelError.hashMismatch(file.name)
                }
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.moveItem(at: temporary, to: destination)
                completed += file.size
                state = .downloading(progress: Double(completed) / Double(total))
            }

            let encoded = try JSONEncoder().encode(modelManifest)
            try encoded.write(to: modelsRoot.appendingPathComponent(cacheFilename), options: .atomic)
            state = .ready
        } catch {
            logger.error("English model install failed: \(error.localizedDescription, privacy: .public)")
            state = .failed(AppL10n.format("英文模型下载失败: %@", error.localizedDescription))
        }
    }

    func deleteModels() async {
        try? FileManager.default.removeItem(
            at: modelsRoot.appendingPathComponent(Self.expectedVersion, isDirectory: true)
        )
        try? FileManager.default.removeItem(at: modelsRoot.appendingPathComponent(cacheFilename))
        manifest = nil
        state = .notDownloaded
    }

    private func fetchManifest() async throws -> EnglishASRModelManifest {
        var request = URLRequest(url: Self.manifestURL, timeoutInterval: 30)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw ModelError.http((response as? HTTPURLResponse)?.statusCode ?? -1)
        }
        return try JSONDecoder().decode(EnglishASRModelManifest.self, from: data)
    }

    private func validate(_ value: EnglishASRModelManifest) throws {
        guard value.schemaVersion == 1,
              value.engine == "sherpa-onnx",
              value.language == "en",
              value.version == Self.expectedVersion,
              !value.files.isEmpty else {
            throw ModelError.invalidManifest
        }
        for file in value.files {
            guard file.size > 0,
                  file.sha256.count == 64,
                  URL(string: file.url)?.scheme == "https" else {
                throw ModelError.invalidManifest
            }
            _ = try safeDestination(
                for: file.name,
                inside: modelsRoot.appendingPathComponent(value.version, isDirectory: true)
            )
        }
    }

    private func safeDestination(for relativePath: String, inside root: URL) throws -> URL {
        guard !relativePath.isEmpty, !relativePath.hasPrefix("/"),
              !relativePath.split(separator: "/").contains("..") else {
            throw ModelError.unsafePath(relativePath)
        }
        let standardizedRoot = root.standardizedFileURL.path + "/"
        let destination = root.appendingPathComponent(relativePath).standardizedFileURL
        guard destination.path.hasPrefix(standardizedRoot) else {
            throw ModelError.unsafePath(relativePath)
        }
        return destination
    }

    nonisolated private static func inspect(
        root: URL,
        cacheURL: URL,
        expectedVersion: String
    ) -> Inspection {
        do {
            guard let data = try? Data(contentsOf: cacheURL),
                  let cached = try? JSONDecoder().decode(EnglishASRModelManifest.self, from: data),
                  cached.schemaVersion == 1,
                  cached.engine == "sherpa-onnx",
                  cached.language == "en",
                  cached.version == expectedVersion else {
                return .notDownloaded(nil)
            }
            let directory = root.appendingPathComponent(cached.version, isDirectory: true)
            for file in cached.files {
                guard !file.name.hasPrefix("/"),
                      !file.name.split(separator: "/").contains("..") else {
                    return .notDownloaded("Cached English manifest contains an unsafe path")
                }
                let url = directory.appendingPathComponent(file.name).standardizedFileURL
                guard FileManager.default.fileExists(atPath: url.path) else {
                    return .notDownloaded("English model file missing: \(file.name)")
                }
                let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
                guard (attributes[.size] as? NSNumber)?.int64Value == file.size else {
                    return .notDownloaded("English model file size mismatch: \(file.name)")
                }
            }
            return .ready(cached)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    private func fileSHA256(_ url: URL) async throws -> String {
        try await Task.detached(priority: .utility) {
            try Self.sha256(url)
        }.value
    }

    nonisolated private static func sha256(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = handle.readData(ofLength: 1024 * 1024)
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private enum Inspection: Sendable {
        case ready(EnglishASRModelManifest)
        case notDownloaded(String?)
        case failed(String)
    }

    private enum ModelError: LocalizedError {
        case invalidManifest
        case invalidURL(String)
        case unsafePath(String)
        case http(Int)
        case sizeMismatch(String)
        case hashMismatch(String)

        var errorDescription: String? {
            switch self {
            case .invalidManifest: "模型清单无效"
            case .invalidURL(let name): "下载地址无效: \(name)"
            case .unsafePath(let path): "模型路径不安全: \(path)"
            case .http(let code): "服务器返回 HTTP \(code)"
            case .sizeMismatch(let name): "文件大小不匹配: \(name)"
            case .hashMismatch(let name): "SHA-256 不匹配: \(name)"
            }
        }
    }
}
