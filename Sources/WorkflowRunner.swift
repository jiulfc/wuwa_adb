import Foundation

typealias WorkflowCancellationCheck = () throws -> Void

enum WorkflowTouchAction: String {
    case down, move, up
}

/// Executes one parsed workflow. Device and vision work stays in the host callbacks.
struct WorkflowRunner {
    let checkCancelled: WorkflowCancellationCheck
    let script: (String, @escaping WorkflowCancellationCheck) throws -> Void
    let vision: (VisionKind, [Double], [String: JSONValue], WorkflowCancellationCheck) throws -> JSONValue
    let touch: ([Double], WorkflowTouchAction) throws -> Void
    let log: (String) -> Void

    func run(_ workflow: Workflow) throws {
        let variables = WorkflowVariables(workflow.variables)
        _ = try execute(workflow.steps, variables: variables, check: checkCancelled)
    }

    private func execute(_ steps: [Step], variables: WorkflowVariables,
                         check: @escaping WorkflowCancellationCheck) throws -> WorkflowSignal {
        for step in steps {
            try check()
            let signal = try execute(step, variables: variables, check: check)
            if signal != .none { return signal }
        }
        return .none
    }

    private func execute(_ step: Step, variables: WorkflowVariables,
                         check: @escaping WorkflowCancellationCheck) throws -> WorkflowSignal {
        switch step {
        case .assign(let target, let input):
            variables.set(target, to: try value(input, variables.snapshot()))
        case .whileLoop(let condition, let steps):
            while try conditionResult("while", condition, variables.snapshot()) {
                try check()
                switch try execute(steps, variables: variables, check: check) {
                case .none, .continueLoop: continue
                case .breakLoop: return .none
                case .returnFromScript: return .returnFromScript
                }
            }
        case .conditional(let condition, let yes, let no):
            return try execute(conditionResult("if", condition, variables.snapshot()) ? yes : no,
                               variables: variables, check: check)
        case .runFor(let duration, let body):
            return try runFor(duration: try milliseconds(duration, variables.snapshot(), minimum: 1),
                              body: body, variables: variables, parentCheck: check)
        case .runUntil(let interval, let timeout, let checkSteps, let until, let body):
            return try runUntil(interval: try milliseconds(interval, variables.snapshot(), minimum: 1),
                                timeout: try milliseconds(timeout, variables.snapshot(), minimum: 1),
                                checkSteps: checkSteps, until: until, body: body,
                                variables: variables, parentCheck: check)
        case .script(let name):
            let name = try string(name, variables.snapshot())
            guard !name.isEmpty else { throw replayError("script_name 不能为空。") }
            try script(name, check)
        case .vision(let command):
            let snapshot = variables.snapshot()
            let roi = try coordinates(command.roi, snapshot, count: 4)
            guard roi[2] > 0, roi[3] > 0 else { throw replayError("ROI 宽高必须为正数。") }
            var parameters: [String: JSONValue] = [:]
            for (name, input) in command.parameters { parameters[name] = try value(input, snapshot) }
            try validate(command.kind, parameters: parameters)
            let result = try converted(vision(command.kind, roi, parameters, check), as: command.outputType)
            variables.set(command.output, to: result)
            if command.kind == .circlePercentage, case .number(let percentage) = result {
                log("[Workflow] Step: type=circle_percentage, output=\(command.output), percentage=\(percentage)")
            } else if case .string(let text) = result {
                log("[Workflow] Step: type=\(command.kind.rawValue), output=\(command.output), text=\(text.debugDescription)")
            } else {
                log("[Workflow] Step: type=\(command.kind.rawValue), output=\(command.output), result=\(result)")
            }
        case .tap(let point, let duration):
            let snapshot = variables.snapshot()
            let point = try coordinates(point, snapshot, count: 2)
            let duration = try milliseconds(duration, snapshot, minimum: 1)
            try touch(point, .down)
            defer { try? touch(point, .up) }
            try wait(milliseconds: duration, check: check)
        case .drag(let from, let to, let duration):
            let snapshot = variables.snapshot()
            let from = try coordinates(from, snapshot, count: 2)
            let to = try coordinates(to, snapshot, count: 2)
            let duration = try milliseconds(duration, snapshot, minimum: 1)
            var releasePoint = from
            try touch(from, .down)
            defer { try? touch(releasePoint, .up) }
            try touch(to, .move)
            releasePoint = to
            try wait(milliseconds: duration, check: check)
        case .wait(let duration):
            try wait(milliseconds: try milliseconds(duration, variables.snapshot(), minimum: 0), check: check)
        case .breakLoop: return .breakLoop
        case .continueLoop: return .continueLoop
        case .returnFromScript: return .returnFromScript
        }
        return .none
    }

