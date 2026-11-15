import Foundation

/// Derives the on-disk path of a Claude Code transcript JSONL file.
///
/// Claude Code stores each conversation at:
/// `$HOME/.claude/projects/<encoded-cwd>/<sessionId>.jsonl`
/// where `<encoded-cwd>` replaces **every non-ASCII-alphanumeric character**
/// with `-`(含 `/`、空格、`~`、`.`、中文;见 BUG-006)。
enum TranscriptPath {
    /// BUG-006:CC 的 projects 目录编码是 cwd 中**所有非 ASCII 字母数字字符**逐个替换为 "-"
    /// (空格/`~`/`.`/中文均如此,实测样本:`Mobile Documents`→`Mobile-Documents`、
    /// `iCloud~md~obsidian`→`iCloud-md-obsidian`、中文目录名→连续 "-")。
    /// 旧实现只替换 "/",含空格等字符的 cwd(如 Obsidian vault 的 iCloud 路径)派生出
    /// 不存在的路径 → seed 会话快照恒 nil → 被 spare 过滤器隐藏。
    static func derive(cwd: String, sessionId: String) -> URL {
        let encodedPath = String(cwd.map { ch in
            (ch.isASCII && (ch.isLetter || ch.isNumber)) ? ch : "-"
        })
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude")
            .appendingPathComponent("projects")
            .appendingPathComponent(encodedPath)
            .appendingPathComponent("\(sessionId).jsonl")
    }

    /// locate 全量扫描的负缓存:整个 projects 目录 miss 后,同一 sessionId 在 TTL 内
    /// 不再重扫(review MEDIUM:零消息 spare 会话每 10s 在主线程重复全量枚举,projects
    /// 目录只增不减属无界增长模式)。命中即清除条目。
    nonisolated(unsafe) private static var locateMissAt: [String: Date] = [:]
    private static let locateMissTTL: TimeInterval = 60
    private static let locateLock = NSLock()

    /// 保底定位:派生路径不存在时,按 `<sessionId>.jsonl` 扫 `~/.claude/projects/*/`。
    /// sessionId 是 UUID 全局唯一,与目录编码规则彻底解耦(CC 规则再变也能找到)。
    /// 仅在派生 miss 时才枚举目录(本机量级 ~10 个),调用方均为 10s 定时刷新,非热路径。
    static func locate(cwd: String, sessionId: String) -> URL? {
        let derived = derive(cwd: cwd, sessionId: sessionId)
        if FileManager.default.fileExists(atPath: derived.path) { return derived }

        locateLock.lock()
        let lastMiss = locateMissAt[sessionId]
        locateLock.unlock()
        if let lastMiss, Date().timeIntervalSince(lastMiss) < locateMissTTL { return nil }

        let projectsDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude")
            .appendingPathComponent("projects")
        if let dirs = try? FileManager.default.contentsOfDirectory(
            at: projectsDir, includingPropertiesForKeys: nil) {
            for dir in dirs {
                let candidate = dir.appendingPathComponent("\(sessionId).jsonl")
                if FileManager.default.fileExists(atPath: candidate.path) {
                    locateLock.lock()
                    locateMissAt[sessionId] = nil
                    locateLock.unlock()
                    return candidate
                }
            }
        }
        locateLock.lock()
        locateMissAt[sessionId] = Date()
        locateLock.unlock()
        return nil
    }
}

/// Result of tailing a transcript file.
struct TranscriptTailChunk: Sendable {
    /// Non-empty lines in file order. When the read offset was past 0,
    /// the first line (which may be a partial JSON record) is dropped.
    let lines: [String]
    let mtime: Date
    let fileSize: UInt64
    /// True when the returned chunk covers the entire file.
    let isFullFile: Bool
}

/// Shared utility for reading the tail of a Claude Code transcript JSONL file.
enum ClaudeTranscriptTailReader {
    /// Read up to `maxBytes` from the end of `url`.
    ///
    /// - Returns: `nil` if the file does not exist or is empty.
    /// - Throws: rethrows `FileManager` / `FileHandle` errors.
    ///   Malformed JSON on individual lines is the caller's problem;
    ///   this function only deals with bytes → lines.
    static func readTail(at url: URL, maxBytes: UInt64 = 65_536) throws -> TranscriptTailChunk? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }

        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let fileSize = (attrs[.size] as? UInt64) ?? 0
        let mtime = (attrs[.modificationDate] as? Date) ?? Date(timeIntervalSince1970: 0)

        guard fileSize > 0 else { return nil }

        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        let chunkSize = min(fileSize, maxBytes)
        let offset = fileSize - chunkSize
        try handle.seek(toOffset: offset)

        guard let data = try handle.readToEnd(),
              let text = String(data: data, encoding: .utf8) else {
            return TranscriptTailChunk(
                lines: [], mtime: mtime, fileSize: fileSize, isFullFile: offset == 0
            )
        }

        var lines = text.components(separatedBy: "\n")
        if offset > 0, !lines.isEmpty {
            lines.removeFirst()
        }
        let filtered = lines.filter { !$0.isEmpty }
        return TranscriptTailChunk(
            lines: filtered,
            mtime: mtime,
            fileSize: fileSize,
            isFullFile: offset == 0
        )
    }

    /// Read up to `maxBytes` from the start of `url`. Used for one-shot
    /// extraction of immutable header data (e.g. first-message timestamp) that
    /// never changes once the JSONL has been appended past it.
    ///
    /// Symmetric to `readTail`: seeks to offset 0, reads forward, and drops
    /// the trailing partial line when the chunk doesn't cover the whole file.
    static func readHead(at url: URL, maxBytes: UInt64 = 4096) throws -> TranscriptTailChunk? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }

        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let fileSize = (attrs[.size] as? UInt64) ?? 0
        let mtime = (attrs[.modificationDate] as? Date) ?? Date(timeIntervalSince1970: 0)

        guard fileSize > 0 else { return nil }

        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        let chunkSize = min(fileSize, maxBytes)
        try handle.seek(toOffset: 0)
        let coversFullFile = chunkSize == fileSize

        guard let data = try handle.read(upToCount: Int(chunkSize)),
              let text = String(data: data, encoding: .utf8) else {
            return TranscriptTailChunk(
                lines: [], mtime: mtime, fileSize: fileSize, isFullFile: coversFullFile
            )
        }

        var lines = text.components(separatedBy: "\n")
        // 未覆盖全文时末尾一行可能是半行 JSON → 丢弃以防止解析失败
        if !coversFullFile, !lines.isEmpty {
            lines.removeLast()
        }
        let filtered = lines.filter { !$0.isEmpty }
        return TranscriptTailChunk(
            lines: filtered,
            mtime: mtime,
            fileSize: fileSize,
            isFullFile: coversFullFile
        )
    }
}
