import Foundation

@main
struct WorkflowParserCheck {
    static func main() throws {
        func parse(_ steps: String, vars: String = #"{"n":0,"text":"","match":null,"skill_state":null,"cooldown":null}"#) throws -> Workflow {
            try WorkflowParser().parse(Data("{\"version\":3,\"vars\":\(vars),\"steps\":\(steps)}".utf8))
        }
        func rejects(_ steps: String, containing message: String) {
            do { _ = try parse(steps); fatalError("Invalid steps accepted: \(steps)") }
            catch { precondition(String(describing: error).contains(message), "Unexpected error: \(error)") }
        }

        let workflow = try parse(#"""
        [
            {"type":"assign","target":"${n}","value":"${1 + 2 * 3}"},
            {"type":"if","condition":"${n == 7}","then":[{"type":"script","script_name":"child.json"}]},
            {"type":"template_match","roi":[0,0,20,20],"template":"button.png","threshold":0.8,"output":"${match}"},
            {"type":"if","condition":"${match.found}","then":[{"type":"tap","point":"${match.point}","duration_ms":1}]},
            {"type":"if","condition":"${false && match.missing}","then":[{"type":"script","script_name":"wrong.json"}]},
            {"type":"return"},
            {"type":"script","script_name":"also-wrong.json"}
        ]
        """#)

        var scripts: [String] = []
        var visionKinds: [VisionKind] = []
        var touches: [Bool] = []
        let runner = WorkflowRunner(checkCancelled: {}, script: { name, _ in scripts.append(name) },
            vision: { kind, _, parameters, _ in
                visionKinds.append(kind)
                precondition(parameters["template"] == .string("button.png"))
                return .object(["found": .bool(true), "point": .array([.number(10), .number(12)])])
            }, touch: { _, down in touches.append(down) })
        try runner.run(workflow)
        precondition(scripts == ["child.json"])
        precondition(visionKinds == [.templateMatch])
        precondition(touches == [true, false])

        let contains = try parse(#"""
        [
            {"type":"assign","target":"${text}","value":"status:  BATTLE   DONE now"},
            {"type":"if","condition":"${text contains 'battle done'}","then":[{"type":"script","script_name":"contains.json"}]},
            {"type":"if","condition":"${text contains 'missing'}","then":[{"type":"script","script_name":"wrong.json"}]}
        ]
        """#)
        try runner.run(contains)
        precondition(scripts == ["child.json", "contains.json"])

        let monitor = try parse(#"""
        [
            {"type":"monitor","interval_ms":5,"timeout_ms":500,
             "check":[
                {"type":"assign","target":"${n}","value":"${n + 1}"},
                {"type":"if","condition":"${n >= 2}","then":[{"type":"assign","target":"${match}","value":true}]}
             ],
             "until":"${match == true}",
             "steps":[{"type":"while","condition":true,"steps":[{"type":"wait","wait_ms":20}]}]}
        ]
        """#)
        try runner.run(monitor)
        let timeout = try parse(#"[{"type":"monitor","interval_ms":5,"timeout_ms":20,"check":[],"until":false,"steps":[{"type":"while","condition":true,"steps":[{"type":"wait","wait_ms":5}]}]}]"#)
        do { try runner.run(timeout); fatalError("monitor timeout was ignored") }
        catch { precondition(error.localizedDescription.contains("monitor 超时")) }

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
        rejects(#"[{"type":"monitor","interval_ms":500,"timeout_ms":1000,"check":[{"type":"ocr_text","roi":[0,0,10,10],"output":"${text}"}],"until":false,"steps":[{"type":"assign","target":"${text}","value":"x"}]}]"#, containing: "both write: text")
        rejects(#"[{"type":"wait","wait_ms":1,"typo":true}]"#, containing: "Unknown field")
        rejects(#"[{"type":"wait"}]"#, containing: "Missing required field")
        rejects(#"[{"type":"wait","wait_ms":true}]"#, containing: "Expected number")
        rejects(#"[{"type":"wait","wait_ms":-1}]"#, containing: "permitted range")
        rejects(#"[{"type":"wait","wait_ms":0.5}]"#, containing: "not an integer")
        rejects(#"[{"type":"tap","point":[1],"duration_ms":10}]"#, containing: "2 coordinates")
        rejects(#"[{"type":"ocr_text","roi":[0,0,0,10],"output":"${text}"}]"#, containing: "positive")
        rejects(#"[{"type":"template_match","roi":[0,0,10,10],"template":"t.png","threshold":1.1,"output":"${match}"}]"#, containing: "permitted range")
        rejects(#"[{"type":"skill_check","roi":[0,0,10,10],"model":"m.onnx","skill":"x","threshold":-0.1,"output":"${match}"}]"#, containing: "permitted range")
        rejects(#"[{"type":"script","script_name":""}]"#, containing: "nonempty")
        rejects(#"[{"type":"if","condition":"true","then":[]}]"#, containing: "Expected boolean")
        let expression = String(repeating: "!", count: 100) + "true"
        rejects("[{\"type\":\"if\",\"condition\":\"${\(expression)}\",\"then\":[]}]", containing: "nesting")

        for bad in [
            #"{"version":4,"vars":{},"steps":[]}"#,
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

        print("V3 DSL parsing, dispatch, expressions, control flow, monitor cancellation, vision callbacks, and replay passed")
    }
}
