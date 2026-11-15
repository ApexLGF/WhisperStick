import Foundation
import Combine
import CryptoKit
import os

enum ModelDownloadState: Equatable {
    case notDownloaded
    case downloading(progress: Double)   // 0.0 .. 1.0
    case verifying
    case ready
    case failed(String)
}

struct ModelFileSpec: Decodable, Equatable, Sendable {
    let name: String
    let url: String
    let sha256: String
    let size: Int64
}

struct ModelManifest: Decodable, Equatable, Sendable {
    let version: String                  // e.g. "paraformer-zh-2024-03-09"
    let files: [ModelFileSpec]
}

/// 管理 Paraformer + ct-punc 模型的下载/校验/落盘/版本。
///
/// 落盘根目录:`~/Library/Application Support/QuickVibeHost/models/<manifest.version>/`
/// 下载流程:fetch manifest → 逐文件下到 `<file>.tmp` → SHA256 校验 → 原子 rename。
/// 失败不破坏旧 ready 模型(.tmp 原子写)。
/// 信任 CDN 直连 IP 的服务器证书(证书签发给 ve.llamer.co,直连 IP 域名不匹配)。
/// 仅用于模型下载;内容完整性由逐文件 SHA256 校验保证(见 downloadModels)。
final class InsecureCDNTrustDelegate: NSObject, URLSessionDelegate {
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           let trust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}

@MainActor
final class ASRModelManager: ObservableObject {
    @Published var state: ModelDownloadState = .notDownloaded
    @Published var manifest: ModelManifest?

    private let manifestURL = URL(string: "https://www.vibeeverything.cc/models-seaco/manifest.json")!
    /// 期望模型版本(防旧 v2.3.0 paraformer 缓存被误判就绪 → 引擎 init 旧模型崩溃)
    static let expectedModelVersion = "seaco-paraformer-zh-2024-2"
    private let logger = Logger(subsystem: "com.vibeeverything.QuickVibeHost", category: "ASRModel")
    private let manifestCacheFilename = "manifest.json"

