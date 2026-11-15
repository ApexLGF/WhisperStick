import Foundation
import Darwin
import os

/// Minimal unix-socket client for `vibepty` (tools/vibepty.py). Sends a single
/// newline-delimited JSON message and reads one JSON reply.
///
/// Socket path convention: `/tmp/vibepty-<claude_pid>.sock`. The child pid
/// under vibepty IS the claude pid (pty.fork + execvp keeps the pid), which
/// matches the pid recorded by the hook — so no lookup indirection needed.
///
/// Blocking, with 500ms send/recv timeouts. Callers should run this on a
/// background queue (ASR pipeline already does).
enum VibeptyClient {
    private static let logger = Logger(subsystem: "com.vibeeverything.QuickVibeHost", category: "VibeptyClient")

    struct VibeptyASRSpan: Hashable {
        var id: String
        var text: String
        var start: Int
        var end: Int
    }

    struct VibeptyLineSnapshot {
        var line: String
        var lineId: Int
        var asrSpans: [VibeptyASRSpan]
    }

    struct VibeptySubmitSnapshot {
        var snapshot: VibeptyLineSnapshot?
        var error: String?
    }

    enum ClientError: Error {
        case socketCreateFailed(errno: Int32)
        case pathTooLong
        case connectRefused(errno: Int32)    // ENOENT/ECONNREFUSED → vibepty 没起
        case sendFailed(errno: Int32)
        case recvFailed(errno: Int32)
        case replyInvalid(String)
        case replyError(String)
    }

    /// 只读探测:目标 pid 的 vibepty 注入通道是否可用(socket 存在)。
    /// 直通按钮置灰门槛用 —— 无 socket == 注入必失败(纯 socket 通道,无 tty 兜底)。
    /// 不做握手(避免每帧 connect 开销),存在性即准入信号。
    static func isChannelAvailable(pid: Int) -> Bool {
        FileManager.default.fileExists(atPath: "/tmp/vibepty-\(pid).sock")
    }

    /// Inject raw UTF-8 bytes into the PTY master of the target claude session.
    /// Returns on success; throws on any failure (caller maps to FallbackReason).
    @discardableResult
    static func inject(bytes: Data, toPid pid: Int, asrSpan: Bool = false) throws -> String? {
        let sockPath = "/tmp/vibepty-\(pid).sock"

        // JSON payload: {"inject": "<utf8 string>"}. Control bytes (\r, \x1b)
        // are in ASCII → UTF-8 safe; JSONSerialization escapes them as
        // \u001b etc., which Python's json.loads roundtrips faithfully.
        guard let textPayload = String(data: bytes, encoding: .utf8) else {
            throw ClientError.replyInvalid("bytes not valid UTF-8")
        }
        var request: [String: Any] = ["inject": textPayload]
        if asrSpan { request["asrSpan"] = true }
        let body = try JSONSerialization.data(withJSONObject: request)
        var framed = body
        framed.append(0x0A)

        let reply = try sendAndReceive(sockPath: sockPath, payload: framed)
        if let ok = reply["ok"] as? Bool, ok {
            return reply["spanId"] as? String
        }
        if let errMsg = reply["error"] as? String {
            throw ClientError.replyError(errMsg)
        }
        throw ClientError.replyInvalid("reply missing 'ok'/'error': \(reply)")
    }

    static func snapshotLine(pid: Int) throws -> VibeptyLineSnapshot {
        let sockPath = "/tmp/vibepty-\(pid).sock"
        var body = try JSONSerialization.data(withJSONObject: ["snapshot": true])
        body.append(0x0A)
        let reply = try sendAndReceive(sockPath: sockPath, payload: body)
        return try parseSnapshot(reply, label: "snapshot")
    }

