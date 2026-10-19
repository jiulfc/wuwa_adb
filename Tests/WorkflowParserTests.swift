import Foundation

@main
struct WorkflowParserCheck {
    static func main() throws {
        func parse(_ steps: String, vars: String = #"{"n":0,"text":"","match":null,"skill_state":null,"cooldown":null,"skill_roi":[0,0,10,10]}"#) throws -> Workflow {
            try WorkflowParser().parse(Data("{\"version\":3,\"label\":\"test workflow\",\"vars\":\(vars),\"steps\":\(steps)}".utf8))
        }
        func rejects(_ steps: String, containing message: String) {
            do { _ = try parse(steps); fatalError("Invalid steps accepted: \(steps)") }
            catch { precondition(String(describing: error).contains(message), "Unexpected error: \(error)") }
        }

        let workflow = try parse(#"""
        [
            {"type":"assign","label":"compute counter","target":"${n}","value":"${1 + 2 * 3}"},
            {"type":"if","condition":"${n == 7}","then":[{"type":"script","script_name":"child.json"}]},
            {"type":"ocr_text","roi":[0,0,20,20],"output":"${text}"},
            {"type":"template_match","roi":[0,0,20,20],"template":"button.png","threshold":0.8,"output":"${match}"},
            {"type":"if","condition":"${match.found}","then":[{"type":"tap","point":"${match.point}","duration_ms":1}]},
            {"type":"drag","from":[1,2],"to":[3,4],"duration_ms":1},
            {"type":"if","condition":"${false && match.missing}","then":[{"type":"script","script_name":"wrong.json"}]},
            {"type":"return"},
            {"type":"script","script_name":"also-wrong.json"}
        ]
        """#)

        var scripts: [String] = []
        var visionKinds: [VisionKind] = []
        var touches: [WorkflowTouchAction] = []
        let logLock = NSLock()
        var logs: [String] = []
        let runner = WorkflowRunner(checkCancelled: {}, script: { name, _, _ in scripts.append(name) },
            vision: { kind, _, parameters, _ in
                visionKinds.append(kind)
                if kind == .ocrText { return .string("CONFIRM") }
                precondition(parameters["template"] == .string("button.png"))
                return .object(["found": .bool(true), "point": .array([.number(10), .number(12)])])
            }, touch: { _, action in touches.append(action) }, log: {
                logLock.lock()
                logs.append($0)
                logLock.unlock()
            })
        try runner.run(workflow)
        precondition(scripts == ["child.json"])
        precondition(visionKinds == [.ocrText, .templateMatch])
        precondition(touches == [.down, .up, .down, .move, .up])
        precondition(logs.contains("[Workflow] Step: type=ocr_text, output=text, text=\("CONFIRM".debugDescription)"))
        precondition(logs.contains("[Workflow] Condition: type=if, matched=true"))

        let circle = try parse(#"[{"type":"circle_percentage","roi":[1270,1270,72,72],"profile":"default","output":"${n}"}]"#)
        let circleRunner = WorkflowRunner(checkCancelled: {}, script: { _, _, _ in },
            vision: { kind, roi, parameters, _ in
                precondition(kind == .circlePercentage && roi == [1270, 1270, 72, 72])
                precondition(parameters["profile"] == .string("default"))
                return .number(0.4)
            }, touch: { _, _ in }, log: {
                logLock.lock()
                logs.append($0)
                logLock.unlock()
            })
        try circleRunner.run(circle)
        precondition(logs.contains("[Workflow] Step: type=circle_percentage, output=n, percentage=0.4"))

        let drag = try parse(#"[{"type":"drag","from":[1,2],"to":[3,4],"duration_ms":100}]"#)
        var cancellationChecks = 0
        var cancelledTouches: [WorkflowTouchAction] = []
        let cancelledDrag = WorkflowRunner(checkCancelled: {
            cancellationChecks += 1
            if cancellationChecks == 2 { throw replayError("cancelled") }
        }, script: { _, _, _ in }, vision: { _, _, _, _ in .null },
           touch: { _, action in cancelledTouches.append(action) }, log: { _ in })
        do { try cancelledDrag.run(drag); fatalError("Drag cancellation ignored") } catch { }
        precondition(cancelledTouches == [.down, .move, .up], "Cancelled drag must release touch")

        let typedOCR = try parse(#"""
        [
            {"type":"ocr_text","roi":"${roi}","output":"${whole:int}"},
            {"type":"ocr_text","roi":"${roi}","output":"${decimal:double}"},
            {"type":"if","condition":"${whole == 42 && decimal == 3.5}","then":[{"type":"script","script_name":"typed.json"}]}
        ]
        """#, vars: #"{"roi":[1,2,3,4],"whole":0,"decimal":0}"#)
        var recognized = [" 42\n", "3.5"]
        var typedROIs: [[Double]] = []
        var typedPassed = false
        let typedRunner = WorkflowRunner(checkCancelled: {}, script: { name, _, _ in typedPassed = name == "typed.json" },
            vision: { _, roi, _, _ in typedROIs.append(roi); return .string(recognized.removeFirst()) },
            touch: { _, _ in }, log: { _ in })
        try typedRunner.run(typedOCR)
        precondition(typedROIs == [[1, 2, 3, 4], [1, 2, 3, 4]] && typedPassed)
        let invalidNumber = try parse(#"[{"type":"ocr_text","roi":[0,0,1,1],"output":"${n:int}"}]"#)
        let invalidNumberRunner = WorkflowRunner(checkCancelled: {}, script: { _, _, _ in },
            vision: { _, _, _, _ in .string("not a number") }, touch: { _, _ in }, log: { _ in })
        do { try invalidNumberRunner.run(invalidNumber); fatalError("Nonnumeric OCR accepted") }
        catch { precondition(error.localizedDescription.contains("valid number")) }
        let fractionalIntRunner = WorkflowRunner(checkCancelled: {}, script: { _, _, _ in },
            vision: { _, _, _, _ in .string("1.5") }, touch: { _, _ in }, log: { _ in })
        do { try fractionalIntRunner.run(invalidNumber); fatalError("Fractional int OCR accepted") }
        catch { precondition(error.localizedDescription.contains("integer")) }

        let contains = try parse(#"""
        [
            {"type":"assign","target":"${text}","value":"status:  BATTLE   DONE now"},
            {"type":"if","condition":"${text contains 'battle done'}","then":[{"type":"script","script_name":"contains.json"}]},
            {"type":"if","condition":"${text contains 'missing'}","then":[{"type":"script","script_name":"wrong.json"}]}
        ]
        """#)
        try runner.run(contains)
        precondition(scripts == ["child.json", "contains.json"])

        let indexed = try parse(#"""
        [
            {"type":"while","condition":"${i < targets.count}","steps":[
                {"type":"ocr_text","roi":"${targets[i].roi}","output":"${text}"},
                {"type":"if","condition":"${text contains targets[i].expected}","then":[
                    {"type":"tap","point":["${targets[i].roi[0] + targets[i].roi[2] / 2}","${targets[i].roi[1] + targets[i].roi[3] / 2}"],"duration_ms":1}
                ]},
                {"type":"assign","target":"${i}","value":"${i + 1}"}
            ]}
        ]
        """#, vars: #"{"targets":[{"roi":[0,0,2,2],"expected":"first"},{"roi":[10,20,4,6],"expected":"reward"}],"i":0,"text":""}"#)
        var indexedTexts = ["other", "CLAIM REWARD now"]
        var indexedROIs: [[Double]] = []
        var indexedTouches: [([Double], WorkflowTouchAction)] = []
        let indexedRunner = WorkflowRunner(checkCancelled: {}, script: { _, _, _ in },
            vision: { _, roi, _, _ in indexedROIs.append(roi); return .string(indexedTexts.removeFirst()) },
            touch: { indexedTouches.append(($0, $1)) }, log: { _ in })
        try indexedRunner.run(indexed)
        precondition(indexedROIs == [[0, 0, 2, 2], [10, 20, 4, 6]])
        precondition(indexedTouches.count == 2 && indexedTouches.allSatisfy { $0.0 == [12, 23] })

        let runUntil = try parse(#"""
        [
            {"type":"run_until","check_every_ms":5,"timeout_ms":500,
             "check":[
                {"type":"assign","target":"${n}","value":"${n + 1}"},
                {"type":"if","condition":"${n >= 2}","then":[{"type":"assign","target":"${match}","value":true}]}
             ],
             "until":"${match == true}",
             "steps":[{"type":"while","condition":true,"steps":[{"type":"wait","wait_ms":20}]}]}
        ]
        """#)
        try runner.run(runUntil)
        let timeout = try parse(#"[{"type":"run_until","check_every_ms":5,"timeout_ms":20,"check":[],"until":false,"steps":[{"type":"while","condition":true,"steps":[{"type":"wait","wait_ms":5}]}]}]"#)
        do { try runner.run(timeout); fatalError("run_until timeout was ignored") }
        catch { precondition(error.localizedDescription.contains("run_until timed out")) }

        let runFor = try parse(#"[{"type":"run_for","duration_ms":20,"steps":[{"type":"tap","point":[1,2],"duration_ms":200}]}]"#)
        var runForTouches: [WorkflowTouchAction] = []
        let runForRunner = WorkflowRunner(checkCancelled: {}, script: { _, _, _ in },
            vision: { _, _, _, _ in .null }, touch: { _, action in runForTouches.append(action) }, log: { _ in })
        try runForRunner.run(runFor)
        precondition(runForTouches == [.down, .up])

        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let doc = try String(contentsOf: repo.appendingPathComponent("wuwa_mass/project.md"), encoding: .utf8)
        let regex = try NSRegularExpression(pattern: "```json\\n([\\s\\S]*?)\\n```")
        let matches = regex.matches(in: doc, range: NSRange(doc.startIndex..., in: doc))
        precondition(matches.count == 8)
        for match in matches {
            let block = String(doc[Range(match.range(at: 1), in: doc)!])
            if block.contains("\"version\"") {
                let example = try WorkflowParser().parse(Data(block.utf8))
                precondition(example.variables["max_loop_count"] == .number(10) && example.steps.count == 1)
            } else if block.hasPrefix("[") {
                _ = try parse("[{\"type\":\"while\",\"condition\":true,\"steps\":\(block)}]")
            } else { _ = try parse("[\(block)]") }
        }
        _ = try WorkflowParser().parse(Data(contentsOf: repo.appendingPathComponent("wuwa_adb/scripts/4c_xin_loop_team_kxq/main.json")))

        rejects(#"[{"type":"assign","target":"n","value":1}]"#, containing: "single variable reference")
        rejects(#"[{"type":"assign","target":"${n + 1}","value":1}]"#, containing: "single variable reference")
        rejects(#"[{"type":"assign","target":"${match.point}","value":1}]"#, containing: "single variable reference")
        rejects(#"[{"type":"assign","target":"${missing}","value":1}]"#, containing: "Undeclared")
        rejects(#"[{"type":"assign","target":"${n}","value":"${n = 2}"}]"#, containing: "Unsupported")
        rejects(#"[{"type":"assign","target":"${n}","value":"${n()}"}]"#, containing: "Unexpected token")
        rejects(#"[{"type":"assign","target":"${n}","value":"text ${n}"}]"#, containing: "entire string")
        rejects(#"[{"type":"assign","target":"${n}","value":"${}"}]"#, containing: "Expected a value")
        rejects(#"[{"type":"assign","target":"${n}","value":"${(n + 1}"}]"#, containing: "Expected ')'")
        rejects(#"[{"type":"assign","target":"${n}","value":"${'unterminated}"}]"#, containing: "Unterminated")
        rejects(#"[{"type":"if","condition":"${1 && true}","then":[]}]"#, containing: "Expected boolean")
        rejects(#"[{"type":"if","condition":"${1 + 2}","then":[]}]"#, containing: "Expected boolean")
        rejects(#"[{"type":"if","condition":"${1 contains '1'}","then":[]}]"#, containing: "Expected string")
        rejects(#"[{"type":"break"}]"#, containing: "enclosing loop")
        rejects(#"[{"type":"continue"}]"#, containing: "enclosing loop")
        rejects(#"[{"type":"run_until","check_every_ms":500,"timeout_ms":1000,"check":[{"type":"ocr_text","roi":[0,0,10,10],"output":"${text}"}],"until":false,"steps":[{"type":"assign","target":"${text}","value":"x"}]}]"#, containing: "both write: text")
        rejects(#"[{"type":"monitor","interval_ms":500,"timeout_ms":1000,"check":[],"until":false,"steps":[]}]"#, containing: "Unknown command")
        rejects(#"[{"type":"wait","wait_ms":1,"typo":true}]"#, containing: "Unknown field")
        rejects(#"[{"type":"wait","label":1,"wait_ms":1}]"#, containing: "Expected a string")
        rejects(#"[{"type":"wait"}]"#, containing: "Missing required field")
        rejects(#"[{"type":"wait","wait_ms":true}]"#, containing: "Expected number")
        rejects(#"[{"type":"wait","wait_ms":-1}]"#, containing: "permitted range")
        rejects(#"[{"type":"wait","wait_ms":0.5}]"#, containing: "not an integer")
        rejects(#"[{"type":"tap","point":[1],"duration_ms":10}]"#, containing: "2 coordinates")
        rejects(#"[{"type":"drag","from":[0,0],"to":[1],"duration_ms":10}]"#, containing: "2 coordinates")
        rejects(#"[{"type":"drag","from":[0,0],"to":[1,1],"duration_ms":0}]"#, containing: "permitted range")
        rejects(#"[{"type":"ocr_text","roi":[0,0,0,10],"output":"${text}"}]"#, containing: "positive")
        rejects(#"[{"type":"template_match","roi":[0,0,10,10],"template":"t.png","threshold":1.1,"output":"${match}"}]"#, containing: "permitted range")
        rejects(#"[{"type":"skill_check","roi":[0,0,10,10],"model":"m.onnx","skill":"x","threshold":-0.1,"output":"${match}"}]"#, containing: "permitted range")
        rejects(#"[{"type":"ocr_text","roi":[0,0,10,10],"output":"${text:bool}"}]"#, containing: "int or double")
        rejects(#"[{"type":"skill_check","roi":[0,0,10,10],"model":"m.onnx","skill":"x","threshold":0,"output":"${match:int}"}]"#, containing: "only supported by ocr_text")
        rejects(#"[{"type":"script","script_name":""}]"#, containing: "nonempty")
        rejects(#"[{"type":"if","condition":"true","then":[]}]"#, containing: "Expected boolean")
        let expression = String(repeating: "!", count: 100) + "true"
        rejects("[{\"type\":\"if\",\"condition\":\"${\(expression)}\",\"then\":[]}]", containing: "nesting")

        for bad in [
            #"{"version":4,"vars":{},"steps":[]}"#,
            #"{"version":3,"label":false,"vars":{},"steps":[]}"#,
            #"{"version":3,"vars":{},"steps":[{"type":"unknown"}]}"#,
            #"{"version":3,"vars":{"bad-name":0},"steps":[]}"#
        ] {
            do { _ = try WorkflowParser().parse(Data(bad.utf8)); fatalError("Invalid workflow accepted: \(bad)") }
            catch { }
        }

        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("workflow.json")
        try Data(#"{"version":3,"vars":{},"steps":[]}"#.utf8).write(to: file)
        guard case .workflow(let loaded) = try LoadedScript.load(from: file) else {
            fatalError("version=3 DSL was not selected")
        }
        precondition(loaded.file == file.standardizedFileURL.resolvingSymlinksInPath())

        print("V3 DSL parsing, dispatch, expressions, timed cancellation, vision callbacks, and replay passed")
    }
}