    private func runFor(duration: Int, body: [Step], variables: WorkflowVariables,
                        parentCheck: @escaping WorkflowCancellationCheck) throws -> WorkflowSignal {
        let deadline = DispatchTime.now().uptimeNanoseconds + nanoseconds(duration)
        let cancellation = WorkflowConcurrentCancellation(deadline: deadline, timeoutMessage: nil)
        let scopedCheck = { try cancellation.check(parent: parentCheck) }
        let state = startConcurrent(body: body, variables: variables, check: scopedCheck)
        do {
            while true {
                if let result = state.result {
                    cancellation.cancel()
                    do { return try result.get() }
                    catch is WorkflowRunForComplete { return .none }
                }
                try scopedCheck()
                state.wait(nanoseconds: 50_000_000)
            }
        } catch is WorkflowRunForComplete {
            cancellation.cancel()
            try waitForStoppedBody(state, ignoringDeadline: true)
            return .none
        } catch {
            cancellation.cancel()
            try? waitForStoppedBody(state)
            throw error
        }
    }

    private func runUntil(interval: Int, timeout: Int, checkSteps: [Step], until: Input,
                          body: [Step], variables: WorkflowVariables,
                          parentCheck: @escaping WorkflowCancellationCheck) throws -> WorkflowSignal {
        let deadline = DispatchTime.now().uptimeNanoseconds + nanoseconds(timeout)
        let cancellation = WorkflowConcurrentCancellation(deadline: deadline, timeoutMessage: "run_until 超时。")
        let scopedCheck = { try cancellation.check(parent: parentCheck) }

        _ = try execute(checkSteps, variables: variables, check: scopedCheck)
        if try conditionResult("run_until", until, variables.snapshot()) { return .none }

        let state = startConcurrent(body: body, variables: variables, check: scopedCheck)

        var nextCheck = DispatchTime.now().uptimeNanoseconds + nanoseconds(interval)
        do {
            while true {
                try scopedCheck()
                if let result = state.result { cancellation.cancel(); return try result.get() }

                let now = DispatchTime.now().uptimeNanoseconds
                if now < nextCheck {
                    state.wait(nanoseconds: min(nextCheck - now, 50_000_000))
                    continue
                }

                _ = try execute(checkSteps, variables: variables, check: scopedCheck)
                if let result = state.result { cancellation.cancel(); return try result.get() }
                let matched = try conditionResult("run_until", until, variables.snapshot())
                if let result = state.result { cancellation.cancel(); return try result.get() }
                if matched {
                    cancellation.cancel()
                    try waitForStoppedBody(state)
                    return .none
                }
                repeat { nextCheck += nanoseconds(interval) }
                while nextCheck <= DispatchTime.now().uptimeNanoseconds
            }
        } catch {
            cancellation.cancel()
            try? waitForStoppedBody(state)
            throw error
        }
    }

    private func startConcurrent(body: [Step], variables: WorkflowVariables,
                                 check: @escaping WorkflowCancellationCheck) -> WorkflowConcurrentState {
        let state = WorkflowConcurrentState()
        let work = WorkflowConcurrentWork(runner: self, body: body, variables: variables, check: check)
        DispatchQueue.global(qos: .userInitiated).async {
            do { state.finish(.success(try work.runner.execute(work.body, variables: work.variables, check: work.check))) }
            catch { state.finish(.failure(error)) }
        }
        return state
    }

    private func waitForStoppedBody(_ state: WorkflowConcurrentState, ignoringDeadline: Bool = false) throws {
        while state.result == nil { state.wait(nanoseconds: 50_000_000) }
        if case .failure(let error)? = state.result,
           !(error is WorkflowConcurrentStopped), !(ignoringDeadline && error is WorkflowRunForComplete) {
            throw error
        }
    }

