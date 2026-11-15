import Foundation

enum ProgrammingTextPostProcessor {
    struct Analysis {
        var text: String
        var replacedTerms: [String]
    }

    private static let extensions: Set<String> = [
        "swift", "ts", "tsx", "js", "jsx", "vue", "py", "rs", "go", "json",
        "md", "toml", "yaml", "yml", "css", "html", "sh"
    ]

    static func apply(_ text: String, terms: [String] = []) -> String {
        analyze(text, terms: terms).text
    }

    static func analyze(_ text: String, terms: [String] = []) -> Analysis {
        guard !text.isEmpty else { return Analysis(text: text, replacedTerms: []) }
        let termResult = normalizeTerms(text, terms: terms)
        var out = termResult.text
        out = normalizePaths(out)
        out = normalizeVersions(out)
        out = normalizePorts(out)
        return Analysis(text: out, replacedTerms: termResult.replacedTerms)
    }

    private static func normalizeTerms(_ text: String, terms: [String]) -> Analysis {
        var forms: [(spoken: String, canonical: String)] = []
        var seen = Set<String>()
        for term in terms {
            let canonical = term.trimmingCharacters(in: .whitespacesAndNewlines)
            guard canonical.count >= 3 else { continue }
            for spoken in spokenForms(for: canonical) where spoken != canonical.lowercased() {
                if seen.insert("\(spoken)\n\(canonical)").inserted {
                    forms.append((spoken, canonical))
                }
            }
        }

        var out = text
        var replacedTerms: [String] = []
        var replacedSeen = Set<String>()
        for form in forms.sorted(by: { $0.spoken.count > $1.spoken.count }) {
            let next = replaceWholePhrase(form.spoken, with: form.canonical, in: out)
            if next != out, replacedSeen.insert(form.canonical.lowercased()).inserted {
                replacedTerms.append(form.canonical)
            }
            out = next
        }
        return Analysis(text: out, replacedTerms: replacedTerms)
    }

    private static func spokenForms(for term: String) -> [String] {
        let chunks = term
            .replacingOccurrences(of: #"[\._/\-+]+"#, with: " ", options: .regularExpression)
            .split(whereSeparator: \.isWhitespace)
            .flatMap { splitIdentifier(String($0)) }
            .map { $0.lowercased() }
            .filter { !$0.isEmpty }
        guard chunks.count >= 2 else { return [] }
        return [chunks.joined(separator: " ")]
    }

    private static func splitIdentifier(_ value: String) -> [String] {
        let chars = Array(value)
        guard !chars.isEmpty else { return [] }
        var words: [String] = []
        var start = 0
        for i in 1..<chars.count {
            let prev = chars[i - 1]
            let cur = chars[i]
            let next = i + 1 < chars.count ? chars[i + 1] : nil
            let boundary =
                (cur.isUppercase && (prev.isLowercase || prev.isNumber)) ||
                (cur.isUppercase && prev.isUppercase && (next?.isLowercase ?? false))
            if boundary {
                words.append(String(chars[start..<i]))
                start = i
            }
        }
        words.append(String(chars[start..<chars.count]))
        return words
    }

    private static func replaceWholePhrase(_ phrase: String, with replacement: String, in text: String) -> String {
        let pattern = #"(?i)(?<![A-Za-z0-9_])"# + NSRegularExpression.escapedPattern(for: phrase)
            .replacingOccurrences(of: #"\\ "#, with: #"\s+"#) + #"(?![A-Za-z0-9_])"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return text }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return re.stringByReplacingMatches(in: text, range: range, withTemplate: replacement)
    }

    private static func normalizePaths(_ text: String) -> String {
        let tokens = text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard tokens.contains("斜杠") || tokens.contains("点") else { return text }
        var out: [String] = []
        var i = 0
        while i < tokens.count {
            guard isPathSegment(tokens[i]) else {
                out.append(tokens[i])
                i += 1
                continue
            }

            var path = tokens[i]
            var j = i + 1
            var changed = false
            while j + 1 < tokens.count, tokens[j] == "斜杠", isPathSegment(tokens[j + 1]) {
                path += "/" + tokens[j + 1]
                j += 2
                changed = true
            }
            if j + 1 < tokens.count, tokens[j] == "点" {
                let ext = splitTrailingPunctuation(tokens[j + 1])
                if extensions.contains(ext.body.lowercased()) {
                    path += "." + ext.body + ext.trailing
                    j += 2
                    changed = true
                }
            }

            if changed {
                out.append(path)
                i = j
            } else {
                out.append(tokens[i])
                i += 1
            }
        }
        return out.joined(separator: " ")
    }

    private static func splitTrailingPunctuation(_ token: String) -> (body: String, trailing: String) {
        var body = token
        var trailing = ""
        while let last = body.last, last.isPunctuation {
            trailing.insert(last, at: trailing.startIndex)
            body.removeLast()
        }
        return (body, trailing)
    }

    private static func isPathSegment(_ token: String) -> Bool {
        token.allSatisfy { ch in
            ch.isASCII && (ch.isLetter || ch.isNumber || "_-.".contains(ch))
        }
    }

    private static func normalizeVersions(_ text: String) -> String {
        guard text.contains("版本") || text.contains("v ") else { return text }
        let pattern = #"v\s+([零一二三四五六七八九0-9]+)点([零一二三四五六七八九0-9]+)点([零一二三四五六七八九0-9]+)"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return text }
        var out = text
        for match in re.matches(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text)).reversed() {
            guard match.numberOfRanges == 4,
                  let full = Range(match.range(at: 0), in: out),
                  let a = Range(match.range(at: 1), in: out),
                  let b = Range(match.range(at: 2), in: out),
                  let c = Range(match.range(at: 3), in: out) else { continue }
            out.replaceSubrange(full, with: "v\(digits(String(out[a]))).\(digits(String(out[b]))).\(digits(String(out[c])))")
        }
        return out
    }

    private static func normalizePorts(_ text: String) -> String {
        guard text.contains("端口") else { return text }
        let pattern = #"端口([^零一二三四五六七八九0-9]*)([零一二三四五六七八九]{2,5})"#
        guard let re = try? NSRegularExpression(pattern: pattern),
              let match = re.firstMatch(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text)),
              let full = Range(match.range(at: 0), in: text),
              let gap = Range(match.range(at: 1), in: text),
              let value = Range(match.range(at: 2), in: text) else { return text }
        var out = text
        out.replaceSubrange(full, with: "端口\(out[gap])\(digits(String(out[value])))")
        return out
    }

    private static func digits(_ text: String) -> String {
        let map: [Character: Character] = [
            "零": "0", "一": "1", "二": "2", "三": "3", "四": "4",
            "五": "5", "六": "6", "七": "7", "八": "8", "九": "9"
        ]
        return String(text.map { map[$0] ?? $0 })
    }
}
