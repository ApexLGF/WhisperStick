import Foundation

enum RecognitionBoostSettings {
    static let enabledKey = "recognitionBoostEnabled"

    static var enabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
    }
}

extension Notification.Name {
    static let dataFileDidChange = Notification.Name("RecognitionBoostDataFileDidChange")
}

struct RecognitionBoostSegment: Codable, Hashable {
    var id: UUID
    var asrText: String
    var createdAt: Date
}

struct RecognitionBoostPendingRevision: Hashable {
    var id: UUID
    var segments: [RecognitionBoostSegment]
    var createdAt: Date

    init(id: UUID, segments: [RecognitionBoostSegment], createdAt: Date) {
        self.id = id
        self.segments = segments
        self.createdAt = createdAt
    }
}

struct RecognitionBoostExtraction: Codable, Hashable {
    var hotwords: [String]
    var readings: [RecognitionBoostReading]
    var deletions: [String]
    var replacements: [RecognitionBoostReplacement]
    var additions: [RecognitionBoostAddition]

    var isEmpty: Bool {
        hotwords.isEmpty && readings.isEmpty && deletions.isEmpty && replacements.isEmpty && additions.isEmpty
    }
}

struct RecognitionBoostReading: Codable, Hashable {
    var wrong: String
    var correct: String
}

struct RecognitionBoostReplacement: Codable, Hashable {
    var wrong: String
    var correct: String
    var hotwordCandidates: [String]
}

struct RecognitionBoostAddition: Codable, Hashable {
    var text: String
    var hotwordCandidates: [String]
}

enum RecognitionBoostHotwordState: String, Codable {
    case candidate
    case active
}

struct StoredRecognitionHotword: Codable {
    var word: String
    var readings: [String]
    var count: Int
    var firstSeenAt: Date
    var lastSeenAt: Date
    var lastUsedAt: Date?
    var state: RecognitionBoostHotwordState

    init(word: String, readings: [String], count: Int, firstSeenAt: Date, lastSeenAt: Date, lastUsedAt: Date? = nil, state: RecognitionBoostHotwordState) {
        self.word = word
        self.readings = readings
        self.count = count
        self.firstSeenAt = firstSeenAt
        self.lastSeenAt = lastSeenAt
        self.lastUsedAt = lastUsedAt
        self.state = state
    }

    private enum CodingKeys: String, CodingKey {
        case word, readings, count, firstSeenAt, lastSeenAt, lastUsedAt, state
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        word = try c.decode(String.self, forKey: .word)
        readings = try c.decode([String].self, forKey: .readings)
        count = try c.decode(Int.self, forKey: .count)
        firstSeenAt = try c.decode(Date.self, forKey: .firstSeenAt)
        lastSeenAt = try c.decode(Date.self, forKey: .lastSeenAt)
        lastUsedAt = try c.decodeIfPresent(Date.self, forKey: .lastUsedAt)
        state = try c.decodeIfPresent(RecognitionBoostHotwordState.self, forKey: .state) ?? (count >= 2 ? .active : .candidate)
    }
}

struct StoredRecognitionRevision: Codable {
    var id: UUID
    var createdAt: Date
    var segments: [RecognitionBoostSegment]
    var revisedText: String
    var extraction: RecognitionBoostExtraction
}

enum RecognitionBoostSimilarity {
    private static let maxSimilarityCells = 250_000

    static func score(_ lhs: String, _ rhs: String) -> Double {
        let a = normalize(lhs)
        let b = normalize(rhs)
        if a == b { return 1 }
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        guard (a.count + 1) * (b.count + 1) <= maxSimilarityCells else { return 0 }
        let aa = Array(a)
        let bb = Array(b)
        let distance = levenshtein(aa, bb)
        return max(0, 1 - Double(distance) / Double(max(aa.count, bb.count)))
    }

    private static func normalize(_ text: String) -> String {
        let mapped = text.lowercased().map { ch -> Character in
            switch ch {
            case "，", "、": ","
            case "。", "！", "？", "；", "：": "."
            case "“", "”": "\""
            case "‘", "’": "'"
            default: ch
            }
        }
        let collapsed = String(mapped).split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return collapsed.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
    }

    private static func levenshtein(_ a: [Character], _ b: [Character]) -> Int {
        var previous = Array(0...b.count)
        for (i, ca) in a.enumerated() {
            var current = [i + 1]
            current.reserveCapacity(b.count + 1)
            for (j, cb) in b.enumerated() {
                current.append(ca == cb ? previous[j] : min(previous[j], previous[j + 1], current[j]) + 1)
            }
            previous = current
        }
        return previous[b.count]
    }
}

struct RecognitionSentencePair {
    var asr: String
    var revised: String
    var score: Double
}

enum RecognitionBoostSentenceMatcher {
    static let sentenceComparisonLimit = 300
    private static let recognitionSentenceMinCharacters = 3
    private static let recognitionSentenceMaxCharacters = 200
    private static let sentenceMatchThreshold = 0.70
    private static let sentenceMatchMargin = 0.08

