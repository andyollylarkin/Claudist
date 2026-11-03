import Foundation

/// Minimal YAML frontmatter reader for Claude Code agent and skill markdown files:
/// flat `key: value` pairs between `---` fences, the rest is the body.
public struct Frontmatter: Equatable {
    public var fields: [String: String]
    public var body: String

    public static func parse(_ text: String) -> Frontmatter {
        let lines = text.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---",
              let end = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" })
        else { return Frontmatter(fields: [:], body: text) }

        var fields: [String: String] = [:]
        var lastKey: String?
        for line in lines[1..<end] {
            if let lastKey, line.hasPrefix(" ") || line.hasPrefix("\t") {
                // Folded continuation line or list item.
                let v = line.trimmingCharacters(in: .whitespaces)
                let item = v.hasPrefix("- ") ? String(v.dropFirst(2)) : v
                let sep = v.hasPrefix("- ") ? ", " : " "
                fields[lastKey] = [fields[lastKey], item].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: sep)
                continue
            }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, let f = value.first, f == "\"" || f == "'", value.last == f {
                value = String(value.dropFirst().dropLast())
            }
            if value == "|" || value == ">" { value = "" }
            fields[key] = value
            lastKey = key
        }
        let body = lines[(end + 1)...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return Frontmatter(fields: fields, body: body)
    }
}
