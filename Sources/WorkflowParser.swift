import Foundation

public struct WorkflowParser {
    public init() {}

    /// Parses one script. Asset loading, expression evaluation, and device I/O belong to the host.
    public func parse(_ data: Data) throws -> Workflow {
        guard data.count <= 1_048_576 else {
            throw DSLParseError(path: "$", message: "Workflow exceeds 1 MiB")
        }
        let value: JSONValue
        do { value = try JSONDecoder().decode(JSONValue.self, from: data) }
        catch {
            throw DSLParseError(path: "$", message: "Invalid JSON: \(error)")
        }
        let root = try object(value, at: "$")
        try fields(root, required: ["version", "vars", "steps"], optional: ["label"], at: "$")
        try validateLabel(root, at: "$")
        guard root["version"] == .number(3) else {
            throw DSLParseError(path: "$.version", message: "Only DSL version 3 is supported")
        }
        let vars = try object(root["vars"]!, at: "$.vars")
        for name in vars.keys.sorted() where !ExpressionParser.isName(name) {
            throw DSLParseError(path: "$.vars.\(name)", message: "Invalid variable name")
        }
        let validator = Validator(variables: Set(vars.keys))
        return Workflow(version: 3, variables: vars,
                        steps: try validator.steps(root["steps"]!, at: "$.steps", loops: 0, inCheck: false, depth: 0))
    }
}

private func object(_ value: JSONValue, at path: String) throws -> [String: JSONValue] {
    guard case .object(let result) = value else {
        throw DSLParseError(path: path, message: "Expected an object")
    }
    return result
}

private func fields(_ obj: [String: JSONValue], required: Set<String>, optional: Set<String> = [], at path: String) throws {
    if let missing = required.subtracting(obj.keys).sorted().first {
        throw DSLParseError(path: "\(path).\(missing)", message: "Missing required field")
    }
    if let extra = Set(obj.keys).subtracting(required.union(optional)).sorted().first {
        throw DSLParseError(path: "\(path).\(extra)", message: "Unknown field")
    }
}

private func validateLabel(_ obj: [String: JSONValue], at path: String) throws {
    if let label = obj["label"], case .string = label { return }
    if obj["label"] != nil { throw DSLParseError(path: "\(path).label", message: "Expected a string") }
}

private struct Validator {
    let variables: Set<String>

    func steps(_ value: JSONValue, at path: String, loops: Int, inCheck: Bool, depth: Int) throws -> [Step] {
        guard depth < 64 else { throw fail(path, "Step nesting exceeds 64") }
        guard case .array(let values) = value else { throw fail(path, "Expected a steps array") }
        return try values.enumerated().map { i, value in
            try step(value, at: "\(path)[\(i)]", loops: loops, inCheck: inCheck, depth: depth)
        }
    }