    private func wait(milliseconds: Int, check: WorkflowCancellationCheck) throws {
        let deadline = DispatchTime.now().uptimeNanoseconds + nanoseconds(milliseconds)
        while true {
            try check()
            let now = DispatchTime.now().uptimeNanoseconds
            if now >= deadline { return }
            _ = DispatchSemaphore(value: 0).wait(timeout: .now() + .nanoseconds(Int(min(deadline - now, 50_000_000))))
        }
    }

    private func nanoseconds(_ milliseconds: Int) -> UInt64 {
        UInt64(milliseconds) * 1_000_000
    }

    private func value(_ input: Input, _ variables: [String: JSONValue]) throws -> JSONValue {
        switch input {
        case .literal(let value): return value
        case .expression(let expression): return try value(expression, variables)
        case .array(let values): return .array(try values.map { try value($0, variables) })
        case .object(let values):
            var result: [String: JSONValue] = [:]
            for (key, input) in values { result[key] = try value(input, variables) }
            return .object(result)
        }
    }

    private func value(_ expression: Expression, _ variables: [String: JSONValue]) throws -> JSONValue {
        switch expression {
        case .literal(let value): return value
        case .variable(let name):
            guard let value = variables[name] else { throw replayError("变量不存在：\(name)") }
            return value
        case .member(let base, let name):
            guard case .object(let object) = try value(base, variables), let value = object[name] else {
                throw replayError("对象成员不存在：\(name)")
            }
            return value
        case .unary("!", let operand): return .bool(!(try boolean(value(operand, variables))))
        case .unary("-", let operand): return try finite(-number(value(operand, variables)))
        case .unary("+", let operand): return try finite(number(value(operand, variables)))
        case .unary(let operation, _): throw replayError("不支持的一元运算：\(operation)")
        case .binary("&&", let left, let right):
            return .bool(try boolean(value(left, variables)) && boolean(value(right, variables)))
        case .binary("||", let left, let right):
            return .bool(try boolean(value(left, variables)) || boolean(value(right, variables)))
        case .binary(let operation, let left, let right):
            let lhs = try value(left, variables)
            let rhs = try value(right, variables)
            switch operation {
            case "==": return .bool(lhs == rhs)
            case "!=": return .bool(lhs != rhs)
            case "contains":
                guard case .string(let text) = lhs, case .string(let phrase) = rhs else {
                    throw replayError("contains 需要字符串。")
                }
                let actual = text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ").lowercased()
                let expected = phrase.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ").lowercased()
                return .bool(!expected.isEmpty && actual.contains(expected))
            case "<": return .bool(try number(lhs) < number(rhs))
            case "<=": return .bool(try number(lhs) <= number(rhs))
            case ">": return .bool(try number(lhs) > number(rhs))
            case ">=": return .bool(try number(lhs) >= number(rhs))
            case "+": return try finite(number(lhs) + number(rhs))
            case "-": return try finite(number(lhs) - number(rhs))
            case "*": return try finite(number(lhs) * number(rhs))
            case "/": return try finite(number(lhs) / number(rhs))
            case "%": return try finite(number(lhs).truncatingRemainder(dividingBy: number(rhs)))
            default: throw replayError("不支持的二元运算：\(operation)")
            }
        }
    }

    private func boolean(_ input: Input, _ variables: [String: JSONValue]) throws -> Bool {
        try boolean(value(input, variables))
    }

    private func conditionResult(_ type: String, _ input: Input, _ variables: [String: JSONValue]) throws -> Bool {
        let matched = try boolean(input, variables)
        log("[Workflow] Condition: type=\(type), matched=\(matched)")
        return matched
    }

    private func boolean(_ value: JSONValue) throws -> Bool {
        guard case .bool(let result) = value else { throw replayError("条件必须是布尔值。") }
        return result
    }

    private func number(_ value: JSONValue) throws -> Double {
        guard case .number(let result) = value, result.isFinite else { throw replayError("需要有限数值。") }
        return result
    }

    private func finite(_ number: Double) throws -> JSONValue {
        guard number.isFinite else { throw replayError("数值运算结果无效。") }
        return .number(number)
    }

