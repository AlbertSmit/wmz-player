import Foundation

/// WMP skins position things with tiny JavaScript expressions:
/// `jscript:view.width-43`, `parent.height/2`, `seek.width`. We don't run the
/// skin's script; we evaluate the handful of arithmetic expressions that show
/// up in layout attributes.
enum Expression {
    static func number(_ raw: String?, lookup: @escaping (String) -> Double) -> Double? {
        guard var text = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        for prefix in ["jscript:", "javascript:"] where text.hasPrefix(prefix) {
            text.removeFirst(prefix.count)
        }
        // A trailing semicolon is just the style these files were written in.
        while text.hasSuffix(";") { text.removeLast() }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // Anything left is a statement, not a layout value.
        if text.contains(";") || text.contains("=") {
            return nil
        }
        guard let tokens = tokenize(text) else { return nil }
        var parser = Parser(tokens: tokens, lookup: lookup)
        guard let value = parser.parseExpression(), parser.atEnd, value.isFinite else { return nil }
        return value
    }

    private enum Token: Equatable {
        case number(Double)
        case identifier(String)
        case plus, minus, times, divide, modulo, open, close
    }

    private static func tokenize(_ text: String) -> [Token]? {
        var tokens: [Token] = []
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if character.isWhitespace {
                index = text.index(after: index)
                continue
            }
            if character.isNumber || character == "." && text[text.index(after: index)...].first?.isNumber == true {
                var end = index
                while end < text.endIndex, text[end].isNumber || text[end] == "." {
                    end = text.index(after: end)
                }
                guard let value = Double(text[index..<end]) else { return nil }
                tokens.append(.number(value))
                index = end
                continue
            }
            if character.isLetter || character == "_" {
                var end = index
                while end < text.endIndex, text[end].isLetter || text[end].isNumber || text[end] == "_" || text[end] == "." {
                    end = text.index(after: end)
                }
                tokens.append(.identifier(String(text[index..<end])))
                index = end
                continue
            }
            switch character {
            case "+": tokens.append(.plus)
            case "-": tokens.append(.minus)
            case "*": tokens.append(.times)
            case "/": tokens.append(.divide)
            case "%": tokens.append(.modulo)
            case "(": tokens.append(.open)
            case ")": tokens.append(.close)
            default: return nil
            }
            index = text.index(after: index)
        }
        return tokens.isEmpty ? nil : tokens
    }

    private struct Parser {
        let tokens: [Token]
        let lookup: (String) -> Double
        var position = 0

        var atEnd: Bool { position >= tokens.count }

        mutating func parseExpression() -> Double? {
            guard var value = parseTerm() else { return nil }
            while position < tokens.count {
                switch tokens[position] {
                case .plus:
                    position += 1
                    guard let rhs = parseTerm() else { return nil }
                    value += rhs
                case .minus:
                    position += 1
                    guard let rhs = parseTerm() else { return nil }
                    value -= rhs
                default:
                    return value
                }
            }
            return value
        }

        mutating func parseTerm() -> Double? {
            guard var value = parseFactor() else { return nil }
            while position < tokens.count {
                switch tokens[position] {
                case .times:
                    position += 1
                    guard let rhs = parseFactor() else { return nil }
                    value *= rhs
                case .divide:
                    position += 1
                    guard let rhs = parseFactor(), rhs != 0 else { return nil }
                    value /= rhs
                case .modulo:
                    position += 1
                    guard let rhs = parseFactor(), rhs != 0 else { return nil }
                    value = value.truncatingRemainder(dividingBy: rhs)
                default:
                    return value
                }
            }
            return value
        }

        mutating func parseFactor() -> Double? {
            guard position < tokens.count else { return nil }
            switch tokens[position] {
            case .number(let value):
                position += 1
                return value
            case .identifier(let name):
                position += 1
                return lookup(name)
            case .minus:
                position += 1
                return parseFactor().map { -$0 }
            case .plus:
                position += 1
                return parseFactor()
            case .open:
                position += 1
                guard let value = parseExpression(), position < tokens.count, tokens[position] == .close else { return nil }
                position += 1
                return value
            default:
                return nil
            }
        }
    }
}