    // www.vibeeverything.cc（阿里云中国 IP）在部分网络可能被按 SNI reset。直连 IP + Host 头
    // (SNI≠域名,绕开重置)+ 自定义 session 信任证书;完整性靠逐文件 SHA256 校验。
    private static let cdnIP = "47.108.148.208"
    private let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: cfg, delegate: InsecureCDNTrustDelegate(), delegateQueue: nil)
    }()
    /// 逻辑 URL（www.vibeeverything.cc）→ 直连 IP + Host 头。
    private func cdnRequest(for url: URL, timeout: TimeInterval) -> URLRequest {
        guard var comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return URLRequest(url: url, timeoutInterval: timeout)
        }
        let host = comps.host ?? ""
        comps.host = Self.cdnIP
        var req = URLRequest(url: comps.url ?? url, timeoutInterval: timeout)
        req.setValue(host, forHTTPHeaderField: "Host")
        req.cachePolicy = .reloadIgnoringLocalCacheData
        return req
    }

    /// 落盘根目录(所有 version 的 parent)。
    var modelsRoot: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent("Library/Application Support/QuickVibeHost/models", isDirectory: true)
    }

    /// 当前 manifest.version 对应的模型目录(就绪后供 SherpaParaformerEngine 用)。
    func currentVersionDir() -> URL? {
        guard let v = manifest?.version else { return nil }
        return modelsRoot.appendingPathComponent(v, isDirectory: true)
    }

    var totalSize: Int64 {
        manifest?.files.reduce(0) { $0 + $1.size } ?? 0
    }

    /// 启动时调:有 manifest 缓存 + 文件齐 + SHA OK → state = .ready;否则 .notDownloaded
    func checkLocalState() async {
        let root = modelsRoot
        let cacheName = manifestCacheFilename
        let expectedVersion = Self.expectedModelVersion
        // 约 643MB 的完整 SHA 校验必须离开 MainActor；否则冷启动/切换引擎会冻结 SwiftUI。
        let inspection = await Task.detached(priority: .utility) {
            Self.inspectLocalModels(root: root, cacheName: cacheName, expectedVersion: expectedVersion)
        }.value
        switch inspection {
        case .ready(let modelManifest):
            manifest = modelManifest
            state = .ready
        case .notDownloaded(let reason):
            if !reason.isEmpty { logger.warning("\(reason, privacy: .public)") }
            manifest = nil
            state = .notDownloaded
        case .failed(let message):
            manifest = nil
            state = .failed(AppL10n.format("本地校验失败: %@", message))
        }
    }

    private enum LocalModelInspection: Sendable {
        case ready(ModelManifest)
        case notDownloaded(String)
        case failed(String)
    }

    nonisolated private static func inspectLocalModels(
        root: URL,
        cacheName: String,
        expectedVersion: String
    ) -> LocalModelInspection {
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let cached = root.appendingPathComponent(cacheName)
            guard FileManager.default.fileExists(atPath: cached.path),
                  let data = try? Data(contentsOf: cached),
                  let modelManifest = try? JSONDecoder().decode(ModelManifest.self, from: data) else {
                return .notDownloaded("")
            }
            guard modelManifest.version == expectedVersion else {
                return .notDownloaded(
                    "Cached manifest version \(modelManifest.version) != expected \(expectedVersion) → notDownloaded"
                )
            }
            let dir = root.appendingPathComponent(modelManifest.version, isDirectory: true)
            for spec in modelManifest.files {
                let path = dir.appendingPathComponent(spec.name)
                guard FileManager.default.fileExists(atPath: path.path) else {
                    return .notDownloaded("Local file \(spec.name) missing")
                }
                let hash = try calculateFileSHA256(at: path)
                guard hash.caseInsensitiveCompare(spec.sha256) == .orderedSame else {
                    return .notDownloaded("Local file \(spec.name) sha mismatch")
                }
            }
            return .ready(modelManifest)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// 拉 manifest → 逐文件下载 → SHA 校验 → 原子 mv 落盘。
    /// 失败不破坏旧 ready 模型(下到 .tmp 再原子替换)。
    func downloadModels() async {
        do {
            try ensureDir(modelsRoot)

            // 1. fetch manifest
            self.state = .downloading(progress: 0.0)
            let m: ModelManifest
            do {
                m = try await fetchManifest()
            } catch {
                self.state = .failed(AppL10n.format("无法拉取模型清单: %@", error.localizedDescription))
                return
            }
            self.manifest = m

            // 2. prepare version dir
            let versionDir = modelsRoot.appendingPathComponent(m.version, isDirectory: true)
            try ensureDir(versionDir)

            // 3. download each file with weighted progress
            let totalBytes = max(m.files.reduce(Int64(0)) { $0 + $1.size }, 1)
            var doneBytes: Int64 = 0
            for spec in m.files {
                let dst = versionDir.appendingPathComponent(spec.name)
                // spec.name 可含子目录(如 punc/model_quant.onnx)→ 先建父目录,否则 moveItem 落盘失败
                try? ensureDir(dst.deletingLastPathComponent())
                if FileManager.default.fileExists(atPath: dst.path),
                   (try? fileSHA256(at: dst).caseInsensitiveCompare(spec.sha256) == .orderedSame) == true {
                    // 已存在且 hash 对得上,跳过
                    doneBytes += spec.size
                    self.state = .downloading(progress: Double(doneBytes) / Double(totalBytes))
                    continue
                }

                let tmp = versionDir.appendingPathComponent(spec.name + ".tmp")
                try? FileManager.default.removeItem(at: tmp)

                guard let url = URL(string: spec.url) else {
                    self.state = .failed(AppL10n.format("无效 URL: %@", spec.url))
                    return
                }

                let baseDone = doneBytes
                do {
                    try await downloadFile(from: url, to: tmp) { [weak self] bytesWritten in
                        guard let self else { return }
                        let cur = baseDone + bytesWritten
                        let p = Double(cur) / Double(totalBytes)
                        Task { @MainActor in self.state = .downloading(progress: p) }
                    }
                } catch {
                    try? FileManager.default.removeItem(at: tmp)
                    self.state = .failed(AppL10n.format("下载 %@ 失败: %@", spec.name, error.localizedDescription))
                    return
                }

                // 4. SHA256 verify
                self.state = .verifying
                let hash: String
                do {
                    hash = try fileSHA256(at: tmp)
                } catch {
                    try? FileManager.default.removeItem(at: tmp)
                    self.state = .failed(AppL10n.format("校验 %@ 读取失败: %@", spec.name, error.localizedDescription))
                    return
                }
                guard hash.caseInsensitiveCompare(spec.sha256) == .orderedSame else {
                    try? FileManager.default.removeItem(at: tmp)
                    self.state = .failed(AppL10n.format("SHA256 不匹配: %@ (期望 %@…, 实际 %@…)", spec.name, String(spec.sha256.prefix(12)), String(hash.prefix(12))))
                    return
                }

                // 5. atomic rename
                if FileManager.default.fileExists(atPath: dst.path) {
                    try? FileManager.default.removeItem(at: dst)
                }
                do {
                    try FileManager.default.moveItem(at: tmp, to: dst)
                } catch {
                    self.state = .failed(AppL10n.format("落盘 %@ 失败: %@", spec.name, error.localizedDescription))
                    return
                }
                doneBytes += spec.size
                self.state = .downloading(progress: Double(doneBytes) / Double(totalBytes))
            }

            // 6. cache manifest for cold-start checkLocalState
            do {
                let data = try JSONEncoder().encode(EncodableManifest(version: m.version, files: m.files))
                try data.write(to: modelsRoot.appendingPathComponent(manifestCacheFilename), options: .atomic)
            } catch {
                logger.warning("Manifest cache write failed: \(error.localizedDescription, privacy: .public)")
            }

            self.state = .ready
        } catch {
            self.state = .failed(AppL10n.format("下载流程异常: %@", error.localizedDescription))
        }
    }

    /// 删模型(UI 提供"重新下载 / 删除模型"用)。
    func deleteModels() async {
        guard let dir = currentVersionDir() else {
            self.state = .notDownloaded
            return
        }
        try? FileManager.default.removeItem(at: dir)
        // 也删掉 manifest 缓存,逼迫下次重新拉
        try? FileManager.default.removeItem(at: modelsRoot.appendingPathComponent(manifestCacheFilename))
        self.manifest = nil
        self.state = .notDownloaded
    }

    // MARK: - 本地流式 2-pass 模型集(T-018:online + vad + online punc,ModelScope 直连)

    @Published var streamingState: ModelDownloadState = .notDownloaded
    static let streamingVersion = "tpass-stream-2024-1"

    /// ModelScope 文件下载 URL。
    private static func msURL(_ repo: String, _ file: String) -> String {
        "https://www.modelscope.cn/api/v1/models/\(repo)/repo?Revision=master&FilePath=\(file)"
    }
    /// 流式集清单(name=本地相对路径 online|vad|punc/文件;sha256 实测)。offline 仍复用 SeACo(currentVersionDir)。
    static let streamingFiles: [ModelFileSpec] = {
        let online = "iic/speech_paraformer-large_asr_nat-zh-cn-16k-common-vocab8404-online-onnx"
        let vad = "iic/speech_fsmn_vad_zh-cn-16k-common-onnx"
        let punc = "iic/punc_ct-transformer_zh-cn-common-vad_realtime-vocab272727-onnx"
        return [
            .init(name: "online/model_quant.onnx",   url: msURL(online, "model_quant.onnx"),   sha256: "dd4121cf45102018c26f9256f0b862df416edfcd06b0863ef4ce378a63c7d5e2", size: 166350528),
            .init(name: "online/decoder_quant.onnx", url: msURL(online, "decoder_quant.onnx"), sha256: "873d21ee80c7345bfc27944b843699fe16bba021fd020747d38aef2dfc103681", size: 71867274),
            .init(name: "online/am.mvn",             url: msURL(online, "am.mvn"),             sha256: "29b3c740a2c0cfc6b308126d31d7f265fa2be74f3bb095cd2f143ea970896ae5", size: 11203),
            .init(name: "online/config.yaml",        url: msURL(online, "config.yaml"),        sha256: "35e6bf41f8c7eaf9a0f787af7fdc8fc5ed75fa8009ade7d3c2f3ef5bce20c648", size: 2940),
            .init(name: "online/tokens.json",        url: msURL(online, "tokens.json"),        sha256: "2b20c2b12572d682afff84ce1c8d560f67b8b32a4c1f21567411d141ed352127", size: 93676),
            .init(name: "vad/model_quant.onnx",      url: msURL(vad, "model_quant.onnx"),      sha256: "5289eb2aa3c9af2d7a4284bcfa7c3ceb81d360814ed4203239b6c5d0569da8a1", size: 506744),
            .init(name: "vad/am.mvn",                url: msURL(vad, "am.mvn"),                sha256: "6820fef9687708c4fc3fab2530179c8fcea6262daa25514380056cd8f6eb1754", size: 8040),
            .init(name: "vad/config.yaml",           url: msURL(vad, "config.yaml"),           sha256: "2ef334f2d7776edd86ed696296774f87550206c256bfabc597872ad861831589", size: 1215),
            .init(name: "punc/model_quant.onnx",     url: msURL(punc, "model_quant.onnx"),     sha256: "a167b716ac5ade229b45c0e5c8fafc935cf65abda8b37597c781332ec2970a89", size: 281877652),
            .init(name: "punc/config.yaml",          url: msURL(punc, "config.yaml"),          sha256: "4b57cf5d7a3310937ac2d73aa0ea89770e022d62c99dcf3e247f7dbeb0b0260d", size: 822),
            .init(name: "punc/tokens.json",          url: msURL(punc, "tokens.json"),          sha256: "c960ab87bccea4aa15cf49a59f71973c2c330b46668048cd8da253749ec71ee3", size: 4207480),
        ]
    }()

    var streamingTotalSize: Int64 { Self.streamingFiles.reduce(0) { $0 + $1.size } }

    /// 流式模型目录(就绪时含 online/ vad/ punc/ 子目录)。
    func streamingDir() -> URL? {
        guard streamingState == .ready else { return nil }
        return installedStreamingDir()
    }

    /// 根据磁盘文件解析已安装的流式模型目录，不依赖进程内 `streamingState`。
    /// 引擎切换可能发生在启动检查之后；此入口避免完整模型因陈旧状态被静默降级为整段识别。
    func installedStreamingDir() -> URL? {
        let dir = modelsRoot.appendingPathComponent(Self.streamingVersion, isDirectory: true)
        for spec in Self.streamingFiles {
            let path = dir.appendingPathComponent(spec.name)
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: path.path),
                  (attrs[.size] as? Int64) == spec.size else { return nil }
        }
        return dir
    }

    /// 启动时快速校验(只看文件存在 + 大小,避免每次启动 hash 500MB;完整 SHA 只在下载时校验)。
    func checkStreamingLocalState() async {
        streamingState = installedStreamingDir() == nil ? .notDownloaded : .ready
    }

    /// 下载流式集(ModelScope 直连,不走 CDN IP 改写)。逐文件 → SHA 校验 → 原子落盘。
    func downloadStreamingModels() async {
        let dir = modelsRoot.appendingPathComponent(Self.streamingVersion, isDirectory: true)
        do { try ensureDir(dir) } catch { streamingState = .failed(AppL10n.format("建目录失败: %@", error.localizedDescription)); return }
        streamingState = .downloading(progress: 0)
        let total = max(streamingTotalSize, 1)
        var done: Int64 = 0
        for spec in Self.streamingFiles {
            let dst = dir.appendingPathComponent(spec.name)
            try? ensureDir(dst.deletingLastPathComponent())
            if FileManager.default.fileExists(atPath: dst.path),
               (try? fileSHA256(at: dst).caseInsensitiveCompare(spec.sha256) == .orderedSame) == true {
                done += spec.size; streamingState = .downloading(progress: Double(done)/Double(total)); continue
            }
            guard let url = URL(string: spec.url) else { streamingState = .failed(AppL10n.format("无效 URL: %@", spec.name)); return }
            let tmp = dir.appendingPathComponent(spec.name + ".tmp")
            try? FileManager.default.removeItem(at: tmp)
            do { try await downloadFilePlain(from: url, to: tmp) }
            catch { try? FileManager.default.removeItem(at: tmp); streamingState = .failed(AppL10n.format("下载 %@ 失败: %@", spec.name, error.localizedDescription)); return }
            streamingState = .verifying
            let hash = (try? fileSHA256(at: tmp)) ?? ""
            guard hash.caseInsensitiveCompare(spec.sha256) == .orderedSame else {
                try? FileManager.default.removeItem(at: tmp)
                streamingState = .failed(AppL10n.format("SHA256 不匹配: %@", spec.name)); return
            }
            if FileManager.default.fileExists(atPath: dst.path) { try? FileManager.default.removeItem(at: dst) }
            do { try FileManager.default.moveItem(at: tmp, to: dst) }
            catch { streamingState = .failed(AppL10n.format("落盘 %@ 失败: %@", spec.name, error.localizedDescription)); return }
            done += spec.size; streamingState = .downloading(progress: Double(done)/Double(total))
        }
        streamingState = .ready
    }

    func deleteStreamingModels() async {
        let dir = modelsRoot.appendingPathComponent(Self.streamingVersion, isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
        streamingState = .notDownloaded
    }

    /// ModelScope 直连下载(不改写 host,区别于 ve.llamer.co 的 cdnRequest)。
    private func downloadFilePlain(from url: URL, to destination: URL) async throws {
        var req = URLRequest(url: url, timeoutInterval: 300)
        req.cachePolicy = .reloadIgnoringLocalCacheData
        let (tempURL, response) = try await session.download(for: req)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw NSError(domain: "ASRModelManager", code: -3,
                          userInfo: [NSLocalizedDescriptionKey: "HTTP \(((response as? HTTPURLResponse)?.statusCode).map(String.init) ?? "?")"])
        }
        if FileManager.default.fileExists(atPath: destination.path) { try? FileManager.default.removeItem(at: destination) }
        try FileManager.default.moveItem(at: tempURL, to: destination)
    }

    // MARK: - Internals

    private func ensureDir(_ url: URL) throws {
        if !FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }

    private func fetchManifest() async throws -> ModelManifest {
        let request = cdnRequest(for: manifestURL, timeout: 10)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw NSError(domain: "ASRModelManager", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "manifest HTTP \(((response as? HTTPURLResponse)?.statusCode).map(String.init) ?? "?")"])
        }
        return try JSONDecoder().decode(ModelManifest.self, from: data)
    }

    /// 流式下载文件并实时回调已写入字节数。
    private func downloadFile(from url: URL,
                              to destination: URL,
                              onProgress: @escaping @Sendable (Int64) -> Void) async throws {
        // URLSession.download 落临时文件(高效);避免 .bytes 逐字节 async 迭代在 200MB+ 文件上
        // CPU 拖到请求超时。进度按文件粒度由 downloadModels 在每文件完成后累加。
        _ = onProgress
        let (tempURL, response) = try await session.download(for: cdnRequest(for: url, timeout: 120))
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw NSError(domain: "ASRModelManager", code: -2,
                          userInfo: [NSLocalizedDescriptionKey: "HTTP \(((response as? HTTPURLResponse)?.statusCode).map(String.init) ?? "?")"])
        }
        if FileManager.default.fileExists(atPath: destination.path) {
            try? FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: tempURL, to: destination)
    }

    private func fileSHA256(at url: URL) throws -> String {
        try Self.calculateFileSHA256(at: url)
    }

    nonisolated private static func calculateFileSHA256(at url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = handle.readData(ofLength: 1024 * 1024)
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// 仅用于 manifest 落盘缓存的 Encodable 镜像(ModelManifest 仅声明 Decodable)
    private struct EncodableManifest: Encodable {
        let version: String
        let files: [EncodableFileSpec]

        init(version: String, files: [ModelFileSpec]) {
            self.version = version
            self.files = files.map { EncodableFileSpec(name: $0.name, url: $0.url, sha256: $0.sha256, size: $0.size) }
        }
    }
    private struct EncodableFileSpec: Encodable {
        let name: String
        let url: String
        let sha256: String
        let size: Int64
    }
}
