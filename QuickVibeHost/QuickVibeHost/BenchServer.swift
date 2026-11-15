import Foundation
import os.log

private let logger = Logger(subsystem: "com.vibeeverything.QuickVibeHost", category: "BenchServer")

// MARK: - Request / Response

struct BenchRequest: Decodable {
    let wavB64: String
    let engine: String?

    enum CodingKeys: String, CodingKey {
        case wavB64 = "wav_b64"
        case engine
    }
}

struct BenchResponse: Encodable {
    let text: String
    let latencyMs: Int
    let engine: String
    let error: String

    enum CodingKeys: String, CodingKey {
        case text
        case latencyMs = "latency_ms"
        case engine
        case error
    }
}

// MARK: - Server

/// 本地 Unix domain socket 服务，供 ASRBench bench.py 调用 App 完整 ASR 流程。
/// 不破坏任何现有识别路径：只是新增了一个输入入口。
/// 默认随 App 启动，监听 /tmp/quickvibe-bench.sock，chmod 0o700。
final class BenchServer {
    static let shared = BenchServer()
    static let socketPath = "/tmp/quickvibe-bench.sock"

    private var serverSocket: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private let queue = DispatchQueue(label: "com.vibeeverything.bench", qos: .userInitiated)

    /// 注入 App 启动时的 VoiceInputManager 引用。
    weak var voiceManager: VoiceInputManager?

    private init() {}

    func start() {
        queue.async { [weak self] in self?.startServer() }
    }

    func stop() {
        acceptSource?.cancel()
        acceptSource = nil
        unlink(Self.socketPath)
    }

    // MARK: - Socket Lifecycle

    private func startServer() {
        guard serverSocket < 0 else { return }

        unlink(Self.socketPath)
        serverSocket = socket(AF_UNIX, SOCK_STREAM, 0)
        guard serverSocket >= 0 else {
            logger.error("socket() failed: \(errno)")
            return
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        Self.socketPath.withCString { ptr in
            withUnsafeMutablePointer(to: &addr.sun_path) {
                strcpy(UnsafeMutableRawPointer($0).assumingMemoryBound(to: CChar.self), ptr)
            }
        }
        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(serverSocket, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            logger.error("bind() failed: \(errno)")
            close(serverSocket); serverSocket = -1; return
        }
        chmod(Self.socketPath, 0o700)
        guard listen(serverSocket, 5) == 0 else {
            logger.error("listen() failed: \(errno)")
            close(serverSocket); serverSocket = -1; return
        }

        logger.info("BenchServer listening on \(Self.socketPath, privacy: .public)")

        acceptSource = DispatchSource.makeReadSource(fileDescriptor: serverSocket, queue: queue)
        acceptSource?.setEventHandler { [weak self] in self?.acceptConnection() }
        acceptSource?.setCancelHandler { [weak self] in
            guard let self, self.serverSocket >= 0 else { return }
            close(self.serverSocket); self.serverSocket = -1
        }
        acceptSource?.resume()
    }

    private func acceptConnection() {
        let fd = accept(serverSocket, nil, nil)
        guard fd >= 0 else { return }
        var nosigpipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &nosigpipe, socklen_t(MemoryLayout<Int32>.size))
        let flags = fcntl(fd, F_GETFL)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        handleClient(fd)
    }

    // MARK: - Request Handling

    private func handleClient(_ fd: Int32) {
        var allData = Data()
        var buf = [UInt8](repeating: 0, count: 65536)
        var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        let deadline = Date().addingTimeInterval(10)

        while Date() < deadline {
            let r = poll(&pfd, 1, 100)
            if r > 0 && (pfd.revents & Int16(POLLIN | POLLHUP)) != 0 {
                let n = read(fd, &buf, buf.count)
                if n > 0 { allData.append(contentsOf: buf[0..<n]) }
                else if n == 0 { break }
                else if errno != EAGAIN && errno != EWOULDBLOCK { break }
            }
        }

        guard !allData.isEmpty else { close(fd); return }

        let req: BenchRequest
        do {
            req = try JSONDecoder().decode(BenchRequest.self, from: allData)
        } catch {
            sendResponse(BenchResponse(text: "", latencyMs: 0, engine: "", error: "invalid json: \(error.localizedDescription)"), to: fd)
            close(fd)
            return
        }

        guard let wavData = Data(base64Encoded: req.wavB64, options: .ignoreUnknownCharacters) else {
            sendResponse(BenchResponse(text: "", latencyMs: 0, engine: "", error: "invalid wav_b64"), to: fd)
            close(fd)
            return
        }

        guard let manager = voiceManager else {
            sendResponse(BenchResponse(text: "", latencyMs: 0, engine: "", error: "voice manager not ready"), to: fd)
            close(fd)
            return
        }

        let engineOverride: ASREngine?
        if let engine = req.engine {
            guard let parsed = ASREngine(rawValue: engine) else {
                sendResponse(BenchResponse(text: "", latencyMs: 0, engine: "", error: "invalid engine: \(engine)"), to: fd)
                close(fd)
                return
            }
            engineOverride = parsed
        } else {
            engineOverride = nil
        }

        Task {
            let result = await manager.recognizeForBench(wavData: wavData, engineOverride: engineOverride)
            let resp = BenchResponse(text: result.text, latencyMs: result.latencyMs,
                                     engine: result.engine, error: result.error)
            self.sendResponse(resp, to: fd)
            close(fd)
        }
    }

    private func sendResponse(_ resp: BenchResponse, to fd: Int32) {
        guard let data = try? JSONEncoder().encode(resp) else { close(fd); return }
        data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var sent = 0
            while sent < data.count {
                let n = write(fd, base.advanced(by: sent), data.count - sent)
                if n > 0 {
                    sent += n
                } else if errno == EAGAIN || errno == EWOULDBLOCK {
                    var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                    guard poll(&pfd, 1, 1000) > 0 else { break }
                } else {
                    break
                }
            }
        }
    }
}
