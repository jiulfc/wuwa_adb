import Foundation

@main
struct FeixueCombatCheck {
    static func main() throws {
        let data = try Data(contentsOf: URL(fileURLWithPath: "scripts/common/combat_role_feixue.json"))
        let workflow = try WorkflowParser().parse(data)

        precondition(workflow.variables["v_point"] == .array([.number(2786), .number(1244)]))
        precondition(workflow.variables["r_point"] == .array([.number(2187), .number(1136)]))
        precondition(workflow.variables["third_a_recovery_ms"] == .number(500))
        precondition(workflow.variables["heavy_a_hold_ms"] == .number(1000))
        precondition(workflow.variables["r_recovery_ms"] == .number(3000))

        func fast(_ step: Step) -> Step {
            switch step {
            case .whileLoop(let condition, let steps):
                return .whileLoop(condition: condition, steps: steps.map(fast))
            case .conditional(let condition, let yes, let no):
                return .conditional(condition: condition, then: yes.map(fast), otherwise: no.map(fast))
            case .tap(let point, let duration):
                let taggedPoint: Input = duration == .expression(.variable("heavy_a_hold_ms"))
                    ? .literal(.array([.number(1000), .number(1000)])) : point
                return .tap(point: taggedPoint, duration: .literal(.number(1)))
            case .wait:
                return .wait(milliseconds: .literal(.number(0)))
            default:
                return step
            }
        }

        var variables = workflow.variables
        variables["max_rounds"] = .number(1)
        let testWorkflow = Workflow(version: 3, variables: variables, steps: workflow.steps.map(fast))
        var touches: [[Double]] = []
        let runner = WorkflowRunner(checkCancelled: {}, script: { _, _, _ in }, vision: { _, _, _, _ in
            fatalError("Feixue combat must not require vision")
        }, touch: { point, action in
            if action == .down { touches.append(point) }
        }, log: { _ in })
        try runner.run(testWorkflow)

        let a = [2571.0, 1123.0]
        let e = [2348.0, 1260.0]
        let heavy = [1000.0, 1000.0]
        let expected = Array(repeating: a, count: 9) + [heavy] + Array(repeating: e, count: 2)
            + Array(repeating: a, count: 6) + [e, [2786, 1244]] + Array(repeating: a, count: 4)
            + [heavy, [2187, 1136]]
        precondition(touches == expected)

        print("Feixue combat round order and timing variables passed")
    }
}
