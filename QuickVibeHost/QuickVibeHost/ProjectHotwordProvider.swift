import Foundation

enum ProjectHotwordProvider {
    private struct CacheEntry {
        var key: String
        var createdAt: Date
        var words: [String]
    }

    private struct SourceFileCandidate {
        var url: URL
        var relativePath: String
        var size: UInt64
        var modifiedAt: Date
        var depth: Int
    }

    private static let cacheTTL: TimeInterval = 180
    private static let maxScannedPaths = 5000
    private static let maxSourceCandidates = 200
    private static let maxSourceFileBytes: UInt64 = 512 * 1024
    private static let maxSourceReadBytes = 1024 * 1024
    private static let maxSourceReadBytesPerFile = 32 * 1024
    private static let lock = NSLock()
    private static var cache: CacheEntry?

    static func hotwords(for session: HookSession, limit: Int = 50) -> [String] {
        guard limit > 0 else { return [] }
        let cwd = session.cwd
        guard !cwd.isEmpty, FileManager.default.fileExists(atPath: cwd) else {
            return Array(clean([session.projectName]).prefix(limit))
        }

        let projectName = URL(fileURLWithPath: cwd).lastPathComponent
        let key = "\(cwd)\n\(projectName)"
        let now = Date()

        lock.lock()
        if let cache, cache.key == key, now.timeIntervalSince(cache.createdAt) < cacheTTL {
            let words = cache.words
            lock.unlock()
            return Array(words.prefix(limit))
        }
        lock.unlock()

        let scanned = filesystemFallbackWords(cwd: cwd)
        let words = pickHotwords(
            projectName: projectName,
            files: scanned.files,
            directories: scanned.directories,
            sourceIdentifiers: sourceIdentifiers(fileCandidates: scanned.sourceFiles),
            dependencies: dependencyWords(cwd: cwd),
            limit: limit
        )

        lock.lock()
        cache = CacheEntry(key: key, createdAt: now, words: words)
        lock.unlock()

        return words
    }

    private static func filesystemFallbackWords(cwd: String) -> (files: [String], directories: [String], sourceFiles: [SourceFileCandidate]) {
        let root = URL(fileURLWithPath: cwd)
        let skipped: Set<String> = [
            ".git", ".build", ".swiftpm", "node_modules", "Pods", "DerivedData",
            "target", "build", ".gradle", "__pycache__", "pycache",
            "docs", "logs", "results", "scripts"
        ]
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return ([], [], []) }

