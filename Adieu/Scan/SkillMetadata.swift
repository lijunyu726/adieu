import Foundation

/// 只编辑各客户端使用的 YAML 标量，保留其他字段、注释和技能正文。
/// 流式映射、锚点和多行策略值交给客户端或原编辑器处理。
struct SkillMetadata {
    enum EditError: LocalizedError {
        case unsupported(URL)

        var errorDescription: String? {
            switch self {
            case .unsupported(let url):
                String(localized: "无法安全读取或修改此技能的 YAML：\(url.path)")
            }
        }
    }

    private struct Field {
        let index: Int
        let value: String
    }

    private var lines: [String]
    private let separator: String
    private let frontmatter: Bool
    private let url: URL

    init(_ text: String, at url: URL, frontmatter: Bool) {
        separator = text.contains("\r\n") ? "\r\n" : "\n"
        lines = text.components(separatedBy: separator)
        self.frontmatter = frontmatter
        self.url = url
    }

    var name: String? {
        guard let bounds = try? yamlBounds(),
              let field = try? field("name", indent: 0, in: bounds) else { return nil }
        return scalar(field.value)
    }

    func mode(for agent: SkillAgent) throws -> SkillInvocation {
        let bounds = try yamlBounds()
        if agent == .codex {
            guard let policy = try policyBlock(in: bounds) else { return .automatic }
            let allow = try boolean("allow_implicit_invocation", indent: policy.indent, in: policy.range)
            return allow == false ? .explicit : .automatic
        }
        let disabled = try boolean("disable-model-invocation", indent: 0, in: bounds)
        let user = try boolean("user-invocable", indent: 0, in: bounds)
        if disabled == true { return user == false ? .unavailable : .explicit }
        return .automatic
    }

    mutating func setMode(_ mode: SkillInvocation, for agent: SkillAgent) throws -> String {
        let bounds = try yamlBounds()
        if agent == .codex {
            let key = "allow_implicit_invocation"
            let value = mode != .explicit
            if let policy = try policyBlock(in: bounds) {
                try setBoolean(key, value: value, indent: policy.indent, in: policy.range)
            } else {
                let insert = lines.first == "---" ? 1 : 0
                if lines.count == 1 && lines[0].trimmingCharacters(in: .whitespaces) == "{}" { lines = [""] }
                lines.insert(contentsOf: ["policy:", "  \(key): \(value)"], at: insert)
            }
        } else {
            try setBoolean("disable-model-invocation", value: mode == .explicit, indent: 0, in: bounds)
            if mode == .explicit {
                let updated = try yamlBounds()
                if try boolean("user-invocable", indent: 0, in: updated) == false {
                    try setBoolean("user-invocable", value: true, indent: 0, in: updated)
                }
            }
        }
        return lines.joined(separator: separator)
    }

    private func yamlBounds() throws -> Range<Int> {
        let start = lines.first == "---" ? 1 : 0
        let end = lines.indices.dropFirst(start).first { lines[$0] == "---" || lines[$0] == "..." } ?? lines.endIndex
        if frontmatter && (start == 0 || end == lines.endIndex) { throw EditError.unsupported(url) }
        let root = lines[start..<end].first { !isTrivia($0) }
        if let root, root != "{}" {
            guard root.contains(":"), let first = root.first,
                  !["{", "[", "-", "&", "*", "!", "?", "%", " ", "\t"].contains(first) else {
                throw EditError.unsupported(url)
            }
        }
        return start..<end
    }

    private func isTrivia(_ line: String) -> Bool {
        let content = line.trimmingCharacters(in: .whitespaces)
        return content.isEmpty || content.hasPrefix("#")
    }

    private func field(_ key: String, indent: Int, in range: Range<Int>) throws -> Field? {
        var found: Field?
        for i in range {
            let line = lines[i]
            let level = line.prefix(while: { $0 == " " }).count
            guard level == indent, !isTrivia(line), let colon = line.firstIndex(of: ":") else { continue }
            let rawKey = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            if rawKey == "<<" { throw EditError.unsupported(url) }
            guard scalar(rawKey) == key else { continue }
            guard found == nil else { throw EditError.unsupported(url) }
            found = Field(index: i, value: String(line[line.index(after: colon)...]))
        }
        return found
    }

    private func policyBlock(in bounds: Range<Int>) throws -> (range: Range<Int>, indent: Int)? {
        guard let policy = try field("policy", indent: 0, in: bounds) else { return nil }
        let value = policy.value.trimmingCharacters(in: .whitespaces)
        guard value.isEmpty || value.hasPrefix("#") else { throw EditError.unsupported(url) }
        let start = policy.index + 1
        let end = (start..<bounds.upperBound).first {
            !isTrivia(lines[$0]) && !lines[$0].hasPrefix(" ")
        } ?? bounds.upperBound
        let range = start..<end
        let first = lines[range].first { !isTrivia($0) }
        if let first, first.trimmingCharacters(in: .whitespaces).hasPrefix("-") {
            throw EditError.unsupported(url)
        }
        let indent = first?.prefix(while: { $0 == " " }).count ?? 2
        return (range, indent)
    }

    private func scalar(_ raw: String) -> String? {
        let text = raw.trimmingCharacters(in: .whitespaces)
        if let quote = text.first, quote == "'" || quote == "\"" {
            guard let closing = text.dropFirst().firstIndex(of: quote) else { return nil }
            let rest = text[text.index(after: closing)...].trimmingCharacters(in: .whitespaces)
            guard rest.isEmpty || rest.hasPrefix("#") else { return nil }
            return String(text[text.index(after: text.startIndex)..<closing])
        }
        let value = text.components(separatedBy: .whitespaces).prefix { !$0.hasPrefix("#") }.joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? nil : value
    }

    private func boolean(_ key: String, indent: Int, in range: Range<Int>) throws -> Bool? {
        guard let field = try field(key, indent: indent, in: range) else { return nil }
        switch scalar(field.value)?.lowercased() {
        case "true", "yes", "on", "1": return true
        case "false", "no", "off", "0": return false
        default: throw EditError.unsupported(url)
        }
    }

    private mutating func setBoolean(_ key: String, value: Bool, indent: Int, in range: Range<Int>) throws {
        let prefix = String(repeating: " ", count: indent)
        guard let field = try field(key, indent: indent, in: range) else {
            lines.insert("\(prefix)\(key): \(value)", at: range.lowerBound)
            return
        }
        _ = try boolean(key, indent: indent, in: range)
        let comment = field.value.firstIndex(of: "#").map { " " + field.value[$0...] } ?? ""
        lines[field.index] = "\(prefix)\(key): \(value)\(comment)"
    }
}
