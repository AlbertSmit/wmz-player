import Foundation

/// A deliberately forgiving XML reader.
///
/// Skin definitions were authored for WMP's own parser, which accepted things
/// real XML refuses: missing spaces between attributes (`cursor="hand"onClick=`),
/// the same attribute twice, unquoted values, uppercase tags, stray ampersands.
/// Roughly a third of the archived skins trip NSXMLParser, so we read them with
/// a small scanner instead.
enum LenientXML {
    static func parse(_ text: String) -> Element? {
        var scanner = Scanner(text)
        return scanner.parseDocument()
    }

    private struct Scanner {
        let characters: [Character]
        var index = 0

        init(_ text: String) {
            characters = Array(text)
        }

        mutating func parseDocument() -> Element? {
            skipProlog()
            return parseElement()
        }

        // MARK: - Elements

        private mutating func parseElement() -> Element? {
            skipWhitespace()
            guard index < characters.count, characters[index] == "<" else { return nil }

            if matches("<!--") { skip(until: "-->"); return parseElement() }
            if matches("<?") { skip(until: "?>"); return parseElement() }
            if matches("<!") { skip(until: ">"); return parseElement() }

            index += 1 // consume '<'

            if index < characters.count, characters[index] == "/" {
                skip(until: ">")
                return parseElement()
            }

            let name = readName().lowercased()
            guard !name.isEmpty else { return nil }

            var attributes: [String: String] = [:]
            var closed = false
            while index < characters.count {
                skipWhitespace()
                if matches("/>") { index += 2; closed = true; break }
                if matches(">") { index += 1; break }
                if let (key, value) = readAttribute(), attributes[key] == nil {
                    attributes[key] = value
                } else if attributes.isEmpty && index < characters.count {
                    index += 1
                }
            }

            var children: [Element] = []
            var text = ""
            if !closed {
                while index < characters.count {
                    if matches("</") {
                        index += 2
                        _ = readName()
                        skip(until: ">")
                        break
                    }
                    if matches("<!--") { skip(until: "-->"); continue }
                    if matches("<![CDATA[") {
                        index += 9
                        text += read(until: "]]>")
                        skip(until: "]]>")
                        if matches("]]>") { index += 3 }
                        continue
                    }
                    if matches("<?") { skip(until: "?>"); continue }
                    if characters[index] == "<" {
                        if let child = parseElement() { children.append(child) }
                        continue
                    }
                    text += readText()
                }
            }

            return Element(
                name: name,
                attrs: attributes,
                children: children,
                text: decodeEntities(text).trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }

        // MARK: - Attributes

        private mutating func readAttribute() -> (String, String)? {
            skipWhitespace()
            guard index < characters.count else { return nil }
            let name = readName().lowercased()
            guard !name.isEmpty else { return nil }

            skipWhitespace()
            guard index < characters.count, characters[index] == "=" else {
                return (name, "")
            }
            index += 1
            skipWhitespace()

            var value = ""
            if index < characters.count, characters[index] == "\"" || characters[index] == "'" {
                let quote = characters[index]
                index += 1
                while index < characters.count, characters[index] != quote {
                    value.append(characters[index])
                    index += 1
                }
                if index < characters.count { index += 1 }
            } else {
                while index < characters.count,
                      !characters[index].isWhitespace,
                      characters[index] != ">",
                      !matches("/>") {
                    value.append(characters[index])
                    index += 1
                }
            }

            return (name, decodeEntities(value).trimmingCharacters(in: .whitespacesAndNewlines))
        }

        // MARK: - Primitives

        private mutating func readName() -> String {
            var name = ""
            while index < characters.count {
                let character = characters[index]
                if character.isLetter || character.isNumber || character == "_" || character == "-"
                    || character == ":" || character == "." {
                    name.append(character)
                    index += 1
                } else {
                    break
                }
            }
            return name
        }

        private mutating func readText() -> String {
            var text = ""
            while index < characters.count, characters[index] != "<" {
                text.append(characters[index])
                index += 1
            }
            return text
        }

        private func read(until terminator: String) -> String {
            let rest = String(characters[index...])
            guard let range = rest.range(of: terminator) else { return rest }
            return String(rest[..<range.lowerBound])
        }

        private mutating func skipProlog() {
            while index < characters.count {
                skipWhitespace()
                if matches("<?") { skip(until: "?>"); continue }
                if matches("<!--") { skip(until: "-->"); continue }
                if matches("<!") { skip(until: ">"); continue }
                return
            }
        }

        private mutating func skipWhitespace() {
            while index < characters.count, characters[index].isWhitespace { index += 1 }
        }

        private mutating func skip(until terminator: String) {
            while index < characters.count {
                if matches(terminator) { index += terminator.count; return }
                index += 1
            }
        }

        private func matches(_ string: String) -> Bool {
            guard index + string.count <= characters.count else { return false }
            for (offset, character) in string.enumerated() where characters[index + offset] != character {
                return false
            }
            return true
        }

        private func decodeEntities(_ value: String) -> String {
            guard value.contains("&") else { return value }
            var result = value
            let named = ["&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&apos;": "'", "&nbsp;": " "]
            for (entity, replacement) in named {
                result = result.replacingOccurrences(of: entity, with: replacement)
            }
            return result
        }
    }
}