    private func step(_ value: JSONValue, at path: String, loops: Int, inCheck: Bool, depth: Int) throws -> Step {
        let obj = try object(value, at: path)
        guard case .string(let type) = obj["type"] else { throw fail(path + ".type", "Expected command name") }
        func schema(_ required: Set<String>, _ optional: Set<String> = []) throws {
            try fields(obj, required: required.union(["type"]), optional: optional.union(["label"]), at: path)
            try validateLabel(obj, at: path)
        }
        func input(_ name: String) throws -> Input {
            try self.input(obj[name]!, at: path + "." + name)
        }
        func body(_ name: String, loopDepth: Int? = nil, check: Bool? = nil) throws -> [Step] {
            try steps(obj[name]!, at: path + "." + name, loops: loopDepth ?? loops,
                      inCheck: check ?? inCheck, depth: depth + 1)
        }
        if inCheck && ["tap", "drag", "script", "monitor", "wait", "return"].contains(type) {
            throw fail(path, "'\(type)' is not allowed in a monitor check")
        }
        switch type {
        case "assign":
            try schema(["target", "value"])
            return .assign(target: try destination(obj["target"]!, at: path + ".target"), value: try input("value"))
        case "while":
            try schema(["condition", "steps"])
            return .whileLoop(condition: try condition(input("condition"), at: path + ".condition"),
                              steps: try body("steps", loopDepth: loops + 1))
        case "if":
            try schema(["condition", "then"], ["else"])
            return .conditional(condition: try condition(input("condition"), at: path + ".condition"),
                                then: try body("then"), otherwise: try obj["else"] == nil ? [] : body("else"))
        case "monitor":
            try schema(["interval_ms", "timeout_ms", "check", "until", "steps"])
            let interval = try number(input("interval_ms"), at: path + ".interval_ms", minimum: 1, integer: true)
            let timeout = try number(input("timeout_ms"), at: path + ".timeout_ms", minimum: 1, integer: true)
            let check = try body("check", loopDepth: 0, check: true)
            let main = try body("steps")
            let overlap = writes(check).intersection(writes(main))
            guard overlap.isEmpty else { throw fail(path, "Check and body both write: \(overlap.sorted().joined(separator: ", "))") }
            return .monitor(interval: interval, timeout: timeout, check: check,
                            until: try condition(input("until"), at: path + ".until"), steps: main)
        case "script":
            try schema(["script_name"])
            return .script(name: try string(input("script_name"), at: path + ".script_name"))
        case "tap":
            try schema(["point", "duration_ms"])
            return .tap(point: try coordinates(input("point"), count: 2, at: path + ".point"),
                        duration: try number(input("duration_ms"), at: path + ".duration_ms", minimum: 1, integer: true))
        case "drag":
            try schema(["from", "to", "duration_ms"])
            return .drag(from: try coordinates(input("from"), count: 2, at: path + ".from"),
                         to: try coordinates(input("to"), count: 2, at: path + ".to"),
                         duration: try number(input("duration_ms"), at: path + ".duration_ms", minimum: 1, integer: true))
        case "wait":
            try schema(["wait_ms"])
            return .wait(milliseconds: try number(input("wait_ms"), at: path + ".wait_ms", minimum: 0, integer: true))
        case "break", "continue", "return":
            try schema([])
            if type != "return" && loops == 0 { throw fail(path, "'\(type)' requires an enclosing loop in the same execution scope") }
            return type == "break" ? .breakLoop : type == "continue" ? .continueLoop : .returnFromScript
        default:
            guard let kind = VisionKind(rawValue: type) else { throw fail(path + ".type", "Unknown command '\(type)'") }
            let extras: Set<String>
            switch kind {
            case .ocrText: extras = []
            case .templateMatch: extras = ["template", "threshold"]
            case .skillCheck: extras = ["model", "skill", "threshold"]
            case .circlePercentage: extras = ["profile"]
            }
            try schema(extras.union(["roi", "output"]))
            var parameters: [String: Input] = [:]
            for key in extras.sorted() {
                let v = try input(key)
                parameters[key] = key == "threshold"
                    ? try number(v, at: path + "." + key, minimum: kind == .templateMatch ? -1 : 0, maximum: 1)
                    : try string(v, at: path + "." + key)
            }
            let output = try visionDestination(obj["output"]!, kind: kind, at: path + ".output")
            return .vision(VisionCommand(kind: kind,
                                         roi: try coordinates(input("roi"), count: 4, at: path + ".roi"),
                                         output: output.name, outputType: output.type, parameters: parameters))
        }
    }

    private func input(_ value: JSONValue, at path: String, depth: Int = 0) throws -> Input {
        guard depth < 64 else { throw fail(path, "Input nesting exceeds 64") }
        switch value {
        case .string(let text) where text.contains("${"):
            guard text.hasPrefix("${"), text.hasSuffix("}") else {
                throw fail(path, "An expression must occupy the entire string; interpolation is unsupported")
            }
            let source = String(text.dropFirst(2).dropLast())
            guard source.count <= 4096 else { throw fail(path, "Expression exceeds 4096 characters") }
            var parser = try ExpressionParser(source, path: path, variables: variables)
            let expression = try parser.parse()
            _ = try kind(expression, at: path)
            return .expression(expression)
        case .array(let values):
            return .array(try values.enumerated().map { try input($0.element, at: "\(path)[\($0.offset)]", depth: depth + 1) })
        case .object(let values):
            var result: [String: Input] = [:]
            for key in values.keys.sorted() { result[key] = try input(values[key]!, at: path + "." + key, depth: depth + 1) }
            return .object(result)
        default: return .literal(value)
        }
    }

    private func destination(_ value: JSONValue, at path: String) throws -> String {
        guard case .expression(.variable(let name)) = try input(value, at: path) else {
            throw fail(path, "Expected a single variable reference such as ${button_text}")
        }
        return name
    }

    private func visionDestination(_ value: JSONValue, kind: VisionKind,
                                   at path: String) throws -> (name: String, type: VisionOutputType?) {
        guard case .string(let reference) = value, reference.hasPrefix("${"), reference.hasSuffix("}") else {
            throw fail(path, "Expected a variable reference such as ${button_text}")
        }
        let parts = reference.dropFirst(2).dropLast().split(separator: ":", omittingEmptySubsequences: false)
        guard let rawName = parts.first, parts.count <= 2 else {
            throw fail(path, "Invalid output variable reference")
        }
        let name = String(rawName)
        guard ExpressionParser.isName(name), variables.contains(name) else {
            throw fail(path, "Undeclared or invalid output variable '\(name)'")
        }
        guard parts.count == 2 else { return (name, nil) }
        guard kind == .ocrText else { throw fail(path, "Typed output is only supported by ocr_text") }
        switch parts[1] {
        case "int": return (name, .int)
        case "double": return (name, .double)
        default: throw fail(path, "Output type must be int or double")
        }
    }

