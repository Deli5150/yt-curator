import Foundation

/// Read-only view over a parsed InnerTube JSON value (`JSONSerialization` output).
/// Missing keys/indices yield an empty `J` instead of crashing, so parsers can chain freely.
struct J: @unchecked Sendable {
    let raw: Any?

    init(_ raw: Any?) { self.raw = raw }

    init(data: Data) throws {
        raw = try JSONSerialization.jsonObject(with: data)
    }

    subscript(key: String) -> J { J((raw as? [String: Any])?[key]) }
    subscript(index: Int) -> J {
        guard let a = raw as? [Any], a.indices.contains(index) else { return J(nil) }
        return J(a[index])
    }

    var exists: Bool { raw != nil && !(raw is NSNull) }
    var dict: [String: Any]? { raw as? [String: Any] }
    var array: [J] { (raw as? [Any])?.map(J.init) ?? [] }
    var keys: [String] { dict.map { Array($0.keys) } ?? [] }
    var bool: Bool? { raw as? Bool }
    var int: Int? { (raw as? NSNumber)?.intValue }

    var string: String? {
        if let s = raw as? String { return s.isEmpty ? nil : s }
        if let n = raw as? NSNumber, !(raw is Bool) { return n.stringValue }
        return nil
    }

    /// InnerTube text in any of its shapes: plain string, `{simpleText}`, `{runs:[{text}]}`,
    /// view-model `{content}`, or `{text: …}` nesting.
    var text: String? {
        if let s = string { return nonBlank(s) }
        if let s = self["simpleText"].string { return nonBlank(s) }
        if let s = self["content"].string { return nonBlank(s) }
        let runs = self["runs"].array
        if !runs.isEmpty {
            return nonBlank(runs.compactMap { $0["text"].string }.joined())
        }
        if self["text"].exists, let t = self["text"].text { return t }
        return nil
    }

    /// First value found for `key` anywhere below this node (depth-first, document order).
    func first(_ key: String) -> J? {
        if let d = dict {
            if let v = d[key] { return J(v) }
            for v in d.values {
                if let found = J(v).first(key) { return found }
            }
        } else if let a = raw as? [Any] {
            for v in a {
                if let found = J(v).first(key) { return found }
            }
        }
        return nil
    }

    /// Every value for `key` anywhere below this node; does not descend into matches.
    func all(_ key: String) -> [J] {
        var out: [J] = []
        collect(key, into: &out)
        return out
    }

    private func collect(_ key: String, into out: inout [J]) {
        if let d = raw as? [String: Any] {
            for (k, v) in d {
                if k == key { out.append(J(v)) } else { J(v).collect(key, into: &out) }
            }
        } else if let a = raw as? [Any] {
            for v in a { J(v).collect(key, into: &out) }
        }
    }
}

private func nonBlank(_ s: String) -> String? {
    s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : s
}
