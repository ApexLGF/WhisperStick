import Foundation

enum ASRHotwordInputParser {
    static func parse(_ text: String, limit: Int) -> [String] {
        guard limit > 0 else { return [] }
        let hasPhraseSeparators = text.contains(where: { $0.isNewline || $0 == "," || $0 == "，" })
        let normalized = text
            .replacingOccurrences(of: "，", with: "\n")
            .replacingOccurrences(of: ",", with: "\n")
        var seen = Set<String>()
        var out: [String] = []
        let parts = hasPhraseSeparators
            ? normalized.split(whereSeparator: \.isNewline)
            : normalized.split(whereSeparator: \.isWhitespace)
        for raw in parts {
            let word = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard (2...64).contains(word.count), word.contains(where: \.isLetter) else { continue }
            guard seen.insert(word.lowercased()).inserted else { continue }
            out.append(word)
            if out.count >= limit { break }
        }
        return out
    }
}
