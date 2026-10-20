import Foundation

/// A single node of a Windows Media Player skin definition (WML).
/// Attribute names are normalised to lower case because the format is wildly
/// inconsistent about casing (`titleBar`, `titlebar`, `resizAble`, ...).
public struct Element {
    public var name: String
    public var attrs: [String: String]
    public var children: [Element] = []
    public var text: String = ""

    public init(name: String, attrs: [String: String] = [:], children: [Element] = [], text: String = "") {
        self.name = name
        self.attrs = attrs
        self.children = children
        self.text = text
    }

    /// Attribute lookup with the aliases and misspellings found in real skins:
    /// WMP7 called the transparency colour `clippingColor`, and a handful of
    /// authors shipped `tranparencyColor`, `backgoundColor` and `fontColor`.
    public subscript(_ key: String) -> String? {
        if let value = attrs[key] { return value }
        switch key {
        case "transparencycolor":
            return attrs["clippingcolor"] ?? attrs["tranparencycolor"]
        case "clippingcolor":
            return attrs["transparencycolor"]
        case "backgroundcolor":
            return attrs["backgoundcolor"]
        case "foregroundcolor":
            return attrs["fontcolor"]
        default:
            return nil
        }
    }

    public func int(_ key: String) -> Int? {
        guard let raw = attrs[key]?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        return Int(raw)
    }

    public func bool(_ key: String) -> Bool? {
        guard let raw = attrs[key]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else { return nil }
        switch raw {
        case "true", "1", "yes": return true
        case "false", "0", "no": return false
        default: return nil
        }
    }

    /// All children with the given (lower case) tag name.
    public func children(named name: String) -> [Element] {
        children.filter { $0.name == name }
    }

    public func firstChild(named name: String) -> Element? {
        children.first { $0.name == name }
    }
}

enum WMLError: LocalizedError {
    case unreadable(String)
    case malformed(String)

    var errorDescription: String? {
        switch self {
        case .unreadable(let name): return "Could not read \(name)."
        case .malformed(let name): return "\(name) is not a skin definition we can read."
        }
    }
}

enum WMLParser {
    /// Reads a `.wms` file and turns it into an element tree.
    static func parse(url: URL) throws -> Element {
        let data = try Data(contentsOf: url)
        let text = decodeText(data)
        guard let root = LenientXML.parse(text), !root.name.isEmpty else {
            throw WMLError.malformed(url.lastPathComponent)
        }
        return root
    }

    /// Skins are usually UTF-16, sometimes UTF-8, and just as often the ANSI
    /// code page of whoever authored them.
    static func decodeText(_ data: Data) -> String {
        if data.starts(with: [0xFF, 0xFE]), let text = String(data: data.dropFirst(2), encoding: .utf16LittleEndian) {
            return text
        }
        if data.starts(with: [0xFE, 0xFF]), let text = String(data: data.dropFirst(2), encoding: .utf16BigEndian) {
            return text
        }
        if data.starts(with: [0xEF, 0xBB, 0xBF]), let text = String(data: data.dropFirst(3), encoding: .utf8) {
            return text
        }
        if let text = String(data: data, encoding: .utf8) { return text }
        if let text = String(data: data, encoding: .windowsCP1252) { return text }
        return String(data: data, encoding: .isoLatin1) ?? ""
    }
}
