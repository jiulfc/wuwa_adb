import Foundation

@main
struct KatixiyaOptimize1Check {
    static func main() throws {
        let data = try Data(contentsOf: URL(fileURLWithPath: "scripts/common/combat_role_katixiya_optimize_1.json"))
        let workflow = try WorkflowParser().parse(data)

        func fast(_ step: Step) -> Step {
            switch step {
            case .whileLoop(let condition, let steps):
                return .whileLoop(condition: condition, steps: steps.map(fast))
            case .conditional(let condition, let yes, let no):
                return .conditional(condition: condition, then: yes.map(fast), otherwise: no.map(fast))
            case .wait: return .wait(milliseconds: .literal(.number(0)))
            default: return step
            }
        }

        var variables = workflow.variables
        variables["max_cycles"] = .number(7)
        for name in ["lock_tap_ms", "s_tap_ms", "a_1_tap_ms", "a_2_tap_ms", "a_3_tap_ms",
                     "heavy_a_tap_ms", "e_tap_ms", "a_4_tap_ms", "current_tap_ms"] {
            variables[name] = .number(1)
        }
        let testWorkflow = Workflow(version: 3, variables: variables, steps: workflow.steps.map(fast))
        var checkedSkills: [String] = []
        var checkedAs = 0
        var downPoints: [[Double]] = []
        let runner = WorkflowRunner(checkCancelled: {}, script: { _, _ in }, vision: { _, _, parameters, _ in
            guard case .string(let skill) = parameters["skill"] else { fatalError("Missing combo skill") }
            checkedSkills.append(skill)
            if skill == "A" { checkedAs += 1 }
            let usable = skill != "S" && (skill != "A" || checkedAs != 2)
            let point: JSONValue = skill == "E" ? .array([.number(2348), .number(1260)])
                                                   : .array([.number(2568), .number(1120)])
            return .object(["state": .string(usable ? "usable" : "unusable"), "point": point])
        }, touch: { point, action in
            if action == .down { downPoints.append(point) }
        }, log: { _ in })
        try runner.run(testWorkflow)

        precondition(checkedSkills == ["S", "A", "S", "A", "S", "A", "S", "A",
                                       "S", "A", "S", "A", "S", "E"])
        precondition(downPoints == [[955, 1220], [2568, 1120], [2568, 1120], [2568, 1120],
                                    [2568, 1120], [2571, 1123], [2348, 1260]])
        print("Katixiya optimized combo restarts after a failed A and ignores unavailable S")
    }
}
