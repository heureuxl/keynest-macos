import Foundation

extension PasswordItem {
    /// 用于一体化模糊检索的文本（小写拼接）。
    func searchHaystackLowercased() -> String {
        var parts: [String] = [
            title,
            username,
            url,
            notes,
            Self.hostHint(for: url),
        ]
        for f in customFields {
            parts.append(f.label)
            parts.append(f.value)
        }
        return parts.joined(separator: "\n").lowercased()
    }

    private static func hostHint(for raw: String) -> String {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return "" }
        var s = t
        if !s.contains("://") { s = "https://" + s }
        if let host = URL(string: s)?.host, !host.isEmpty { return host }
        return t
    }

    /// 查询字符串按空白拆成多个词，全部命中（子串）即匹配。
    func matchesSearchTokens(_ tokens: [String]) -> Bool {
        guard !tokens.isEmpty else { return true }
        let hay = searchHaystackLowercased()
        for tok in tokens {
            if !hay.contains(tok.lowercased()) { return false }
        }
        return true
    }
}
