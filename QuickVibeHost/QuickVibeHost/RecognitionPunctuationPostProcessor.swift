import Foundation

enum RecognitionPunctuationPostProcessor {
    private static let sentenceEndings: Set<Character> = ["。", ".", "！", "!", "？", "?"]
    private static let questionEndings: Set<Character> = ["？", "?"]
    private static let fullStopEndings: Set<Character> = ["。", "."]
    private static let questionPrefixHints = ["是不是", "能不能", "可不可以", "有没有", "要不要", "为什么", "为啥", "怎么", "怎样", "如何", "哪里", "在哪", "在哪里", "在哪儿", "谁", "多少", "是否", "能否", "可否"]
    private static let questionSuffixHints = ["吗"]

    static func apply(_ text: String) -> String {
        guard let last = text.lastNonWhitespaceIndex else { return text }
        let end = text[last]
        let hasSentenceEnding = sentenceEndings.contains(end)
        let body = hasSentenceEnding ? String(text[..<last]) : text

        if isQuestion(body) {
            if questionEndings.contains(end) { return text }
            if fullStopEndings.contains(end) {
                return text.replacingCharacter(at: last, with: "？")
            }
            return text
        }

        if fullStopEndings.contains(end), effectiveCount(body) <= 4 {
            return String(text[..<last]) + text[text.index(after: last)...]
        }
        return text
    }

    private static func isQuestion(_ text: String) -> Bool {
        questionPrefixHints.contains { text.hasPrefix($0) } || questionSuffixHints.contains { text.hasSuffix($0) }
    }

    private static func effectiveCount(_ text: String) -> Int {
        text.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || isCJK($0) }.count
    }

    private static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        (0x4E00...0x9FFF).contains(Int(scalar.value))
    }
}

private extension String {
    var lastNonWhitespaceIndex: Index? {
        indices.reversed().first { !self[$0].isWhitespace }
    }

    func replacingCharacter(at index: Index, with char: Character) -> String {
        var s = self
        s.replaceSubrange(index...index, with: String(char))
        return s
    }
}
