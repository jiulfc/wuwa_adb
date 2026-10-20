import Foundation

@main
struct PickupCheck {
    static func main() throws {
        let common = URL(fileURLWithPath: "scripts/common/pickup.json").standardizedFileURL
        let original = try WorkflowParser().parse(Data(contentsOf: common))
        // Keep the real control flow and movement accounting; skip device delays.
        func fast(_ step: Step) -> Step {
            switch step {
            case .whileLoop(let condition, let steps):
                return .whileLoop(condition: condition, steps: steps.map(fast))
            case .conditional(let condition, let yes, let no):
                return .conditional(condition: condition, then: yes.map(fast), otherwise: no.map(fast))
            case .drag(let from, let to, _): return .drag(from: from, to: to, duration: .literal(.number(1)))
            case .tap(let point, _): return .tap(point: point, duration: .literal(.number(1)))
            case .wait: return .wait(milliseconds: .literal(.number(0)))
            default: return step
            }
        }
        let workflow = Workflow(version: original.version, variables: original.variables, steps: original.steps.map(fast))
        let directions: [[Double]] = [[501, 880], [701, 1080], [501, 1280], [301, 1080]]
        let expected = (0..<20).flatMap { phase in
            Array(repeating: directions[phase % 4], count: (phase / 2 + 1) * 2)
        }
        for scenario in 0..<3 {
            var moves: [[Double]] = []
            var taps: [[Double]] = []
            var reads = 0
            try WorkflowRunner(checkCancelled: {}, script: { _, _, _ in fatalError("Unexpected child") },
                vision: { kind, roi, _, _ in
                    precondition(kind == .ocrText)
                    reads += 1
                    precondition(reads < 3000, "Pickup search must terminate")
                    if scenario == 2 { return .string("吸收") }
                    if scenario == 1 {
                        // Two drops at the start, one missed tap mid-leg, and a drop at the endpoint.
                        if taps.count == 0 && roi[1] == 589 { return .string("吸收") }
                        if taps.count == 1 && roi[1] == 715 { return .string("吸收") }
                        if moves.count == 3 && taps.count < 4 && roi[1] == 589 { return .string("吸收") }
                        if moves.count == expected.count && taps.count == 4 && roi[1] == 715 { return .string("吸收") }
                    }
                    return .string("")
                }, touch: { point, action in
                    if action == .move { moves.append(point) }
                    if action == .down && point[0] == 2096.5 { taps.append(point) }
                }, log: { _ in }).run(workflow)
            precondition(moves == expected, "Pickup must resume the same spiral segment")
            if scenario == 0 { precondition(taps.isEmpty) }
            if scenario == 1 { precondition(taps.map { $0[1] } == [612, 738, 612, 612, 738]) }
            if scenario == 2 { precondition(taps.count == (expected.count + 1) * 3, "Retries must be bounded") }
        }
        let files = FileManager.default.enumerator(at: URL(fileURLWithPath: "scripts"), includingPropertiesForKeys: nil)!
        var wrappers = 0
        for case let path as URL in files where path.lastPathComponent == "pickup.json" && path.standardizedFileURL != common {
            let wrapper = try WorkflowParser().parse(Data(contentsOf: path))
            precondition(wrapper.steps == [.script(name: .literal(.string("../../common/pickup.json")))])
            precondition(path.deletingLastPathComponent().appendingPathComponent("../../common/pickup.json").standardizedFileURL == common)
            wrappers += 1
        }
        precondition(wrappers == 12)
        print("Pickup spiral, resume, retries, endpoint, and all 12 wrappers passed")
    }
}