        var urls: [URL] = []
        var sourceFiles: [SourceFileCandidate] = []
        for case let url as URL in enumerator {
            let name = url.lastPathComponent
            if skipped.contains(name) || shouldSkipDirectory(name) {
                enumerator.skipDescendants()
                continue
            }
            let relative = url.path.replacingOccurrences(of: root.path + "/", with: "")
            guard relative.split(separator: "/").count <= 8 else {
                enumerator.skipDescendants()
                continue
            }
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey])
            let isDirectory = values?.isDirectory ?? false
            if urls.count < maxScannedPaths, isDirectory || !shouldSkipFile(name) {
                urls.append(url)
                if urls.count >= maxScannedPaths { break }
            }
            if !isDirectory {
                let size = UInt64(values?.fileSize ?? 0)
                if isSourceFile(name),
                   size <= maxSourceFileBytes,
                   !shouldSkipSourcePath(relative) {
                    sourceFiles.append(SourceFileCandidate(
                        url: url,
                        relativePath: relative,
                        size: size,
                        modifiedAt: values?.contentModificationDate ?? .distantPast,
                        depth: relative.split(separator: "/").count
                    ))
                }
            }
        }

        var files: [String] = []
        var directories: [String] = []
        let sourceURLs = sourceFiles.map(\.url)
        let wordURLs = (urls + sourceURLs).reduce(into: (seen: Set<String>(), urls: [URL]())) { result, url in
            if result.seen.insert(url.path).inserted {
                result.urls.append(url)
            }
        }.urls
        for url in wordURLs.sorted(by: { $0.path < $1.path }) {
            let name = url.lastPathComponent
            if shouldSkipFile(name) {
                continue
            }
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey])
            let isDirectory = values?.isDirectory ?? false
            if isDirectory {
                directories.append(name)
                directories.append(contentsOf: splitIdentifier(name))
            } else {
                files.append(fileStem(name))
            }
        }
        return (files, directories, sourceFiles)
    }

    private static func shouldSkipDirectory(_ name: String) -> Bool {
        let lower = name.lowercased()
        return lower.hasSuffix(".xcodeproj")
            || lower.hasSuffix(".xcworkspace")
            || lower.hasSuffix(".xcassets")
            || lower.hasSuffix(".imageset")
            || lower.hasSuffix(".appiconset")
            || lower.hasSuffix(".xcframework")
    }

    private static func shouldSkipFile(_ name: String) -> Bool {
        let lower = name.lowercased()
        let skippedSuffixes = [
            ".log", ".err", ".jsonl", ".json", ".md", ".pyc", ".txt",
            ".png", ".jpg", ".jpeg", ".icns", ".pdf"
        ]
        return skippedSuffixes.contains { lower.hasSuffix($0) }
    }

    private static func fileStem(_ name: String) -> String {
        var stem = URL(fileURLWithPath: name).deletingPathExtension().lastPathComponent
        if stem.lowercased().hasSuffix(".generated") {
            stem.removeLast(".generated".count)
        }
        return stem
    }

    private static func isSourceFile(_ name: String) -> Bool {
        let ext = "." + URL(fileURLWithPath: name).pathExtension.lowercased()
        let sourceExtensions: Set<String> = [
            ".swift", ".ts", ".tsx", ".js", ".jsx", ".vue", ".py", ".rs", ".go",
            ".java", ".kt", ".m", ".mm", ".h", ".hpp", ".cpp", ".c"
        ]
        return sourceExtensions.contains(ext)
    }

    private static func shouldSkipSourcePath(_ relativePath: String) -> Bool {
        let parts = relativePath.lowercased().split(separator: "/").map(String.init)
        let skipped: Set<String> = ["test", "tests", "spec", "mock", "mocks", "fixture", "fixtures", "generated"]
        if parts.contains(where: { skipped.contains($0) }) { return true }
        return relativePath.lowercased().contains(".generated.")
    }

    private static func sourceIdentifiers(fileCandidates: [SourceFileCandidate]) -> [String] {
        let selected = fileCandidates
            .sorted {
                if $0.modifiedAt != $1.modifiedAt { return $0.modifiedAt > $1.modifiedAt }
                if $0.size != $1.size { return $0.size < $1.size }
                return $0.depth < $1.depth
            }
            .prefix(maxSourceCandidates)
            .prefix(50)

        var remaining = maxSourceReadBytes
        var counts: [String: [String: Int]] = [:]
        var firstSeen: [String: Int] = [:]
        for candidate in selected {
            guard remaining > 0 else { continue }
            let n = min(Int(candidate.size), min(maxSourceReadBytesPerFile, remaining))
            guard let data = readPrefix(candidate.url, byteCount: n) else { continue }
            remaining -= data.count
            let text = String(decoding: data, as: UTF8.self)
            for word in extractIdentifiers(from: text) {
                let key = word.lowercased()
                if firstSeen[key] == nil { firstSeen[key] = firstSeen.count }
                counts[key, default: [:]][word, default: 0] += 1
            }
        }

        return counts
            .map { key, variants in
                let canonical = variants.sorted {
                    if $0.value != $1.value { return $0.value > $1.value }
                    if $0.key.contains(where: { $0.isUppercase }) != $1.key.contains(where: { $0.isUppercase }) {
                        return $0.key.contains(where: { $0.isUppercase })
                    }
                    return $0.key < $1.key
                }[0].key
                return (key: key, word: canonical)
            }
            .sorted {
                (firstSeen[$0.key] ?? Int.max) < (firstSeen[$1.key] ?? Int.max)
            }
            .map(\.word)
    }

    private static func readPrefix(_ url: URL, byteCount: Int) -> Data? {
        guard byteCount > 0, let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        return try? handle.read(upToCount: byteCount)
    }

    private static func extractIdentifiers(from text: String) -> [String] {
        let pattern = #"\b[A-Za-z_][A-Za-z0-9_]{2,63}\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard let range = Range(match.range, in: text) else { return nil }
            let word = String(text[range])
            return shouldSkipSourceIdentifier(word) ? nil : word
        }
    }

    private static func shouldSkipSourceIdentifier(_ word: String) -> Bool {
        let lower = word.lowercased()
        let blocked: Set<String> = [
            "func", "let", "var", "class", "struct", "enum", "return", "import",
            "private", "public", "internal", "static", "final", "extension",
            "if", "else", "for", "while", "switch", "case", "break", "continue",
            "true", "false", "nil", "null", "undefined", "async", "await",
            "data", "text", "value", "item", "result", "error", "string", "number"
        ]
        guard !blocked.contains(lower) else { return true }
        guard word.count >= 3, word.count <= 64 else { return true }
        guard word.contains(where: { $0.isLetter }) else { return true }
        if word.allSatisfy({ $0.isLowercase || $0 == "_" }), word.count <= 4 { return true }
        return false
    }

    private static func pickHotwords(projectName: String, files: [String], directories: [String], sourceIdentifiers: [String], dependencies: [String], limit: Int) -> [String] {
        var out: [String] = []
        out.append(contentsOf: clean([projectName]).prefix(1))
        out.append(contentsOf: clean(files + directories).prefix(20))
        out.append(contentsOf: clean(sourceIdentifiers).prefix(20))
        out.append(contentsOf: clean(dependencies).prefix(9))
        return Array(clean(out).prefix(limit))
    }

    private static func dependencyWords(cwd: String) -> [String] {
        let root = URL(fileURLWithPath: cwd)
        var out: [String] = []
        out.append(contentsOf: packageJSONWords(root.appendingPathComponent("package.json")))
        out.append(contentsOf: cargoTomlWords(root.appendingPathComponent("Cargo.toml")))
        out.append(contentsOf: simpleDependencyFileWords(root.appendingPathComponent("requirements.txt")))
        return out
    }

    private static func packageJSONWords(_ url: URL) -> [String] {
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        var out: [String] = []
        for key in ["dependencies", "devDependencies", "peerDependencies"] {
            if let deps = obj[key] as? [String: Any] {
                out.append(contentsOf: deps.keys)
            }
        }
        return out
    }

    private static func cargoTomlWords(_ url: URL) -> [String] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        var out: [String] = []
        var inDependencies = false
        for raw in text.split(separator: "\n").prefix(300) {
            let line = raw.split(separator: "#", maxSplits: 1).first.map(String.init) ?? ""
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("[") {
                inDependencies = trimmed == "[dependencies]"
                continue
            }
            guard inDependencies else { continue }
            let name = trimmed.split(whereSeparator: { "=<>~![](),; ".contains($0) }).first.map(String.init) ?? ""
            if !name.isEmpty { out.append(name) }
        }
        return out
    }

    private static func simpleDependencyFileWords(_ url: URL) -> [String] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        var out: [String] = []
        for raw in text.split(separator: "\n").prefix(300) {
            let line = raw.split(separator: "#", maxSplits: 1).first.map(String.init) ?? ""
            let name = line.split(whereSeparator: { "=<>~![](),; ".contains($0) }).first.map(String.init) ?? ""
            if !name.isEmpty { out.append(name) }
        }
        return out
    }

    private static func splitIdentifier(_ value: String) -> [String] {
        value
            .replacingOccurrences(of: "_", with: "-")
            .replacingOccurrences(of: ".", with: "-")
            .split(separator: "-")
            .map(String.init)
            .filter { $0.count >= 2 }
    }

    private static func clean(_ candidates: [String?]) -> [String] {
        clean(candidates.compactMap { $0 })
    }

    private static func clean(_ candidates: [String]) -> [String] {
        let blocked: Set<String> = [
            ".git", ".build", ".swiftpm", "node_modules", "Pods", "DerivedData",
            "src", "lib", "test", "tests", "main", "index", "app", "utils", "common",
            "README", "swift", "json", "md", "py", "txt", "yml", "yaml",
            "package", "packages", "project", "projects", "requirements",
            "xcodeproj", "xcworkspace", "xcshareddata", "swiftpm", "generated",
            "sources", "resources", "fixtures", "thirdparty", "third-party", "tools"
        ]
        let blockedKeys = Set(blocked.map { $0.lowercased() })
        var seen = Set<String>()
        var out: [String] = []
        for raw in candidates {
            let word = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard word.count >= 2, word.count <= 64 else { continue }
            let key = word.lowercased()
            guard !blockedKeys.contains(key) else { continue }
            if !word.contains(where: { $0.isASCII }), word.count > 16 { continue }
            guard !word.allSatisfy(\.isNumber) else { continue }
            guard word.contains(where: { $0.isLetter }) else { continue }
            guard seen.insert(key).inserted else { continue }
            out.append(word)
        }
        return out
    }
}