    static func split(_ text: String) -> [String] {
        text
            .split { ch in
                ch.isNewline || "。！？?!；;".contains(ch)
            }
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { sentence in
                let count = sentence.count
                guard count >= recognitionSentenceMinCharacters,
                      count <= recognitionSentenceMaxCharacters else { return false }
                return sentence.contains { !$0.isWhitespace && !$0.isPunctuation }
            }
    }

    static func pairs(asr: String, revised prompt: String) -> [RecognitionSentencePair] {
        struct Candidate {
            var asrIndex: Int
            var promptIndex: Int
            var pair: RecognitionSentencePair
        }

        let asrSentences = split(asr)
        let promptSentences = split(prompt)
        guard !asrSentences.isEmpty, !promptSentences.isEmpty else { return [] }
        guard asrSentences.count * promptSentences.count <= sentenceComparisonLimit else { return [] }

        let candidates = asrSentences.enumerated().flatMap { asrIndex, asrSentence in
            promptSentences.enumerated().compactMap { promptIndex, promptSentence -> Candidate? in
                let score = sentenceScore(asrSentence, promptSentence)
                guard score >= sentenceMatchThreshold else { return nil }
                return .init(
                    asrIndex: asrIndex,
                    promptIndex: promptIndex,
                    pair: .init(asr: asrSentence, revised: promptSentence, score: score)
                )
            }
        }
        let ambiguousASRIndexes = Set(asrSentences.indices.filter { asrIndex in
            let ranked = candidates
                .filter { $0.asrIndex == asrIndex && $0.pair.score < 1 }
                .sorted { $0.pair.score > $1.pair.score }
            return ranked.count > 1 && ranked[0].pair.score - ranked[1].pair.score < sentenceMatchMargin
        })
        let exactASRIndexes = Set(candidates.filter { $0.pair.score == 1 }.map(\.asrIndex))
        let ambiguousPromptIndexes = Set(promptSentences.indices.filter { promptIndex in
            let ranked = candidates
                .filter { $0.promptIndex == promptIndex && $0.pair.score < 1 && !exactASRIndexes.contains($0.asrIndex) }
                .sorted { $0.pair.score > $1.pair.score }
            return ranked.count > 1 && ranked[0].pair.score - ranked[1].pair.score < sentenceMatchMargin
        })
        var usedASRIndexes = Set<Int>()
        var usedPromptIndexes = Set<Int>()
        var pairs: [RecognitionSentencePair] = []

        for candidate in candidates.sorted(by: { $0.pair.score > $1.pair.score }) {
            guard !usedASRIndexes.contains(candidate.asrIndex),
                  !usedPromptIndexes.contains(candidate.promptIndex) else { continue }
            usedASRIndexes.insert(candidate.asrIndex)
            usedPromptIndexes.insert(candidate.promptIndex)

            if candidate.pair.score < 1,
               !ambiguousASRIndexes.contains(candidate.asrIndex),
               !ambiguousPromptIndexes.contains(candidate.promptIndex) {
                pairs.append(candidate.pair)
            }
        }

        return pairs
    }

    private static func sentenceScore(_ asr: String, _ revised: String) -> Double {
        let raw = RecognitionBoostSimilarity.score(asr, revised)
        guard raw < 1 else { return raw }
        let aa = Array(asr)
        let bb = Array(revised)
        var prefix = 0
        while prefix < aa.count, prefix < bb.count, aa[prefix] == bb[prefix] {
            prefix += 1
        }
        var suffix = 0
        while suffix + prefix < aa.count,
              suffix + prefix < bb.count,
              aa[aa.count - suffix - 1] == bb[bb.count - suffix - 1] {
            suffix += 1
        }
        let sharedEdge = prefix + suffix
        guard sharedEdge >= recognitionSentenceMinCharacters else { return raw }
        let contextRatio = Double(sharedEdge) / Double(max(aa.count, bb.count))
        return min(0.99, raw + contextRatio * 0.10)
    }
}

enum RecognitionBoostPostProcessor {
    private struct Match {
        var range: Range<String.Index>
        var replacement: String
        var hotword: String
        var score: Double
        var order: Int
    }

    static func apply(_ text: String) -> String {
        guard RecognitionBoostSettings.enabled else { return text }
        return apply(text, hotwords: RecognitionBoostStore.shared.activeHotwordRecords(limit: 100)) {
            RecognitionBoostStore.shared.markHotwordsUsed($0)
        }
    }

    static func apply(_ text: String, hotwords: [StoredRecognitionHotword], onUse: (([String]) -> Void)? = nil) -> String {
        let active = filterReverseConflicts(hotwords.filter { $0.state == .active && !$0.readings.isEmpty })
        guard !text.isEmpty, !active.isEmpty else { return text }

        var matches: [Match] = []
        for (order, hotword) in active.enumerated() {
            for reading in hotword.readings where isShortReading(reading) {
                matches.append(contentsOf: matchesFor(reading: reading, replacement: hotword.word, in: text, order: order))
            }
        }

        let chosen = choose(matches)
        guard !chosen.isEmpty else {
            log(before: text, after: text, replacements: 0, activeHotwords: active.count)
            return text
        }

        var out = text
        for match in chosen.sorted(by: { $0.range.lowerBound > $1.range.lowerBound }) {
            out.replaceSubrange(match.range, with: replacementText(match.replacement))
        }
        out = normalizeSpaces(out)
        var seen = Set<String>()
        onUse?(chosen.compactMap { seen.insert($0.hotword.lowercased()).inserted ? $0.hotword : nil })
        log(before: text, after: out, replacements: chosen.count, activeHotwords: active.count)
        return out
    }

