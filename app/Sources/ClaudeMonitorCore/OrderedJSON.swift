import Foundation

/// JSON that keeps object key order and number text, so editing ~/.claude/settings.json
/// changes only what we touch. `render` prints like `JSON.stringify(value, null, 2)`,
/// which is how Claude Code writes the file: parse → render is byte-identical for it.
public indirect enum JSONValue: Equatable, Sendable {
    case object([Member])
    case array([JSONValue])
    case string(String)
    /// The number exactly as written.
    case number(String)
    case bool(Bool)
    case null

    public struct Member: Equatable, Sendable {
        public var key: String
        public var value: JSONValue

        public init(_ key: String, _ value: JSONValue) {
            self.key = key
            self.value = value
        }
    }

    public struct ParseError: Error, Equatable, CustomStringConvertible {
        public var message: String
        public var offset: Int
        public var description: String { "\(message) at byte \(offset)" }
    }

    public static func parse(_ data: Data) throws -> JSONValue {
        var parser = Parser(bytes: Array(data))
        parser.skipWhitespace()
        let value = try parser.value(depth: 0)
        parser.skipWhitespace()
        guard parser.atEnd else { throw parser.error("unexpected trailing content") }
        return value
    }

    // MARK: - Access

    public subscript(key: String) -> JSONValue? {
        guard case .object(let members) = self else { return nil }
        return members.first { $0.key == key }?.value
    }

    public var members: [Member]? {
        if case .object(let m) = self { return m }
        return nil
    }

    public var elements: [JSONValue]? {
        if case .array(let a) = self { return a }
        return nil
    }

    public var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    /// Sets (in place) or appends a key on an object.
    public mutating func set(_ key: String, _ value: JSONValue) {
        guard case .object(var members) = self else { return }
        if let i = members.firstIndex(where: { $0.key == key }) {
            members[i].value = value
        } else {
            members.append(Member(key, value))
        }
        self = .object(members)
    }

    public mutating func remove(_ key: String) {
        guard case .object(let members) = self else { return }
        self = .object(members.filter { $0.key != key })
    }

    // MARK: - Render

    public func render() -> String {
        var out = ""
        write(to: &out, indent: 0)
        return out
    }

    private func write(to out: inout String, indent: Int) {
        switch self {
        case .null: out += "null"
        case .bool(let b): out += b ? "true" : "false"
        case .number(let n): out += n
        case .string(let s): Self.writeString(s, to: &out)
        case .array(let items):
            guard !items.isEmpty else { out += "[]"; return }
            out += "[\n"
            for (i, item) in items.enumerated() {
                out += String(repeating: "  ", count: indent + 1)
                item.write(to: &out, indent: indent + 1)
                out += i == items.count - 1 ? "\n" : ",\n"
            }
            out += String(repeating: "  ", count: indent) + "]"
        case .object(let members):
            guard !members.isEmpty else { out += "{}"; return }
            out += "{\n"
            for (i, m) in members.enumerated() {
                out += String(repeating: "  ", count: indent + 1)
                Self.writeString(m.key, to: &out)
                out += ": "
                m.value.write(to: &out, indent: indent + 1)
                out += i == members.count - 1 ? "\n" : ",\n"
            }
            out += String(repeating: "  ", count: indent) + "}"
        }
    }

    /// JSON.stringify's escaping: quote, backslash, the short escapes, other controls as \u00xx.
    private static func writeString(_ s: String, to out: inout String) {
        out += "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case _ where scalar.value < 0x20: out += String(format: "\\u%04x", scalar.value)
            default: out.unicodeScalars.append(scalar)
            }
        }
        out += "\""
    }

    // MARK: - Parse

    private struct Parser {
        let bytes: [UInt8]
        var pos = 0
        static let maxDepth = 256

        var atEnd: Bool { pos >= bytes.count }

        func error(_ message: String) -> ParseError { ParseError(message: message, offset: pos) }

        mutating func skipWhitespace() {
            while pos < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[pos]) { pos += 1 }
        }

        mutating func value(depth: Int) throws -> JSONValue {
            guard depth < Self.maxDepth else { throw error("nested too deeply") }
            guard pos < bytes.count else { throw error("unexpected end") }
            switch bytes[pos] {
            case UInt8(ascii: "{"): return try object(depth: depth)
            case UInt8(ascii: "["): return try array(depth: depth)
            case UInt8(ascii: "\""): return .string(try string())
            case UInt8(ascii: "t"): try literal("true"); return .bool(true)
            case UInt8(ascii: "f"): try literal("false"); return .bool(false)
            case UInt8(ascii: "n"): try literal("null"); return .null
            default: return .number(try number())
            }
        }

        mutating func object(depth: Int) throws -> JSONValue {
            pos += 1
            var members: [Member] = []
            skipWhitespace()
            if pos < bytes.count, bytes[pos] == UInt8(ascii: "}") { pos += 1; return .object([]) }
            while true {
                skipWhitespace()
                guard pos < bytes.count, bytes[pos] == UInt8(ascii: "\"") else { throw error("expected a key") }
                let key = try string()
                skipWhitespace()
                guard pos < bytes.count, bytes[pos] == UInt8(ascii: ":") else { throw error("expected ':'") }
                pos += 1
                skipWhitespace()
                members.append(Member(key, try value(depth: depth + 1)))
                skipWhitespace()
                guard pos < bytes.count else { throw error("unterminated object") }
                if bytes[pos] == UInt8(ascii: ",") { pos += 1; continue }
                if bytes[pos] == UInt8(ascii: "}") { pos += 1; return .object(members) }
                throw error("expected ',' or '}'")
            }
        }

        mutating func array(depth: Int) throws -> JSONValue {
            pos += 1
            var items: [JSONValue] = []
            skipWhitespace()
            if pos < bytes.count, bytes[pos] == UInt8(ascii: "]") { pos += 1; return .array([]) }
            while true {
                skipWhitespace()
                items.append(try value(depth: depth + 1))
                skipWhitespace()
                guard pos < bytes.count else { throw error("unterminated array") }
                if bytes[pos] == UInt8(ascii: ",") { pos += 1; continue }
                if bytes[pos] == UInt8(ascii: "]") { pos += 1; return .array(items) }
                throw error("expected ',' or ']'")
            }
        }

        mutating func literal(_ word: String) throws {
            let w = Array(word.utf8)
            guard pos + w.count <= bytes.count, Array(bytes[pos..<pos + w.count]) == w else {
                throw error("invalid literal")
            }
            pos += w.count
        }

        mutating func number() throws -> String {
            let start = pos
            if pos < bytes.count, bytes[pos] == UInt8(ascii: "-") { pos += 1 }
            func digits() -> Int {
                let s = pos
                while pos < bytes.count, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(bytes[pos]) { pos += 1 }
                return pos - s
            }
            guard digits() > 0 else { throw error("invalid value") }
            if pos < bytes.count, bytes[pos] == UInt8(ascii: ".") {
                pos += 1
                guard digits() > 0 else { throw error("invalid number") }
            }
            if pos < bytes.count, bytes[pos] == UInt8(ascii: "e") || bytes[pos] == UInt8(ascii: "E") {
                pos += 1
                if pos < bytes.count, bytes[pos] == UInt8(ascii: "+") || bytes[pos] == UInt8(ascii: "-") { pos += 1 }
                guard digits() > 0 else { throw error("invalid number") }
            }
            return String(decoding: bytes[start..<pos], as: UTF8.self)
        }

        mutating func string() throws -> String {
            pos += 1  // opening quote
            var raw: [UInt8] = []
            while true {
                guard pos < bytes.count else { throw error("unterminated string") }
                let b = bytes[pos]
                pos += 1
                switch b {
                case UInt8(ascii: "\""):
                    guard let s = String(bytes: raw, encoding: .utf8) else { throw error("invalid UTF-8") }
                    return s
                case UInt8(ascii: "\\"):
                    guard pos < bytes.count else { throw error("unterminated escape") }
                    let e = bytes[pos]
                    pos += 1
                    switch e {
                    case UInt8(ascii: "\""): raw.append(0x22)
                    case UInt8(ascii: "\\"): raw.append(0x5C)
                    case UInt8(ascii: "/"): raw.append(0x2F)
                    case UInt8(ascii: "b"): raw.append(0x08)
                    case UInt8(ascii: "f"): raw.append(0x0C)
                    case UInt8(ascii: "n"): raw.append(0x0A)
                    case UInt8(ascii: "r"): raw.append(0x0D)
                    case UInt8(ascii: "t"): raw.append(0x09)
                    case UInt8(ascii: "u"):
                        var code = try hex4()
                        if (0xD800...0xDBFF).contains(code), pos + 1 < bytes.count,
                           bytes[pos] == UInt8(ascii: "\\"), bytes[pos + 1] == UInt8(ascii: "u") {
                            pos += 2
                            let low = try hex4()
                            guard (0xDC00...0xDFFF).contains(low) else { throw error("invalid surrogate pair") }
                            code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00)
                        }
                        guard let scalar = Unicode.Scalar(code) else { throw error("invalid \\u escape") }
                        raw += Array(String(Character(scalar)).utf8)
                    default:
                        throw error("invalid escape")
                    }
                case 0x00..<0x20:
                    throw error("control character in string")
                default:
                    raw.append(b)
                }
            }
        }

        mutating func hex4() throws -> UInt32 {
            guard pos + 4 <= bytes.count,
                  let v = UInt32(String(decoding: bytes[pos..<pos + 4], as: UTF8.self), radix: 16) else {
                throw error("invalid \\u escape")
            }
            pos += 4
            return v
        }
    }
}
