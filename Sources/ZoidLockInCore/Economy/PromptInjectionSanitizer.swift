import Foundation

/// Strips prompt-injection control tokens from untrusted meeting text before Gemini sees it.
public enum PromptInjectionSanitizer: Sendable {
    public static func sanitizeAgenda(_ text: String) -> String {
        sanitize(text, limit: GeminiAuditPolicy.maxAgendaCharacters)
    }

    public static func sanitizeAppeal(_ text: String) -> String {
        sanitize(text, limit: GeminiAuditPolicy.maxAppealCharacters)
    }

    public static func sanitize(_ text: String, limit: Int) -> String {
        var value = text.precomposedStringWithCompatibilityMapping
        value = stripInvisibleAndBidi(value)
        value = stripHTMLComments(value)
        value = stripFencedInstructionBlocks(value)
        value = stripControlPhrases(value)
        value = stripInstructionHeadings(value)
        value = stripRoleDelimiters(value)
        value = collapseWhitespace(value)
        if value.count > limit {
            let end = value.index(value.startIndex, offsetBy: limit)
            value = String(value[..<end])
        }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func stripInvisibleAndBidi(_ text: String) -> String {
        let banned = CharacterSet.controlCharacters
            .union(.illegalCharacters)
            .union(CharacterSet(charactersIn: "\u{200B}\u{200C}\u{200D}\u{2060}\u{FEFF}\u{00AD}"))
            .union(CharacterSet(charactersIn: "\u{202A}\u{202B}\u{202C}\u{202D}\u{202E}\u{2066}\u{2067}\u{2068}\u{2069}"))
        return String(text.unicodeScalars.filter { scalar in
            if scalar == "\n" || scalar == "\t" || scalar == "\r" {
                return true
            }
            return !banned.contains(scalar)
        })
    }

    private static func stripHTMLComments(_ text: String) -> String {
        replace(text, pattern: "<!--([\\s\\S]*?)-->", template: " ")
    }

    private static func stripFencedInstructionBlocks(_ text: String) -> String {
        var value = replace(
            text,
            pattern: "```(?:system|prompt|instruction|developer|assistant)[\\s\\S]*?```",
            template: " "
        )
        value = replace(value, pattern: "<\\/?\\s*(system|instruction|prompt|assistant|inst)\\s*>", template: " ")
        return value
    }

    private static func stripControlPhrases(_ text: String) -> String {
        let phrases = [
            #"ignore\s+(all\s+)?(previous|prior|above|prior)\s+instructions"#,
            #"ignore\s+previous\s+instructions"#,
            #"disregard\s+(all\s+)?(previous|prior|above)\s+(instructions|prompts?)"#,
            #"forget\s+(your\s+)?(previous\s+)?(instructions|prompt)"#,
            #"override\s+(the\s+)?(system\s+)?(prompt|instructions?)"#,
            #"you\s+are\s+now"#,
            #"new\s+instructions?\s*:"#,
            #"do\s+anything\s+now"#,
            #"\bjailbreak\b"#,
            #"\bDAN\s+mode\b"#,
            #"\bDAN\b"#,
            #"reveal\s+(your\s+)?system\s+prompt"#,
            #"end\s+system\s+prompt"#,
            #"begin\s+system\s+prompt"#,
        ]
        var value = text
        for phrase in phrases {
            value = replace(value, pattern: phrase, template: " ")
        }
        return value
    }

    private static func stripInstructionHeadings(_ text: String) -> String {
        let lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        let filtered = lines.map { line -> String in
            let raw = String(line)
            if matches(raw, pattern: #"^\s{0,3}#{1,6}\s*(system|instruction|prompt|developer|assistant)\b"#) {
                return ""
            }
            if matches(raw, pattern: #"^\s{0,3}(system|assistant|developer|instruction)\s*:"#) {
                return ""
            }
            return raw
        }
        return filtered.joined(separator: "\n")
    }

    private static func stripRoleDelimiters(_ text: String) -> String {
        let tokens = [
            #"\[/?INST\]"#,
            #"<<SYS>>"#,
            #"<</SYS>>"#,
            #"<\|im_start\|>"#,
            #"<\|im_end\|>"#,
            #"<\|system\|>"#,
            #"<\|assistant\|>"#,
            #"<\|user\|>"#,
            #"\[system\]"#,
            #"\[assistant\]"#,
            #"\[/?system\]"#,
        ]
        var value = text
        for token in tokens {
            value = replace(value, pattern: token, template: " ")
        }
        value = replace(value, pattern: #"(?m)^\s*-{3,}\s*$"#, template: " ")
        return value
    }

    private static func collapseWhitespace(_ text: String) -> String {
        let unified = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let collapsedLines = unified.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            .map { line in
                line.split(whereSeparator: { $0 == " " || $0 == "\t" }).joined(separator: " ")
            }
        var lines = collapsedLines.map { $0.trimmingCharacters(in: .whitespaces) }
        while lines.last == "" {
            lines.removeLast()
        }
        var compact: [String] = []
        var emptyRun = 0
        for line in lines {
            if line.isEmpty {
                emptyRun += 1
                if emptyRun <= 1 {
                    compact.append("")
                }
            } else {
                emptyRun = 0
                compact.append(line)
            }
        }
        return compact.joined(separator: "\n")
    }

    private static func replace(_ text: String, pattern: String, template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else {
            return text
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: template)
    }

    private static func matches(_ text: String, pattern: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return false
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.firstMatch(in: text, options: [], range: range) != nil
    }
}