    private static func filterReverseConflicts(_ hotwords: [StoredRecognitionHotword]) -> [StoredRecognitionHotword] {
        let words = Dictionary(uniqueKeysWithValues: hotwords.map { ($0.word.lowercased(), $0.word) })
        var blocked = Set<String>()
        for hotword in hotwords {
            let wordKey = hotword.word.lowercased()
            for reading in hotword.readings {
                let readingKey = reading.lowercased()
                guard let otherWord = words[readingKey],
                      let other = hotwords.first(where: { $0.word.lowercased() == readingKey }),
                      other.readings.contains(where: { $0.lowercased() == wordKey }) else { continue }
                let wordIsTech = isTechnicalWord(hotword.word)
                let otherIsTech = isTechnicalWord(otherWord)
                let wordIsCJK = isCJKPhrase(hotword.word)
                let otherIsCJK = isCJKPhrase(otherWord)
                if wordIsTech && otherIsCJK {
                    blocked.insert("\(other.word.lowercased())|\(hotword.word.lowercased())")
                } else if otherIsTech && wordIsCJK {
                    blocked.insert("\(hotword.word.lowercased())|\(other.word.lowercased())")
                } else {
                    blocked.insert("\(hotword.word.lowercased())|\(other.word.lowercased())")
                    blocked.insert("\(other.word.lowercased())|\(hotword.word.lowercased())")
                }
            }
        }
        return hotwords.compactMap { hotword in
            let readings = hotword.readings.filter {
                !blocked.contains("\(hotword.word.lowercased())|\($0.lowercased())")
            }
            guard !readings.isEmpty else { return nil }
            var copy = hotword
            copy.readings = readings
            return copy
        }
    }

    private static func matchesFor(reading: String, replacement: String, in text: String, order: Int) -> [Match] {
        var out: [Match] = []
        var start = text.startIndex
        while let range = text.range(of: reading, options: [.caseInsensitive], range: start..<text.endIndex) {
            if boundariesOK(text, range), !localContains(text, replacement: replacement, around: range) {
                out.append(.init(range: range, replacement: replacement, hotword: replacement, score: 1, order: order))
            }
            start = range.upperBound
        }

        guard out.isEmpty, shouldFuzzy(reading) else { return out }
        let windows = fuzzyWindows(in: text, reading: reading)
        for window in windows {
            let candidate = String(text[window])
            let score = levenshteinRatio(candidate.lowercased(), reading.lowercased())
            if score >= 0.88, boundariesOK(text, window), !localContains(text, replacement: replacement, around: window) {
                out.append(.init(range: window, replacement: replacement, hotword: replacement, score: score, order: order))
            }
        }
        return out
    }

    private static func choose(_ matches: [Match]) -> [Match] {
        var out: [Match] = []
        var groups: [[Match]] = []
        for match in matches {
            if let idx = groups.firstIndex(where: { $0.first?.range == match.range }) {
                groups[idx].append(match)
            } else {
                groups.append([match])
            }
        }
        for group in groups {
            let ranked = group.sorted {
                if $0.score != $1.score { return $0.score > $1.score }
                return $0.order < $1.order
            }
            guard let best = ranked.first else { continue }
            if ranked.count > 1, best.score - ranked[1].score < 0.08 { continue }
            out.append(best)
        }
        return out.sorted {
            if $0.score != $1.score { return $0.score > $1.score }
            return $0.range.lowerBound < $1.range.lowerBound
        }.reduce(into: []) { chosen, match in
            if !chosen.contains(where: { $0.range.overlaps(match.range) }) {
                chosen.append(match)
            }
        }
    }

    private static func fuzzyWindows(in text: String, reading: String) -> [Range<String.Index>] {
        let count = reading.count
        let minLen = max(3, count - 1)
        let maxLen = min(12, count + 1)
        let chars = Array(text.indices) + [text.endIndex]
        guard chars.count > 1, minLen <= maxLen else { return [] }
        var out: [Range<String.Index>] = []
        for i in 0..<(chars.count - 1) {
            for len in minLen...maxLen where i + len < chars.count {
                let r = chars[i]..<chars[i + len]
                guard !crossesSentenceBoundary(String(text[r])) else { continue }
                out.append(r)
            }
        }
        return out
    }

    private static func boundariesOK(_ text: String, _ range: Range<String.Index>) -> Bool {
        !touchesWord(text, before: range.lowerBound) &&
        !touchesWord(text, after: range.upperBound) &&
        !crossesSentenceBoundary(String(text[range]))
    }

    private static func localContains(_ text: String, replacement: String, around range: Range<String.Index>) -> Bool {
        text[sentenceRange(in: text, containing: range)].range(of: replacement, options: [.caseInsensitive]) != nil
    }

