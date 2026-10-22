import Foundation

public struct DSLParseError: Error, LocalizedError, CustomStringConvertible, Equatable {
    public let path: String
    public let message: String
    public var description: String { "\(path): \(message)" }
    public var errorDescription: String? { description }
}

public indirect enum JSONValue: Decodable, Equatable, Sendable {
    case null, bool(Bool), number(Double), string(String)
    case array([JSONValue]), object([String: JSONValue])

    public init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self), v.isFinite { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([JSONValue].self) { self = .array(v) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }
}

public indirect enum Expression: Equatable, Sendable {
    case literal(JSONValue)
    case variable(String)
    case member(Expression, String)
    case index(Expression, Expression)
    case unary(String, Expression)
    case binary(String, Expression, Expression)
}

public indirect enum Input: Equatable, Sendable {
    case literal(JSONValue), expression(Expression)
    case array([Input]), object([String: Input])
}

public struct Workflow: Equatable, Sendable {
    public let version: Int
    public let variables: [String: JSONValue]
    public let steps: [Step]

    func applying(props: [String: JSONValue]) throws -> Workflow {
        guard case .object(let defaults) = variables["props"] else {
            throw replayError("A script receiving props must declare vars.props as an object.")
        }
        let unknown = Set(props.keys).subtracting(defaults.keys)
        guard unknown.isEmpty else {
            throw replayError("Undeclared props: \(unknown.sorted().joined(separator: ", "))")
        }
        var values = variables
        values["props"] = .object(defaults.merging(props) { _, passed in passed })
        return Workflow(version: version, variables: values, steps: steps)
    }
}

public enum VisionKind: String, Equatable, Sendable {
    case ocrText = "ocr_text"
    case templateMatch = "template_match"
    case skillCheck = "skill_check"
    case circlePercentage = "circle_percentage"
}

public enum VisionOutputType: Equatable, Sendable {
    case int, double
}

public struct VisionCommand: Equatable, Sendable {
    public let kind: VisionKind
    public let roi: Input
    public let output: String
    public let outputType: VisionOutputType?
    /// Additional validated inputs: template, model, skill, profile, threshold.
    public let parameters: [String: Input]
}

public indirect enum Step: Equatable, Sendable {
    case assign(target: String, value: Input)
    case debug(info: Input)
    case whileLoop(condition: Input, steps: [Step])
    case conditional(condition: Input, then: [Step], otherwise: [Step])
    case runFor(duration: Input, steps: [Step])
    case runUntil(checkEvery: Input, timeout: Input, check: [Step], until: Input, steps: [Step])
    case script(name: Input, props: Input? = nil)
    case vision(VisionCommand)
    case tap(point: Input, duration: Input)
    case drag(from: Input, to: Input, duration: Input)
    case wait(milliseconds: Input)
    case breakLoop, continueLoop, returnFromScript
}

func replayError(_ message: String) -> NSError {
    NSError(domain: "AdbQuick.Replay", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
}
