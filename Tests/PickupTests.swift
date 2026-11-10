import Foundation

@main
struct PickupCheck {
    static func main() throws {
        let common = URL(fileURLWithPath: "scripts/common/pickup.json").standardizedFileURL
        let commonWorkflow = try WorkflowParser().parse(Data(contentsOf: common))
        precondition(commonWorkflow.steps == [.script(name: .literal(.string("pickup_spiral_scan.json")))])
        let circleURL = URL(fileURLWithPath: "scripts/common/pickup_circle.json").standardizedFileURL
        let circleOriginal = try WorkflowParser().parse(Data(contentsOf: circleURL))
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
        func verifyJoystickCenter(_ workflow: Workflow) {
            func dragStarts(_ steps: [Step]) -> [Input] {
                steps.flatMap { step in
                    switch step {
                    case .drag(let from, _, _): return [from]
                    case .whileLoop(_, let body): return dragStarts(body)
                    case .conditional(_, let yes, let no): return dragStarts(yes) + dragStarts(no)
                    default: return []
                    }
                }
            }
            precondition(workflow.variables["joystick_center"] == .array([.number(498), .number(1079)]))
            let starts = dragStarts(workflow.steps)
            precondition(!starts.isEmpty && starts.allSatisfy { $0 == .expression(.variable("joystick_center")) })
        }
        verifyJoystickCenter(circleOriginal)
        let workflow = Workflow(version: circleOriginal.version, variables: circleOriginal.variables,
                                steps: circleOriginal.steps.map(fast))
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
                    if action == .move {
                        precondition(taps.isEmpty, "No movement after pickup")
                        moves.append(point)
                    }
                    if action == .down && point[0] == 2096.5 { taps.append(point) }
                }, log: { _ in }).run(workflow)
            let moveCount = [expected.count, 0, 0, 3, expected.count][scenario]
            precondition(moves == Array(expected.prefix(moveCount)))
            let expectedTaps: [[Double]] = [[], [612, 612], [738, 738], [612, 612], [738, 738]]
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
        let crossURL = URL(fileURLWithPath: "scripts/common/pickup_cross.json").standardizedFileURL
        let crossOriginal = try WorkflowParser().parse(Data(contentsOf: crossURL))
        verifyJoystickCenter(crossOriginal)
        let cross = Workflow(version: crossOriginal.version, variables: crossOriginal.variables,
                             steps: crossOriginal.steps.map(fast))
        let crossDirections: [[Double]] = [[501, 880], [501, 1280], [301, 1080], [701, 1080]]
        let crossReturns: [[Double]] = [[501, 1280], [501, 880], [701, 1080], [301, 1080]]
        guard case .number(let maxStepsValue)? = crossOriginal.variables["max_steps"],
              case .number(let stepsPerCheckValue)? = crossOriginal.variables["steps_per_check"] else {
            fatalError("Missing cross pickup configuration")
        }
        let maxSteps = Int(maxStepsValue)
        let stepsPerCheck = Int(stepsPerCheckValue)
        precondition(maxSteps > 0 && stepsPerCheck > 0)
        let expectedCross = (0..<4).flatMap { arm in
            Array(repeating: crossDirections[arm], count: maxSteps) +
                Array(repeating: crossReturns[arm], count: maxSteps)
        }
        let pickupStep = min(maxSteps, stepsPerCheck * 2)
        for findsPickup in [false, true] {
            var moves: [[Double]] = []
            var taps: [[Double]] = []
            var reads = 0
            var scripts: [String] = []
            try WorkflowRunner(checkCancelled: {}, script: { name, _, _ in scripts.append(name) },
                vision: { kind, roi, _, _ in
                    precondition(kind == .ocrText)
                    reads += 1
                    if findsPickup && moves.count == pickupStep && roi[1] == 715 { return .string("吸收") }
                    return .string("")
                }, touch: { point, action in
                    if action == .move { moves.append(point) }
                    if action == .down && point[0] == 2096.5 { taps.append(point) }
                }, log: { _ in }).run(cross.applying(props: ["fallback_script": .string("pickup_circle.json")]))
            if findsPickup {
                precondition(moves == Array(repeating: crossDirections[0], count: pickupStep))
                precondition(taps.map { $0[1] } == [738, 738])
                precondition(reads == ((pickupStep + stepsPerCheck - 1) / stepsPerCheck) * 2)
                precondition(scripts.isEmpty, "Cross pickup must not start the circle after finding pickup")
            } else {
                precondition(moves == expectedCross, "Cross pickup must return to center after every arm")
                precondition(taps.isEmpty)
                let checksPerArm = (maxSteps + stepsPerCheck - 1) / stepsPerCheck
                precondition(reads == checksPerArm * 2 * crossDirections.count,
                             "Cross pickup must check both regions at the configured interval")
                precondition(scripts == ["pickup_circle.json"], "Circle pickup must run after the cross misses")
            }
        }
        let spiralURL = URL(fileURLWithPath: "scripts/common/pickup_spiral_scan.json").standardizedFileURL
        let spiralOriginal = try WorkflowParser().parse(Data(contentsOf: spiralURL))
        verifyJoystickCenter(spiralOriginal)
        let spiral = Workflow(version: spiralOriginal.version, variables: spiralOriginal.variables,
                              steps: spiralOriginal.steps.map(fast))
        guard case .number(let maxRadiusValue)? = spiralOriginal.variables["max_radius_steps"],
              case .number(let laneSpacingValue)? = spiralOriginal.variables["lane_spacing_steps"],
              case .number(let ocrPassesValue)? = spiralOriginal.variables["ocr_passes"] else {
            fatalError("Missing spiral pickup configuration")
        }
        let radiusChunks = Int(maxRadiusValue / laneSpacingValue)
        let totalSpiralMoves = 4 * radiusChunks * (radiusChunks + 1)
        precondition(maxRadiusValue == 16 && laneSpacingValue == 2 && ocrPassesValue == 2)
        var expectedSpiral: [[Double]] = []
        var spiralPhase = 0
        var spiralLeg = 1
        while expectedSpiral.count < totalSpiralMoves {
            expectedSpiral += Array(repeating: directions[spiralPhase % directions.count],
                                    count: min(spiralLeg, totalSpiralMoves - expectedSpiral.count))
            spiralPhase += 1
            if spiralPhase % 2 == 0 { spiralLeg += 1 }
        }
        let combinedROI = [2041.0, 589, 111, 172]
        let upperROI = [2041.0, 589, 111, 46]
        let lowerROI = [2041.0, 715, 111, 46]
        do {
            var moves: [[Double]] = []
            var combinedReads = 0
            try WorkflowRunner(checkCancelled: {}, script: { _, _, _ in fatalError("Unexpected child") },
                vision: { kind, roi, _, _ in
                    precondition(kind == .ocrText && roi == combinedROI)
                    combinedReads += 1
                    return .string("")
                }, touch: { point, action in
                    if action == .move { moves.append(point) }
                }, log: { _ in }).run(spiral)
            precondition(moves == expectedSpiral, "Spiral must cover every bounded search position")
            precondition(combinedReads == (totalSpiralMoves + 1) * 2,
                         "Spiral must check the center, every move endpoint, and retry OCR")
        }
        for pickupY in [612.0, 738.0] {
            var moves: [[Double]] = []
            var taps: [[Double]] = []
            var combinedReads = 0
            try WorkflowRunner(checkCancelled: {}, script: { _, _, _ in fatalError("Unexpected child") },
                vision: { kind, roi, _, _ in
                    precondition(kind == .ocrText && taps.isEmpty)
                    if roi == combinedROI {
                        combinedReads += 1
                        if pickupY == 612 || combinedReads == 2 { return .string("点击吸收") }
                        return .string("")
                    }
                    if roi == upperROI { return .string(pickupY == 612 ? "吸收" : "") }
                    if roi == lowerROI { return .string(pickupY == 738 ? "吸收" : "") }
                    fatalError("Unexpected pickup ROI")
                }, touch: { point, action in
                    if action == .move { moves.append(point) }
                    if action == .down && point[0] == 2096.5 { taps.append(point) }
                }, log: { _ in }).run(spiral)
            precondition(moves.isEmpty, "Pickup at the center must not move")
            precondition(combinedReads == (pickupY == 612 ? 1 : 2), "Combined OCR retry count")
            precondition(taps.map { $0[1] } == [pickupY, pickupY])
        }
        do {
            var moves: [[Double]] = []
            var taps: [[Double]] = []
            try WorkflowRunner(checkCancelled: {}, script: { _, _, _ in fatalError("Unexpected child") },
                vision: { kind, roi, _, _ in
                    precondition(kind == .ocrText && taps.isEmpty)
                    if roi == combinedROI { return .string("吸收") }
                    if moves.count == 1 && roi == upperROI { return .string("吸收") }
                    if roi == upperROI || roi == lowerROI { return .string("") }
                    fatalError("Unexpected pickup ROI")
                }, touch: { point, action in
                    if action == .move {
                        precondition(taps.isEmpty, "No movement after pickup")
                        moves.append(point)
                    }
                    if action == .down && point[0] == 2096.5 { taps.append(point) }
                }, log: { _ in }).run(spiral)
            precondition(moves == [directions[0]], "A combined-ROI false positive must not stop the search")
            precondition(taps.map { $0[1] } == [612, 612])
        }
        for invalid in [
            ("max_radius_steps", 0.0), ("lane_spacing_steps", 0), ("max_radius_steps", 15),
            ("step_duration_ms", 0), ("settle_ms", -1), ("initial_settle_ms", -1), ("ocr_passes", 0)
        ] {
            var variables = spiralOriginal.variables
            variables[invalid.0] = .number(invalid.1)
            let invalidSpiral = Workflow(version: spiralOriginal.version, variables: variables,
                                         steps: spiralOriginal.steps.map(fast))
            var logs: [String] = []
            try WorkflowRunner(checkCancelled: {}, script: { _, _, _ in fatalError("Unexpected child") },
                vision: { _, _, _, _ in fatalError("Invalid configuration must not scan") },
                touch: { _, _ in fatalError("Invalid configuration must not move") },
                log: { logs.append($0) }).run(invalidSpiral)
            precondition(logs.contains { $0.contains("Invalid pickup spiral configuration") })
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
            let expectedTaps: [[Double]] = [[612, 612], [738, 738], [612, 612], [738, 738], []]
            precondition(taps.map { $0[1] } == expectedTaps[scenario])
            let expectedScripts = scenario == 4 ? ["fixture/pickup_prepare.json", "../common/pickup.json"] : []
            precondition(scripts == expectedScripts,
                         "Prepare must immediately precede the original pickup in scenario \(scenario): \(scripts)")
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
        precondition(wrappers == 7)
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
            expectedScripts += ["pickup.json", "../../common/route_to_quan_xi_huan_tong/main.json"]
            precondition(scripts == expectedScripts, "Every Juluo main delegates pickup and returns through the shared route")
        }
        print("Pickup circle, cross, bounded spiral, OCR retry/localization, and all 7 wrappers passed")
        print("All five Juluo scripts: instant, one-phase, prepare-then-spiral fallback, and return route passed")
    }
}