    private static func sentenceRange(in text: String, containing range: Range<String.Index>) -> Range<String.Index> {
        let punct: Set<Character> = ["。", "！", "？", "!", "?", "；", ";", "\n"]
        var lower = range.lowerBound
        while lower > text.startIndex {
            let prev = text.index(before: lower)
            if punct.contains(text[prev]) { break }
            lower = prev
        }
        var upper = range.upperBound
        while upper < text.endIndex {
            if punct.contains(text[upper]) { break }
            upper = text.index(after: upper)
        }
        return lower..<upper
    }

    private static func touchesWord(_ text: String, before index: String.Index) -> Bool {
        guard index > text.startIndex else { return false }
        return isWord(text[text.index(before: index)])
    }

    private static func touchesWord(_ text: String, after index: String.Index) -> Bool {
        guard index < text.endIndex else { return false }
        return isWord(text[index])
    }

    private static func isWord(_ c: Character) -> Bool {
        c.isASCII && (c.isLetter || c.isNumber || "._+#/-".contains(c))
    }

    private static func isTechnicalWord(_ text: String) -> Bool {
        text.contains { $0.isASCII && ($0.isLetter || $0.isNumber || "._+#/-".contains($0)) }
    }

    private static func isCJKPhrase(_ text: String) -> Bool {
        text.contains { char in
            char.unicodeScalars.contains { (0x4E00...0x9FFF).contains(Int($0.value)) }
        }
    }

    private static func replacementText(_ text: String) -> String {
        text.contains(where: isWord) ? " \(text) " : text
    }

    private static func isShortReading(_ reading: String) -> Bool {
        if reading.allSatisfy({ $0.unicodeScalars.allSatisfy { (0x4E00...0x9FFF).contains(Int($0.value)) } }) {
            return (2...12).contains(reading.count)
        }
        return reading.split(whereSeparator: \.isWhitespace).count <= 4 && reading.count <= 32
    }

    private static func shouldFuzzy(_ reading: String) -> Bool {
        if reading.allSatisfy({ $0.unicodeScalars.allSatisfy { (0x4E00...0x9FFF).contains(Int($0.value)) } }) {
            return reading.count > 2
        }
        return true
    }

    private static func crossesSentenceBoundary(_ text: String) -> Bool {
        text.contains { "。！？!?；;\n".contains($0) }
    }

    private static func levenshteinRatio(_ a: String, _ b: String) -> Double {
        let aa = Array(a)
        let bb = Array(b)
        guard !aa.isEmpty, !bb.isEmpty else { return aa.isEmpty && bb.isEmpty ? 1 : 0 }
        var prev = Array(0...bb.count)
        for i in 1...aa.count {
            var row = [i] + Array(repeating: 0, count: bb.count)
            for j in 1...bb.count {
                row[j] = aa[i - 1] == bb[j - 1]
                    ? prev[j - 1]
                    : min(prev[j - 1], prev[j], row[j - 1]) + 1
            }
            prev = row
        }
        return 1 - Double(prev[bb.count]) / Double(max(aa.count, bb.count))
    }

