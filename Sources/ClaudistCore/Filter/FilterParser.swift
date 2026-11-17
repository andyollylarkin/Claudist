import Foundation

public struct FilterQuery {
    /// Parses a Todoist-style filter query.
    ///
    /// Comma-separated parts become separate groups (Todoist semantics); each group's title is
    /// its trimmed source text. Commas are only allowed at the top level.
    public static func parse(_ text: String) throws -> [FilterGroupQuery] {
        var p = FilterParser(text)
        return try p.parseQuery()
    }
}

/// One character of a term; `escaped` is true when it was preceded by `\`.
struct TermChar {
    var ch: Character
    var escaped: Bool
    var pos: Int
}

struct FilterParser {
    let chars: [Character]
    var pos = 0

    init(_ text: String) { chars = Array(text) }

    func fail(_ message: String, at p: Int? = nil) -> FilterError {
        .syntax(position: min(p ?? pos, chars.count), message: message)
    }

    var peek: Character? { pos < chars.count ? chars[pos] : nil }

    mutating func skipSpace() {
        while let c = peek, c.isWhitespace { pos += 1 }
    }

    // MARK: Grammar
    //   query   := expr (',' expr)*
    //   expr    := and ('|' and)*
    //   and     := unary ('&' unary)*
    //   unary   := '!' unary | '(' expr ')' | term

    mutating func parseQuery() throws -> [FilterGroupQuery] {
        skipSpace()
        if peek == nil { throw fail("Empty filter query") }
        var groups: [FilterGroupQuery] = []
        while true {
            skipSpace()
            let start = pos
            let e = try parseOr()
            let title = String(chars[start..<pos]).trimmingCharacters(in: .whitespacesAndNewlines)
            groups.append(FilterGroupQuery(title: title, expr: e))
            skipSpace()
            guard let c = peek else { break }
            switch c {
            case ",": pos += 1
            case ")": throw fail("Unmatched ')'")
            default: throw fail("Expected '&', '|' or ','")
            }
        }
        return groups
    }

    mutating func parseOr() throws -> FilterExpr {
        var lhs = try parseAnd()
        while true {
            skipSpace()
            guard peek == "|" else { return lhs }
            pos += 1
            lhs = .or(lhs, try parseAnd())
        }
    }

    mutating func parseAnd() throws -> FilterExpr {
        var lhs = try parseUnary()
        while true {
            skipSpace()
            guard peek == "&" else { return lhs }
            pos += 1
            lhs = .and(lhs, try parseUnary())
        }
    }

    mutating func parseUnary() throws -> FilterExpr {
        skipSpace()
        guard let c = peek else { throw fail("Expected a filter term") }
        switch c {
        case "!":
            pos += 1
            return .not(try parseUnary())
        case "(":
            let open = pos
            pos += 1
            let e = try parseOr()
            skipSpace()
            switch peek {
            case ")": pos += 1; return e
            case ",": throw fail("Commas can't be used inside parentheses; use '|' to combine queries or put the comma outside")
            case nil: throw fail("Missing ')'", at: open)
            default: throw fail("Expected '&', '|' or ')'")
            }
        case "&", "|", ",", ")":
            throw fail("Expected a filter term before '\(c)'")
        default:
            return try parseTerm()
        }
    }

    mutating func parseTerm() throws -> FilterExpr {
        var units: [TermChar] = []
        while let c = peek {
            if c == "\\" {
                guard pos + 1 < chars.count else { throw fail("Nothing to escape after '\\'") }
                units.append(TermChar(ch: chars[pos + 1], escaped: true, pos: pos))
                pos += 2
                continue
            }
            if "&|,)".contains(c) { break }
            units.append(TermChar(ch: c, escaped: false, pos: pos))
            pos += 1
        }
        let term = units.trimmed
        guard !term.isEmpty else { throw fail("Expected a filter term") }
        return try TermClassifier.classify(term)
    }
}

extension Array where Element == TermChar {
    var trimmed: [TermChar] {
        var s = self[...]
        while let f = s.first, !f.escaped, f.ch.isWhitespace { s = s.dropFirst() }
        while let l = s.last, !l.escaped, l.ch.isWhitespace { s = s.dropLast() }
        return Array(s)
    }

    /// Text with escapes resolved.
    var text: String { String(map(\.ch)) }

    /// Lowercased with runs of whitespace collapsed — for keyword matching.
    var normalized: String {
        text.lowercased().split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// Unescaped `*` become wildcards.
    var namePattern: NamePattern {
        var parts: [NamePattern.Part] = []
        var lit = ""
        for u in self {
            if u.ch == "*" && !u.escaped {
                if !lit.isEmpty { parts.append(.literal(lit)); lit = "" }
                if parts.last != .wildcard { parts.append(.wildcard) }
            } else {
                lit.append(u.ch)
            }
        }
        if !lit.isEmpty { parts.append(.literal(lit)) }
        return NamePattern(parts: parts)
    }

    var hasEscapes: Bool { contains { $0.escaped } }
}

enum TermClassifier {
    static let simple: [String: FilterExpr] = [
        "all": .all, "view all": .all,
        "no labels": .noLabels, "no label": .noLabels,
        "p1": .priority(1), "p2": .priority(2), "p3": .priority(3), "p4": .priority(4),
        "no priority": .priority(4),
        "overdue": .overdue, "od": .overdue,
        "no date": .noDate, "no due date": .noDate, "no dates": .noDate,
        "no time": .noTime,
        "no deadline": .noDeadline,
        "recurring": .recurring,
        "flagged": .flagged, "flag": .flagged,
        "subtask": .subtask, "subtasks": .subtask,
        "shared": .shared,
        "assigned": .assigned,
        "uncompletable": .uncompletable,
        "completed": .completed,
        "run": .run(nil),
        "needs you": .needsYou, "needs input": .needsYou,
    ]

