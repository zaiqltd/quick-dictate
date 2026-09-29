import Foundation

enum SpokenText {
    static func chunks(_ text: String, maximumCharacters: Int) -> [String] {
        precondition(maximumCharacters > 0)
        var remaining = text[...]
        var result: [String] = []
        while remaining.count > maximumCharacters {
            let limit = remaining.index(remaining.startIndex, offsetBy: maximumCharacters)
            let boundary = remaining[..<limit].lastIndex(where: { $0.isWhitespace }) ?? limit
            let end = boundary == remaining.startIndex ? limit : boundary
            result.append(String(remaining[..<end]))
            remaining = remaining[end...].drop(while: { $0.isWhitespace })
        }
        if !remaining.isEmpty { result.append(String(remaining)) }
        return result
    }
    static func clean(_ raw: String) -> String {
        var text = raw
        for (pattern, replacement) in [
            (#"(?s)```.*?```"#, " Code is shown in the answer. "),
            (#"\[([^\]]+)\]\([^\)]+\)"#, "$1"),
            (#"https?://\S+"#, ""),
            (#"(?m)^\s*[-#*>]+\s*"#, ""),
            (#"[`*_]"#, ""),
            (#"\s+"#, " ")
        ] {
            text = text.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