    private static func normalizeSpaces(_ text: String) -> String {
        var out = text.replacingOccurrences(of: #" {2,}"#, with: " ", options: .regularExpression)
        out = out.replacingOccurrences(of: #" ([，。！？!?；;、,.])"#, with: "$1", options: .regularExpression)
        out = out.replacingOccurrences(of: #"([（(]) "#, with: "$1", options: .regularExpression)
        return out.trimmingCharacters(in: .whitespaces)
    }

    private static func log(before: String, after: String, replacements: Int, activeHotwords: Int) {
        if ProcessInfo.processInfo.environment["QVH_RECOGNITION_BOOST_DEBUG"] == "1" {
            ClaudeCodeSessionManager.log("[RecognitionBoost] postprocess before=\"\(before)\" after=\"\(after)\" replacements=\(replacements)")
        } else {
            ClaudeCodeSessionManager.log("[RecognitionBoost] postprocess replacements=\(replacements) activeHotwords=\(activeHotwords)")
        }
    }
}

private struct RecognitionBoostFile: Codable {
    var version: Int = 1
    var updatedAt: Date = Date()
    var hotwords: [StoredRecognitionHotword] = []
    var revisions: [StoredRecognitionRevision] = []
}

enum RecognitionBoostExtractor {
    private enum OpTag { case equal, replace, insert, delete }
    private typealias Opcode = (OpTag, Int, Int, Int, Int)
    private typealias Change = (OpTag, [String], [String])
    private static let maxDiffCells = 250_000

    static func extract(asr: String, revised: String) -> RecognitionBoostExtraction {
        let asrTokens = tokenize(asr)
        let revisedTokens = tokenize(revised)
        guard (asrTokens.count + 1) * (revisedTokens.count + 1) <= maxDiffCells else {
            return emptyExtraction()
        }
        var hotwords: [String] = []
        var readings: [RecognitionBoostReading] = []
        var replacements: [RecognitionBoostReplacement] = []
        var additions: [RecognitionBoostAddition] = []
        var deletions: [String] = []

        for (tag, oldTokens, newTokens) in mergeAdjacentChanges(opcodes(asrTokens, revisedTokens), asrTokens, revisedTokens) {
            let oldClean = joinTokens(oldTokens)
            let newClean = joinTokens(newTokens)
            switch tag {
            case .replace:
                guard !oldClean.isEmpty || !newClean.isEmpty else { continue }
                let candidates = isTightReplacementPair(wrong: oldClean, correct: newClean)
                    ? candidatesFrom(newClean, allowChinese: true, reading: oldClean)
                    : []
                replacements.append(.init(wrong: oldClean, correct: newClean, hotwordCandidates: candidates))
                if !oldClean.isEmpty, !candidates.isEmpty {
                    readings.append(.init(wrong: oldClean, correct: newClean))
                }
                hotwords.append(contentsOf: candidates)
            case .insert:
                let candidates = candidatesFrom(newClean, allowChinese: false)
                guard !candidates.isEmpty else { continue }
                additions.append(.init(text: newClean, hotwordCandidates: candidates))
            case .delete:
                if !oldClean.isEmpty { deletions.append(oldClean) }
            case .equal:
                break
            }
        }

        return .init(
            hotwords: dedupePhrases(hotwords),
            readings: dedupe(readings),
            deletions: dedupe(deletions),
            replacements: replacements,
            additions: additions
        )
    }

    private static func emptyExtraction() -> RecognitionBoostExtraction {
        .init(hotwords: [], readings: [], deletions: [], replacements: [], additions: [])
    }

    private static func tokenize(_ text: String) -> [String] {
        var out: [String] = []
        var i = text.startIndex
        while i < text.endIndex {
            let ch = text[i]
            if ch.isASCII, ch.isLetter {
                var j = text.index(after: i)
                while j < text.endIndex {
                    let c = text[j]
                    if c.isASCII, c.isLetter || c.isNumber || "._+#/-".contains(c) {
                        j = text.index(after: j)
                    } else {
                        break
                    }
                }
                out.append(String(text[i..<j]))
                i = j
            } else if ch.isNumber {
                var j = text.index(after: i)
                var dotSeen = false
                while j < text.endIndex {
                    let c = text[j]
                    if c.isNumber {
                        j = text.index(after: j)
                    } else if c == ".", !dotSeen {
                        dotSeen = true
                        j = text.index(after: j)
                    } else {
                        break
                    }
                }
                out.append(String(text[i..<j]))
                i = j
            } else if ch.isWhitespace {
                var j = text.index(after: i)
                while j < text.endIndex, text[j].isWhitespace {
                    j = text.index(after: j)
                }
                out.append(String(text[i..<j]))
                i = j
            } else {
                out.append(String(ch))
                i = text.index(after: i)
            }
        }
        return out
    }

    private static func opcodes(_ a: [String], _ b: [String]) -> [Opcode] {
        let n = a.count
        let m = b.count
        var dp = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        if n > 0, m > 0 {
            for i in stride(from: n - 1, through: 0, by: -1) {
                for j in stride(from: m - 1, through: 0, by: -1) {
                    dp[i][j] = a[i] == b[j] ? dp[i + 1][j + 1] + 1 : max(dp[i + 1][j], dp[i][j + 1])
                }
            }
        }

        var pairs: [(Int, Int)] = []
        var i = 0
        var j = 0
        while i < n, j < m {
            if a[i] == b[j] {
                pairs.append((i, j))
                i += 1
                j += 1
            } else if dp[i + 1][j] >= dp[i][j + 1] {
                i += 1
            } else {
                j += 1
            }
        }

        var result: [Opcode] = []
        var ai = 0
        var bj = 0
        for (ei, ej) in pairs {
            appendChange(&result, ai, ei, bj, ej)
            result.append((.equal, ei, ei + 1, ej, ej + 1))
            ai = ei + 1
            bj = ej + 1
        }
        appendChange(&result, ai, n, bj, m)
        return coalesceEquals(result)
    }

    private static func appendChange(_ result: inout [Opcode], _ i1: Int, _ i2: Int, _ j1: Int, _ j2: Int) {
        guard i1 < i2 || j1 < j2 else { return }
        let tag: OpTag = i1 == i2 ? .insert : (j1 == j2 ? .delete : .replace)
        result.append((tag, i1, i2, j1, j2))
    }

    private static func coalesceEquals(_ opcodes: [Opcode]) -> [Opcode] {
        var out: [Opcode] = []
        for op in opcodes {
            if let last = out.last, last.0 == .equal, op.0 == .equal, last.2 == op.1, last.4 == op.3 {
                out[out.count - 1] = (.equal, last.1, op.2, last.3, op.4)
            } else {
                out.append(op)
            }
        }
        return out
    }

    private static func mergeAdjacentChanges(_ opcodes: [Opcode], _ asrTokens: [String], _ revisedTokens: [String]) -> [Change] {
        var merged: [Change] = []
        var pending: Change?

        func flush() {
            if let pending {
                merged.append(pending)
            }
            pending = nil
        }

        for (tag, i1, i2, j1, j2) in opcodes {
            if tag == .equal {
                let gap = joinTokens(Array(asrTokens[i1..<i2]))
                if gap.isEmpty, var p = pending {
                    p.1.append(contentsOf: asrTokens[i1..<i2])
                    p.2.append(contentsOf: revisedTokens[j1..<j2])
                    pending = p
                } else {
                    flush()
                }
                continue
            }

            let old = Array(asrTokens[i1..<i2])
            let new = Array(revisedTokens[j1..<j2])
            if var p = pending {
                p.1.append(contentsOf: old)
                p.2.append(contentsOf: new)
                if p.0 != tag { p.0 = .replace }
                pending = p
            } else {
                pending = (tag, old, new)
            }
        }
        flush()
        return merged
    }

    private static func joinTokens(_ tokens: [String]) -> String {
        clean(tokens.joined())
    }

    private static func clean(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters).union(CharacterSet(charactersIn: "_")))
    }

    private static func isTightReplacementPair(wrong: String, correct: String) -> Bool {
        guard !wrong.isEmpty, !correct.isEmpty else { return false }
        guard !wrong.contains(where: { "，、。！？?!；;\n\r".contains($0) }) else { return false }
        return wrong.count <= max(correct.count * 2, 8)
    }

    private static func candidatesFrom(_ text: String, allowChinese: Bool, reading: String? = nil) -> [String] {
        let text = clean(text)
        guard !text.isEmpty else { return [] }
        var out: [String] = []
        let tokens = tokenize(text)

        var phrase: [String] = []
        func flushPhrase() {
            if phrase.count >= 2 {
                let s = phrase.joined(separator: " ")
                if isLikelyProperNoun(s, allowChinese: allowChinese) { out.append(s) }
            }
            phrase.removeAll()
        }

        for token in tokens {
            if isLatinToken(token) {
                if token.count >= 2 { out.append(token) }
                phrase.append(token)
            } else if token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                continue
            } else {
                flushPhrase()
            }
        }
        flushPhrase()

        if allowChinese, out.isEmpty {
            let chinese = text.filter { isCJK($0) }
            let phrase = String(chinese)
            if isLikelyChineseHotword(phrase, reading: reading) { out.append(phrase) }
        }
        if out.isEmpty, isLikelyProperNoun(text, allowChinese: allowChinese, reading: reading) {
            out.append(text)
        }
        return dedupe(out)
    }