    private enum Kind { case boolean, number, string, array, object, null, dynamic }

    private func kind(_ value: JSONValue) -> Kind {
        switch value {
        case .bool: return .boolean
        case .number: return .number
        case .string: return .string
        case .array: return .array
        case .object: return .object
        case .null: return .null
        }
    }

    private func kind(_ value: Input, at path: String) throws -> Kind {
        switch value {
        case .literal(let v): return kind(v)
        case .expression(let e): return try kind(e, at: path)
        case .array: return .array
        case .object: return .object
        }
    }

    private func kind(_ expression: Expression, at path: String) throws -> Kind {
        switch expression {
        case .literal(let v): return kind(v)
        case .variable: return .dynamic
        case .member(let base, _):
            let k = try kind(base, at: path)
            guard k == .object || k == .dynamic else { throw fail(path, "Member access requires an object") }
            return .dynamic
        case .unary(let op, let value):
            let expected: Kind = op == "!" ? .boolean : .number
            try expect(kind(value, at: path), expected, at: path)
            return expected
        case .binary(let op, let left, let right):
            let a = try kind(left, at: path), b = try kind(right, at: path)
            if ["==", "!="].contains(op) { return .boolean }
            if op == "contains" {
                try expect(a, .string, at: path)
                try expect(b, .string, at: path)
                return .boolean
            }
            let expected: Kind = ["&&", "||"].contains(op) ? .boolean : .number
            try expect(a, expected, at: path)
            try expect(b, expected, at: path)
            return ["&&", "||", "<", "<=", ">", ">="].contains(op) ? .boolean : .number
        }
    }

    private func expect(_ actual: Kind, _ expected: Kind, at path: String) throws {
        guard actual == expected || actual == .dynamic else { throw fail(path, "Expected \(expected), got \(actual)") }
    }

    private func condition(_ value: Input, at path: String) throws -> Input {
        try expect(kind(value, at: path), .boolean, at: path)
        return value
    }

    private func string(_ value: Input, at path: String) throws -> Input {
        try expect(kind(value, at: path), .string, at: path)
        if let literal = literal(value), case .string(let s) = literal, s.isEmpty { throw fail(path, "Expected nonempty string") }
        return value
    }

    private func literal(_ value: Input) -> JSONValue? {
        switch value {
        case .literal(let v), .expression(.literal(let v)): return v
        case .expression(.unary("-", .literal(.number(let n)))): return .number(-n)
        case .expression(.unary("+", .literal(.number(let n)))): return .number(n)
        default: return nil
        }
    }

    private func number(_ value: Input, at path: String, minimum: Double, maximum: Double = .greatestFiniteMagnitude, integer: Bool = false) throws -> Input {
        try expect(kind(value, at: path), .number, at: path)
        if let literal = literal(value), case .number(let n) = literal {
            guard n.isFinite, n >= minimum, n <= maximum, !integer || n.rounded() == n else {
                throw fail(path, "Number is outside the permitted range or is not an integer")
            }
        }
        return value
    }

    private func coordinates(_ value: Input, count: Int, at path: String) throws -> Input {
        try expect(kind(value, at: path), .array, at: path)
        if case .array(let items) = value {
            guard items.count == count else { throw fail(path, "Expected \(count) coordinates") }
            for (i, item) in items.enumerated() {
                _ = try number(item, at: "\(path)[\(i)]", minimum: 0)
                if count == 4 && i >= 2, let literal = literal(item), case .number(let n) = literal, n <= 0 {
                    throw fail("\(path)[\(i)]", "ROI dimensions must be positive")
                }
            }
        }
        return value
    }

    private func writes(_ steps: [Step]) -> Set<String> {
        steps.reduce(into: Set<String>()) { result, step in
            switch step {
            case .assign(let target, _): result.insert(target)
            case .vision(let v): result.insert(v.output)
            case .whileLoop(_, let body): result.formUnion(writes(body))
            case .conditional(_, let yes, let no): result.formUnion(writes(yes)); result.formUnion(writes(no))
            case .monitor(_, _, let check, _, let body): result.formUnion(writes(check)); result.formUnion(writes(body))
            default: break
            }
        }
    }

    private func fail(_ path: String, _ message: String) -> DSLParseError {
        DSLParseError(path: path, message: message)
    }
}