    static let dateKeys: [String: (DateField, DateComparison)] = {
        var m: [String: (DateField, DateComparison)] = [:]
        let fields: [(String, DateField)] = [
            ("date", .date), ("due", .due), ("deadline", .deadline),
            ("created", .created), ("completed", .completed), ("run", .run),
        ]
        for (name, f) in fields {
            m[name] = (f, .on)
            m[name + " before"] = (f, .before)
            m[name + " after"] = (f, .after)
        }
        return m
    }()

    static let unsupportedKeys: Set<String> = ["assigned by", "added by", "workspace", "folder"]

    static func classify(_ term: [TermChar]) throws -> FilterExpr {
        let start = term[0].pos
        func fail(_ m: String, at p: Int? = nil) -> FilterError { .syntax(position: p ?? start, message: m) }

        // #Project, ##Project, /Section, @label, %label
        if !term[0].escaped, "#/@%".contains(term[0].ch) {
            let sigil = term[0].ch
            var rest = Array(term.dropFirst())
            var sub = false
            if sigil == "#", let f = rest.first, f.ch == "#", !f.escaped {
                sub = true
                rest.removeFirst()
            }
            rest = rest.trimmed
            let what = sigil == "#" ? "project" : sigil == "/" ? "section" : "label"
            guard !rest.isEmpty else { throw fail("Expected a \(what) name after '\(sub ? "##" : String(sigil))'") }
            let name = rest.namePattern
            switch sigil {
            case "#": return .project(name, includeSubprojects: sub)
            case "/": return .section(name)
            default: return .label(name)
            }
        }

        let norm = term.normalized
        if !term.hasEscapes, let e = simple[norm] { return e }

        // keyword: value
        if let colon = term.firstIndex(where: { $0.ch == ":" && !$0.escaped }) {
            let key = Array(term[..<colon]).normalized
            let valueUnits = Array(term[(colon + 1)...]).trimmed
            let valuePos = valueUnits.first?.pos ?? term[colon].pos + 1
            let value = valueUnits.text

            if let (field, cmp) = dateKeys[key] {
                guard !valueUnits.isEmpty else { throw fail("Expected a date after '\(key):'", at: valuePos) }
                if field == .run && cmp == .on, let status = RunStatus(rawValue: valueUnits.normalized) {
                    return .run(status)
                }
                if field == .run && cmp == .on && valueUnits.normalized == "none" {
                    return .not(.run(nil))
                }
                do {
                    return .date(field, cmp, try DateExprParser.parse(value, mode: .filter))
                } catch let e as DateParseError {
                    let hint = field == .run && cmp == .on
                        ? " (or a run status: \(RunStatus.allCases.map(\.rawValue).joined(separator: ", ")))" : ""
                    throw fail(e.message + hint, at: valuePos)
                }
            }
            switch key {
            case "search":
                guard !valueUnits.isEmpty else { throw fail("Expected text after 'search:'", at: valuePos) }
                return .search(value)
            case "assigned to", "agent":
                guard !valueUnits.isEmpty else { throw fail("Expected a name after '\(key):'", at: valuePos) }
                switch valueUnits.normalized {
                case "me" where !valueUnits.hasEscapes: return .assignedTo(.me)
                case "others" where !valueUnits.hasEscapes: return .assignedTo(.others)
                default: return .assignedTo(.named(valueUnits.namePattern))
                }
            default:
                break
            }
            if unsupportedKeys.contains(key) {
                throw fail("'\(key):' is not supported in Claudist")
            }
            // Could still be a date with a time, e.g. "today at 14:00".
            if let e = try? DateExprParser.parse(term.text, mode: .filter) {
                return .date(.date, .on, e)
            }
            throw fail("Unknown filter keyword '\(key):'")
        }

        // N days / next N days / -N days
        let words = norm.split(separator: " ").map(String.init)
        if words.count == 2, DateWords.unit(words[1]) == .day, let n = Int(words[0]) {
            if words[0].hasPrefix("-") { return .date(.date, .on, .pastDays(-n)) }
            if !words[0].hasPrefix("+") { return .date(.date, .on, .nextDays(n)) }
        }

        do {
            return .date(.date, .on, try DateExprParser.parse(term.text, mode: .filter))
        } catch {
            throw fail("Unknown filter '\(term.text)'")
        }
    }
}