    private static func isLikelyProperNoun(_ token: String, allowChinese: Bool, reading: String? = nil) -> Bool {
        guard !token.isEmpty else { return false }
        if isLatinToken(token) { return token.count >= 2 }
        if allowChinese, token.allSatisfy(isCJK) { return isLikelyChineseHotword(token, reading: reading) }
        return token.contains { $0.isLetter } && token.count >= 2 && !token.allSatisfy(\.isNumber)
    }

    private static func isLikelyChineseHotword(_ token: String, reading: String?) -> Bool {
        let word = stripChineseFillerSuffix(token)
        guard (2...12).contains(word.count), let reading else { return false }
        let spoken = stripChineseFillerSuffix(String(reading.filter { isCJK($0) }))
        guard spoken.count == word.count else { return false }
        return pinyinSyllables(spoken) == pinyinSyllables(word)
    }

    private static func stripChineseFillerSuffix(_ text: String) -> String {
        let suffixes = ["一下吧", "一下吗", "一下", "吧", "吗", "呢", "的", "了"]
        var out = text
        while let suffix = suffixes.first(where: { out.hasSuffix($0) }) {
            out.removeLast(suffix.count)
        }
        return out
    }

    private static func pinyinSyllables(_ text: String) -> [String] {
        let mutable = NSMutableString(string: text) as CFMutableString
        CFStringTransform(mutable, nil, kCFStringTransformMandarinLatin, false)
        CFStringTransform(mutable, nil, kCFStringTransformStripDiacritics, false)
        return (mutable as String).lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
    }

    private static func isLatinToken(_ token: String) -> Bool {
        guard let first = token.first, first.isASCII, first.isLetter else { return false }
        return token.allSatisfy { c in
            c.isASCII && (c.isLetter || c.isNumber || "._+#/-".contains(c))
        }
    }

    private static func isCJK(_ c: Character) -> Bool {
        c.unicodeScalars.allSatisfy { (0x4E00...0x9FFF).contains(Int($0.value)) }
    }

    private static func dedupe<T: Hashable>(_ items: [T]) -> [T] {
        var seen = Set<T>()
        var out: [T] = []
        for item in items where seen.insert(item).inserted {
            out.append(item)
        }
        return out
    }

    private static func dedupePhrases(_ items: [String]) -> [String] {
        let unique = dedupe(items)
        return unique.filter { word in
            let needle = word.lowercased()
            return !unique.contains { phrase in
                let p = phrase.lowercased()
                return p != needle && p.split(separator: " ").contains(Substring(needle))
            }
        }
    }
}

enum RecognitionBoostLearner {
    private static let matchThreshold = 0.70

