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
        for scenario in 0..<5 {
            var moves: [[Double]] = []
            var taps: [[Double]] = []
            var reads = 0
            try WorkflowRunner(checkCancelled: {}, script: { _, _, _ in fatalError("Unexpected child") },
                vision: { kind, roi, _, _ in
                    precondition(kind == .ocrText)
                    reads += 1
                    precondition(reads < 3000, "Pickup search must terminate")
                    precondition(taps.isEmpty, "Pickup must return after the first tap")
                    if scenario == 1 && roi[1] == 589 { return .string("点击吸收") }
                    if scenario == 2 && roi[1] == 715 { return .string("吸收") }
                    if scenario == 3 && moves.count == 3 && roi[1] == 589 { return .string("吸收") }
                    if scenario == 4 && moves.count == expected.count && roi[1] == 715 { return .string("吸收") }
                    return .string("")
                }, touch: { point, action in
                    precondition(taps.isEmpty || action == .up, "No movement or tap after pickup")
                    if action == .move { moves.append(point) }
                    if action == .down && point[0] == 2096.5 { taps.append(point) }
                }, log: { _ in }).run(workflow)
            let moveCount = [expected.count, 0, 0, 3, expected.count][scenario]
            precondition(moves == Array(expected.prefix(moveCount)))
            let expectedTaps: [[Double]] = [[], [612], [738], [612], [738]]
            precondition(taps.map { $0[1] } == expectedTaps[scenario])
        }
        for maxPhase in [0, 1] {
            var moves: [[Double]] = []
            var reads = 0
            try WorkflowRunner(checkCancelled: {}, script: { _, _, _ in fatalError("Unexpected child") },
                vision: { _, _, _, _ in
                    reads += 1
                    return .string("")
                }, touch: { point, action in
                    if action == .move { moves.append(point) }
                }, log: { _ in }).run(workflow.applying(props: ["max_phase": .number(Double(maxPhase))]))
            precondition(moves == Array(expected.prefix(maxPhase * 2)), "Stop at the configured phase")
            precondition(reads == (maxPhase * 2 + 1) * 2, "Check both regions at the endpoint")
        }
        let juluoCommon = URL(fileURLWithPath: "scripts/juluo/pickup.json").standardizedFileURL
        let quickOriginal = try WorkflowParser().parse(Data(contentsOf: juluoCommon))
        let quick = Workflow(version: quickOriginal.version, variables: quickOriginal.variables,
                             steps: quickOriginal.steps.map(fast))
        for scenario in 0..<5 {
            var moves: [[Double]] = []
            var taps: [[Double]] = []
            var scripts: [String] = []
            try WorkflowRunner(checkCancelled: {}, script: { name, _, _ in scripts.append(name) },
                vision: { kind, roi, _, _ in
                    precondition(kind == .ocrText)
                    if scenario == 0 && moves.isEmpty && roi[1] == 589 { return .string("吸收") }
                    if scenario == 1 && moves.isEmpty && roi[1] == 715 { return .string("吸收") }
                    if scenario == 2 && moves.count == 1 && roi[1] == 589 { return .string("吸收") }
                    if scenario == 3 && moves.count == 2 && roi[1] == 715 { return .string("吸收") }
                    return .string("")
                }, touch: { point, action in
                    if action == .move { moves.append(point) }
                    if action == .down && point[0] == 2096.5 { taps.append(point) }
                }, log: { _ in }).run(quick.applying(props: [
                    "pickup_prepare_script": .string("fixture/pickup_prepare.json")
                ]))
            precondition(moves == Array(repeating: [501, 880], count: [0, 0, 1, 2, 2][scenario]),
                         "Quick pickup moves at most one phase")
            let expectedTaps: [[Double]] = [[612], [738], [612], [738], []]
            precondition(taps.map { $0[1] } == expectedTaps[scenario])
            let expectedScripts = scenario == 4 ? ["fixture/pickup_prepare.json", "../common/pickup.json"] : []
            precondition(scripts == expectedScripts, "Prepare must immediately precede the original pickup")
        }
        let files = FileManager.default.enumerator(at: URL(fileURLWithPath: "scripts"), includingPropertiesForKeys: nil)!
        var wrappers = 0
        for case let path as URL in files where path.lastPathComponent == "pickup.json" &&
            path.standardizedFileURL != common && path.standardizedFileURL != juluoCommon {
            let wrapper = try WorkflowParser().parse(Data(contentsOf: path))
            guard wrapper.steps.count == 1, case .script = wrapper.steps[0] else { continue }
            if path.path.contains("/scripts/juluo/") {
                let location = path.deletingLastPathComponent().lastPathComponent
                precondition(wrapper.steps == [.script(name: .literal(.string("../pickup.json")), props: .object([
                    "pickup_prepare_script": .literal(.string("\(location)/pickup_prepare.json"))
                ]))])
                precondition(path.deletingLastPathComponent().appendingPathComponent("../pickup.json").standardizedFileURL == juluoCommon)
                precondition(FileManager.default.fileExists(atPath: juluoCommon.deletingLastPathComponent()
                    .appendingPathComponent("\(location)/pickup_prepare.json").path))
            } else {
                precondition(wrapper.steps == [.script(name: .literal(.string("../../common/pickup.json")))])
                precondition(path.deletingLastPathComponent().appendingPathComponent("../../common/pickup.json").standardizedFileURL == common)
            }
            wrappers += 1
        }
        precondition(wrappers == 12)
        precondition(juluoCommon.deletingLastPathComponent().appendingPathComponent("../common/pickup.json")
            .standardizedFileURL == common)
        for name in ["1_mengshu", "2_luoyuan", "3_wangmang", "4_fusheng", "5_xianzu"] {
            let main = try WorkflowParser().parse(Data(contentsOf: URL(fileURLWithPath: "scripts/juluo/\(name)/main.json")))
            let fastMain = Workflow(version: main.version, variables: main.variables, steps: main.steps.map(fast))
            var scripts: [String] = []
            try WorkflowRunner(checkCancelled: {}, script: { script, _, _ in scripts.append(script) },
                vision: { kind, roi, _, _ in
                    precondition(kind == .ocrText && roi == [222, 397, 319, 49])
                    return .string("已清")
                }, touch: { _, _ in fatalError("Pickup is extracted from main") }, log: { _ in }).run(fastMain)
            var expectedScripts = name == "1_mengshu" ? ["prepare.json"] : ["../../common/reset_team_kxq.json", "prepare.json"]
            expectedScripts += ["pickup.json", "finish.json"]
            precondition(scripts == expectedScripts, "Every Juluo main delegates pickup and always finishes")
        }
        print("Pickup spiral, return after tap in either region, endpoint, and all 12 wrappers passed")
        print("All five Juluo scripts: instant, one-phase, prepare-then-original fallback, and finish passed")
    }
}