    static func submitSnapshotLine(pid: Int) throws -> VibeptySubmitSnapshot {
        let sockPath = "/tmp/vibepty-\(pid).sock"
        var body = try JSONSerialization.data(withJSONObject: ["submitSnapshot": true])
        body.append(0x0A)
        let reply = try sendAndReceive(sockPath: sockPath, payload: body)
        if let ok = reply["ok"] as? Bool, ok {
            return .init(snapshot: try parseSnapshot(reply, label: "submitSnapshot"), error: nil)
        }
        if let errMsg = reply["error"] as? String {
            if errMsg != "unsafe line state" {
                throw ClientError.replyError(errorMessage(from: reply, fallback: errMsg))
            }
            return .init(snapshot: nil, error: errorMessage(from: reply, fallback: errMsg))
        }
        throw ClientError.replyInvalid("submitSnapshot missing 'ok'/'error': \(reply)")
    }

    private static func parseSnapshot(_ reply: [String: Any], label: String) throws -> VibeptyLineSnapshot {
        if let ok = reply["ok"] as? Bool, ok {
            guard let line = reply["line"] as? String,
                  let lineId = reply["lineId"] as? Int,
                  let rawSpans = reply["asrSpans"] as? [[String: Any]] else {
                throw ClientError.replyInvalid("\(label) missing fields: \(reply)")
            }
            let spans = rawSpans.compactMap { raw -> VibeptyASRSpan? in
                guard let id = raw["id"] as? String,
                      let text = raw["text"] as? String,
                      let start = raw["start"] as? Int,
                      let end = raw["end"] as? Int else { return nil }
                return .init(id: id, text: text, start: start, end: end)
            }
            return .init(line: line, lineId: lineId, asrSpans: spans)
        }
        if let errMsg = reply["error"] as? String {
            throw ClientError.replyError(errorMessage(from: reply, fallback: errMsg))
        }
        throw ClientError.replyInvalid("\(label) missing 'ok'/'error': \(reply)")
    }

    private static func errorMessage(from reply: [String: Any], fallback: String) -> String {
        guard let reason = reply["unsafeReason"] as? String, !reason.isEmpty else { return fallback }
        return "\(fallback) (\(reason))"
    }

    private static func sendAndReceive(sockPath: String, payload: Data) throws -> [String: Any] {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        if fd < 0 { throw ClientError.socketCreateFailed(errno: errno) }
        defer { close(fd) }

        // 500ms send/recv timeout so a stuck vibepty doesn't hang ASR path.
        var tv = timeval(tv_sec: 0, tv_usec: 500_000)
        _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(sockPath.utf8)
        let maxLen = MemoryLayout.size(ofValue: addr.sun_path) - 1   // leave room for \0
        if pathBytes.count > maxLen { throw ClientError.pathTooLong }
        withUnsafeMutableBytes(of: &addr.sun_path) { rawBuf in
            guard let base = rawBuf.baseAddress else { return }
            let typed = base.assumingMemoryBound(to: UInt8.self)
            for (i, b) in pathBytes.enumerated() { typed[i] = b }
            typed[pathBytes.count] = 0
        }

        let rc = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.connect(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if rc != 0 { throw ClientError.connectRefused(errno: errno) }

        // Send
        let sent = payload.withUnsafeBytes { buf -> Int in
            guard let base = buf.baseAddress else { return -1 }
            return send(fd, base, payload.count, 0)
        }
        if sent != payload.count { throw ClientError.sendFailed(errno: errno) }

        // Recv up to a newline-terminated line
        var received = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        while !received.contains(0x0A) {
            let n = recv(fd, &buf, buf.count, 0)
            if n <= 0 {
                if n == 0 { break }
                throw ClientError.recvFailed(errno: errno)
            }
            received.append(buf, count: n)
            if received.count > 65536 { throw ClientError.replyInvalid("reply too large") }
        }
        guard let nlIdx = received.firstIndex(of: 0x0A) else {
            throw ClientError.replyInvalid("no newline in reply")
        }
        let line = received.prefix(upTo: nlIdx)
        guard let obj = try JSONSerialization.jsonObject(with: line) as? [String: Any] else {
            throw ClientError.replyInvalid("reply not a JSON object")
        }
        return obj
    }
}