    static func extraction(asr: String, revised: String) -> RecognitionBoostExtraction? {
        if RecognitionBoostSentenceMatcher.split(asr).count != RecognitionBoostSentenceMatcher.split(revised).count,
           let extraction = sentenceExtraction(asr: asr, revised: revised) {
            return extraction
        }

        let similarity = RecognitionBoostSimilarity.score(asr, revised)
        if similarity >= matchThreshold {
            guard similarity < 1 else { return nil }
            let extraction = RecognitionBoostExtractor.extract(asr: asr, revised: revised)
            return extraction.isEmpty ? nil : extraction
        }

        return sentenceExtraction(asr: asr, revised: revised)
    }

    private static func sentenceExtraction(asr: String, revised: String) -> RecognitionBoostExtraction? {
        let pairs = RecognitionBoostSentenceMatcher.pairs(asr: asr, revised: revised)
        guard !pairs.isEmpty else { return nil }
        let extraction = mergedExtraction(from: pairs)
        return extraction.isEmpty ? nil : extraction
    }

    static func learn(
        id: UUID,
        segments: [RecognitionBoostSegment],
        createdAt: Date,
        revisedText: String,
        sid: String = "",
        source: String,
        shouldMerge: ((String, String) -> Bool)? = nil
    ) {
        let asr = segments.map(\.asrText).joined()
        guard !asr.isEmpty else { return }
        let sidPart = sid.isEmpty ? "" : " sid=\(sid.prefix(8))"
        if let shouldMerge, !shouldMerge(asr, revisedText) {
            ClaudeCodeSessionManager.log("[RecognitionBoost] \(source) skipped reason=dedupe\(sidPart)")
            return
        }
        guard let extraction = extraction(asr: asr, revised: revisedText) else {
            ClaudeCodeSessionManager.log("[RecognitionBoost] \(source) skipped reason=no-extraction\(sidPart) asr=\(asr.count) revised=\(revisedText.count)")
            return
        }
        ClaudeCodeSessionManager.log("[RecognitionBoost] \(source) chars asr=\(asr.count) revised=\(revisedText.count) hotwords=\(extraction.hotwords.count) readings=\(extraction.readings.count)\(sidPart)")
        RecognitionBoostStore.shared.merge(
            extraction,
            revision: .init(id: id, segments: segments, createdAt: createdAt),
            revisedText: revisedText
        )
    }

    private static func mergedExtraction(from pairs: [RecognitionSentencePair]) -> RecognitionBoostExtraction {
        let extractions = pairs.map {
            RecognitionBoostExtractor.extract(asr: $0.asr, revised: $0.revised)
        }
        return .init(
            hotwords: dedupe(extractions.flatMap { $0.hotwords }),
            readings: dedupe(extractions.flatMap { $0.readings }),
            deletions: dedupe(extractions.flatMap { $0.deletions }),
            replacements: dedupe(extractions.flatMap { $0.replacements }),
            additions: dedupe(extractions.flatMap { $0.additions })
        )
    }

    private static func dedupe<T: Hashable>(_ items: [T]) -> [T] {
        var seen = Set<T>()
        return items.filter { seen.insert($0).inserted }
    }
}

final class RecognitionBoostStore {
    static let shared = RecognitionBoostStore()

