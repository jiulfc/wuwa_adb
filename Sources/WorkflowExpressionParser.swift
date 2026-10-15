import Foundation

// A restricted expression grammar; no host-language evaluation or function calls.
struct ExpressionParser {
    private enum Token: Equatable {
        case identifier(String), literal(JSONValue), symbol(String), end
    }
    private var tokens: [Token] = []
    private var index = 0
    private let path: String
    private let variables: Set<String>

    init(_ source: String, path: String, variables: Set<String>) throws {
        self.path = path
        self.variables = variables
        let chars = Array(source)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c.isWhitespace { i += 1; continue }
            if Self.isStart(c) {
                let start = i
                i += 1
                while i < chars.count && Self.isPart(chars[i]) { i += 1 }
                let name = String(chars[start..<i])
                switch name {
                case "true": tokens.append(.literal(.bool(true)))
                case "false": tokens.append(.literal(.bool(false)))
                case "null": tokens.append(.literal(.null))
                case "contains": tokens.append(.symbol(name))
                default: tokens.append(.identifier(name))
                }
            } else if c.isASCII && c.isNumber {
                let start = i
                while i < chars.count && chars[i].isASCII && chars[i].isNumber { i += 1 }
                if i < chars.count && chars[i] == "." {
                    i += 1
                    let fraction = i
                    while i < chars.count && chars[i].isASCII && chars[i].isNumber { i += 1 }
                    guard i > fraction else { throw error("Expected digits after decimal point") }
                }
                guard let value = Double(String(chars[start..<i])), value.isFinite else {
                    throw error("Invalid finite number")
                }
                tokens.append(.literal(.number(value)))
            } else if c == "'" || c == "\"" {
                let quote = c
                i += 1
                var value = ""
                while i < chars.count && chars[i] != quote {
                    if chars[i] == "\\" {
                        i += 1
                        guard i < chars.count else { throw error("Unterminated string escape") }
                        switch chars[i] {
                        case "n": value.append("\n")
                        case "r": value.append("\r")
                        case "t": value.append("\t")
                        case "\\", "'", "\"": value.append(chars[i])
                        default: throw error("Unsupported string escape")
                        }
                    } else { value.append(chars[i]) }
                    i += 1
                }
                guard i < chars.count else { throw error("Unterminated string") }
                i += 1
                tokens.append(.literal(.string(value)))
            } else {
                let pair = i + 1 < chars.count ? String(chars[i...i + 1]) : ""
                if ["==", "!=", "<=", ">=", "&&", "||"].contains(pair) {
                    tokens.append(.symbol(pair)); i += 2
                } else if "()+-*/%!<>.".contains(c) {
                    tokens.append(.symbol(String(c))); i += 1
                } else { throw error("Unsupported expression character '\(c)'") }
            }
        }
        tokens.append(.end)
    }

    static func isStart(_ c: Character) -> Bool {
        c == "_" || (c.isASCII && c.isLetter)
    }
    static func isPart(_ c: Character) -> Bool {
        isStart(c) || (c.isASCII && c.isNumber)
    }
    static func isName(_ s: String) -> Bool {
        guard let first = s.first, isStart(first) else { return false }
        return s.allSatisfy(isPart) && !["true", "false", "null", "contains"].contains(s)
    }

    mutating func parse() throws -> Expression {
        let result = try expression(minimum: 0, depth: 0)
        guard tokens[index] == .end else { throw error("Unexpected token after expression") }
        return result
    }

    private mutating func expression(minimum: Int, depth: Int) throws -> Expression {
        guard depth < 64 else { throw error("Expression nesting exceeds 64") }
        var lhs = try primary(depth: depth + 1)
        let precedence = ["||": 1, "&&": 2, "==": 3, "!=": 3, "contains": 3, "<": 4, "<=": 4,
                          ">": 4, ">=": 4, "+": 5, "-": 5, "*": 6, "/": 6, "%": 6]
        while case .symbol(let op) = tokens[index], let p = precedence[op], p >= minimum {
            index += 1
            lhs = .binary(op, lhs, try expression(minimum: p + 1, depth: depth + 1))
        }
        return lhs
    }

    private mutating func primary(depth: Int) throws -> Expression {
        guard depth < 64 else { throw error("Expression nesting exceeds 64") }
        var result: Expression
        switch tokens[index] {
        case .literal(let value):
            index += 1; result = .literal(value)
        case .identifier(let name):
            guard variables.contains(name) else { throw error("Undeclared variable '\(name)'") }
            index += 1; result = .variable(name)
        case .symbol(let op) where ["!", "-", "+"].contains(op):
            index += 1
            return .unary(op, try primary(depth: depth + 1))
        case .symbol("("):
            index += 1
            result = try expression(minimum: 0, depth: depth + 1)
            guard tokens[index] == .symbol(")") else { throw error("Expected ')'") }
            index += 1
        default: throw error("Expected a value or variable")
        }
        while tokens[index] == .symbol(".") {
            index += 1
            guard case .identifier(let name) = tokens[index] else { throw error("Expected member name") }
            index += 1
            result = .member(result, name)
        }
        return result
    }

    private func error(_ message: String) -> DSLParseError {
        DSLParseError(path: path, message: message)
    }
}