    private func converted(_ value: JSONValue, as type: VisionOutputType?) throws -> JSONValue {
        guard let type else { return value }
        guard case .string(let raw) = value else { throw replayError("typed ocr_text 需要文字识别结果。") }
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let number = Double(text), number.isFinite else { throw replayError("OCR 结果不是有效数字：\(raw)") }
        if type == .int {
            guard number.rounded() == number, abs(number) <= 9_007_199_254_740_991 else {
                throw replayError("OCR 结果不是可精确表示的整数：\(raw)")
            }
        }
        return .number(number)
    }

    private func string(_ input: Input, _ variables: [String: JSONValue]) throws -> String {
        guard case .string(let result) = try value(input, variables) else { throw replayError("需要字符串。") }
        return result
    }

    private func milliseconds(_ input: Input, _ variables: [String: JSONValue], minimum: Int) throws -> Int {
        let value = try number(value(input, variables))
        guard value.rounded() == value, value >= Double(minimum), value <= Double(Int.max) / 1_000_000 else {
            throw replayError("毫秒数必须是有效整数。")
        }
        return Int(value)
    }

    private func coordinates(_ input: Input, _ variables: [String: JSONValue], count: Int) throws -> [Double] {
        guard case .array(let values) = try value(input, variables), values.count == count else {
            throw replayError("坐标需要 \(count) 个数值。")
        }
        let result = try values.map(number)
        guard result.allSatisfy({ $0 >= 0 }) else { throw replayError("坐标不能为负数。") }
        return result
    }

    private func validate(_ kind: VisionKind, parameters: [String: JSONValue]) throws {
        func nonempty(_ name: String) throws {
            guard case .string(let value) = parameters[name], !value.isEmpty else {
                throw replayError("\(name) 需要非空字符串。")
            }
        }
        func threshold(_ minimum: Double) throws {
            guard let input = parameters["threshold"] else { throw replayError("缺少 threshold。") }
            let value = try number(input)
            guard value >= minimum, value <= 1 else { throw replayError("threshold 超出范围。") }
        }
        switch kind {
        case .ocrText: break
        case .templateMatch: try nonempty("template"); try threshold(-1)
        case .skillCheck: try nonempty("model"); try nonempty("skill"); try threshold(0)
        case .circlePercentage: try nonempty("profile")
        }
    }
}

private enum WorkflowSignal: Equatable {
    case none, breakLoop, continueLoop, returnFromScript
}

private struct WorkflowConcurrentWork: @unchecked Sendable {
    let runner: WorkflowRunner
    let body: [Step]
    let variables: WorkflowVariables
    let check: WorkflowCancellationCheck
}

private final class WorkflowVariables: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: JSONValue]

    init(_ values: [String: JSONValue]) { self.values = values }

    func snapshot() -> [String: JSONValue] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }

    func set(_ name: String, to value: JSONValue) {
        lock.lock()
        values[name] = value
        lock.unlock()
    }
}

private struct WorkflowConcurrentStopped: Error {}
private struct WorkflowRunForComplete: Error {}

private final class WorkflowConcurrentCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private let deadline: UInt64
    private let timeoutMessage: String?
    private var stopped = false

    init(deadline: UInt64, timeoutMessage: String?) {
        self.deadline = deadline
        self.timeoutMessage = timeoutMessage
    }

    func cancel() {
        lock.lock()
        stopped = true
        lock.unlock()
    }

    func check(parent: WorkflowCancellationCheck) throws {
        try parent()
        lock.lock()
        let stopped = self.stopped
        lock.unlock()
        if stopped { throw WorkflowConcurrentStopped() }
        if DispatchTime.now().uptimeNanoseconds >= deadline {
            if let timeoutMessage { throw replayError(timeoutMessage) }
            throw WorkflowRunForComplete()
        }
    }
}

private final class WorkflowConcurrentState: @unchecked Sendable {
    private let lock = NSLock()
    private let changed = DispatchSemaphore(value: 0)
    private var stored: Result<WorkflowSignal, Error>?

    var result: Result<WorkflowSignal, Error>? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func finish(_ result: Result<WorkflowSignal, Error>) {
        lock.lock()
        stored = result
        lock.unlock()
        changed.signal()
    }

    func wait(nanoseconds: UInt64) {
        _ = changed.wait(timeout: .now() + .nanoseconds(Int(nanoseconds)))
    }
}