    private let fileURL: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let lock = NSLock()

    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            self.fileURL = appSupport.appendingPathComponent("QuickVibeHost/recognition-boost.json")
        }
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
    }

    func merge(_ extraction: RecognitionBoostExtraction, revision: RecognitionBoostPendingRevision, revisedText: String) {
        guard RecognitionBoostSettings.enabled else { return }
        locked {
            mergeLocked(extraction, revision: revision, revisedText: revisedText)
        }
    }

    private func mergeLocked(_ extraction: RecognitionBoostExtraction, revision: RecognitionBoostPendingRevision, revisedText: String) {
        var file = load()
        let now = Date()
        removeExpiredHotwords(from: &file, now: now)
        let readingsByCorrect = Dictionary(grouping: extraction.readings, by: { $0.correct.lowercased() })
        for word in extraction.hotwords {
            let key = word.lowercased()
            let readings = readingsByCorrect[key]?.map(\.wrong) ?? []
            if let idx = file.hotwords.firstIndex(where: { $0.word.lowercased() == key }) {
                file.hotwords[idx].count += 1
                file.hotwords[idx].lastSeenAt = now
                file.hotwords[idx].readings = dedupe(file.hotwords[idx].readings + readings)
                if file.hotwords[idx].count >= 2 || activatesImmediately(word: word, readings: file.hotwords[idx].readings) {
                    file.hotwords[idx].state = .active
                }
            } else {
                let readings = dedupe(readings)
                file.hotwords.append(.init(
                    word: word,
                    readings: readings,
                    count: 1,
                    firstSeenAt: now,
                    lastSeenAt: now,
                    state: activatesImmediately(word: word, readings: readings) ? .active : .candidate
                ))
            }
        }
        file.revisions.insert(.init(id: revision.id, createdAt: revision.createdAt, segments: revision.segments, revisedText: revisedText, extraction: extraction), at: 0)
        if file.revisions.count > 100 {
            file.revisions = Array(file.revisions.prefix(100))
        }
        file.updatedAt = now
        save(file)
        ClaudeCodeSessionManager.log("[RecognitionBoost] merge hotwords=\(extraction.hotwords.count) total=\(file.hotwords.count) revisions=\(file.revisions.count)")
    }

    func activeHotwords(limit: Int = 50) -> [String] {
        guard RecognitionBoostSettings.enabled, limit > 0 else { return [] }
        return locked {
            var seen = Set<String>()
            return activeHotwordRecordsLocked(limit: .max)
                .compactMap { item in
                    let key = item.word.lowercased()
                    guard seen.insert(key).inserted else { return nil }
                    return item.word
                }
                .prefix(limit)
                .map { $0 }
        }
    }

    func activeHotwordRecords(limit: Int = 100) -> [StoredRecognitionHotword] {
        guard RecognitionBoostSettings.enabled, limit > 0 else { return [] }
        return locked {
            activeHotwordRecordsLocked(limit: limit)
        }
    }

    private func activeHotwordRecordsLocked(limit: Int) -> [StoredRecognitionHotword] {
        var file = load()
        let oldCount = file.hotwords.count
        removeExpiredHotwords(from: &file, now: Date())
        if file.hotwords.count != oldCount {
            file.updatedAt = Date()
            save(file)
        }
        var seen = Set<String>()
        return Array(file.hotwords
            .filter { $0.state == .active }
            .sorted {
                if $0.count != $1.count { return $0.count > $1.count }
                let lhsUsedAt = $0.lastUsedAt ?? .distantPast
                let rhsUsedAt = $1.lastUsedAt ?? .distantPast
                if lhsUsedAt != rhsUsedAt { return lhsUsedAt > rhsUsedAt }
                return $0.lastSeenAt > $1.lastSeenAt
            }
            .filter { seen.insert($0.word.lowercased()).inserted }
            .prefix(limit))
    }

    func markHotwordsUsed(_ words: [String], at now: Date = Date()) {
        guard RecognitionBoostSettings.enabled, !words.isEmpty else { return }
        locked {
            var file = load()
            let keys = Set(words.map { $0.lowercased() })
            var changed = false
            for idx in file.hotwords.indices where file.hotwords[idx].state == .active && keys.contains(file.hotwords[idx].word.lowercased()) {
                file.hotwords[idx].lastUsedAt = now
                changed = true
            }
            if changed {
                file.updatedAt = now
                save(file)
            }
        }
    }

    func clear() {
        locked {
            try? FileManager.default.removeItem(at: fileURL)
        }
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .dataFileDidChange, object: nil)
        }
        ClaudeCodeSessionManager.log("[RecognitionBoost] cleared")
    }

    func hasDataFile() -> Bool {
        locked {
            FileManager.default.fileExists(atPath: fileURL.path)
        }
    }

    func counts() -> (learned: Int, active: Int) {
        locked {
            var file = load()
            let oldCount = file.hotwords.count
            removeExpiredHotwords(from: &file, now: Date())
            if file.hotwords.count != oldCount {
                file.updatedAt = Date()
                save(file)
            }
            return (file.hotwords.count, file.hotwords.filter { $0.state == .active }.count)
        }
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    private func load() -> RecognitionBoostFile {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return RecognitionBoostFile() }
        do {
            return try decoder.decode(RecognitionBoostFile.self, from: Data(contentsOf: fileURL))
        } catch {
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
            let backup = fileURL.deletingLastPathComponent().appendingPathComponent("\(fileURL.lastPathComponent).corrupt-\(stamp)")
            try? FileManager.default.moveItem(at: fileURL, to: backup)
            ClaudeCodeSessionManager.log("[RecognitionBoost] corrupt store backed up")
            return RecognitionBoostFile()
        }
    }

    private func save(_ file: RecognitionBoostFile) {
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try encoder.encode(file).write(to: fileURL, options: .atomic)
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .dataFileDidChange, object: nil)
            }
        } catch {
            ClaudeCodeSessionManager.log("[RecognitionBoost] save failed: \(error.localizedDescription)")
        }
    }

    private func removeExpiredHotwords(from file: inout RecognitionBoostFile, now: Date) {
        let candidateCutoff = now.addingTimeInterval(-90 * 24 * 60 * 60)
        let activeCutoff = now.addingTimeInterval(-90 * 24 * 60 * 60)
        file.hotwords.removeAll {
            switch $0.state {
            case .candidate:
                return $0.lastSeenAt < candidateCutoff
            case .active:
                return max($0.lastSeenAt, $0.lastUsedAt ?? $0.firstSeenAt) < activeCutoff
            }
        }
    }

    private func activatesImmediately(word: String, readings: [String]) -> Bool {
        readings.isEmpty == false &&
        word.split(whereSeparator: \.isWhitespace).count >= 2 &&
        word.contains { $0.isASCII && $0.isLetter }
    }

    private func dedupe<T: Hashable>(_ items: [T]) -> [T] {
        var seen = Set<T>()
        return items.filter { seen.insert($0).inserted }
    }
}
