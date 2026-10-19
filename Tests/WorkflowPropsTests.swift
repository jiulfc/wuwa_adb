import Foundation

@main
struct WorkflowPropsCheck {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let child = root.appendingPathComponent("child.json")
        try Data(#"{"version":3,"vars":{"props":{"x":10,"y":20},"local":0},"steps":[{"type":"tap","point":["${props.x}","${props.y}"],"duration_ms":1},{"type":"assign","target":"${props}","value":{"x":999,"y":999}}]}"#.utf8).write(to: child)
        let parent = try WorkflowParser().parse(Data(#"{"version":3,"vars":{"x":42},"steps":[{"type":"script","script_name":"child.json","props":{"x":"${x + 1}"}},{"type":"script","script_name":"child.json"}]}"#.utf8))
        var points: [[Double]] = []
        var run: ((Workflow) throws -> Void)!
        run = { workflow in
            try WorkflowRunner(checkCancelled: {}, script: { name, props, check in
                try check()
                guard case .workflow(let loaded) = try LoadedScript.load(from: root.appendingPathComponent(name), props: props) else { fatalError() }
                try run(loaded.workflow)
            }, vision: { _, _, _, _ in .null }, touch: { point, action in
                if action == .down { points.append(point) }
            }, log: { _ in }).run(workflow)
        }
        try run(parent)
        precondition(points == [[43, 20], [10, 20]], "Overrides, retained defaults, and call isolation")
        func rejects(_ operation: () throws -> Void) {
            do { try operation(); fatalError("Invalid props accepted") } catch { }
        }
        rejects { _ = try LoadedScript.load(from: child, props: ["typo": .number(1)]) }
        rejects { _ = try parent.applying(props: [:]) }
        let recording = root.appendingPathComponent("recording.json")
        try Data(#"{"version":3,"deviceWidth":100,"deviceHeight":100,"events":[]}"#.utf8).write(to: recording)
        rejects { _ = try LoadedScript.load(from: recording, props: [:]) }
        let defaults = Workflow(version: 3, variables: ["props": .object([
            "nested": .object(["a": .number(1), "b": .number(2)]), "items": .array([])
        ])], steps: [])
        let overridden = try defaults.applying(props: ["nested": .null, "items": .array([.number(3)])])
        precondition(overridden.variables["props"] == .object(["nested": .null, "items": .array([.number(3)])]))
        rejects { _ = try WorkflowParser().parse(Data(#"{"version":3,"vars":{"props":1},"steps":[]}"#.utf8)) }
        rejects { _ = try WorkflowParser().parse(Data(#"{"version":3,"vars":{},"steps":[{"type":"script","script_name":"child.json","props":[] }]}"#.utf8)) }
        let dynamic = try WorkflowParser().parse(Data(#"{"version":3,"vars":{"bad":1},"steps":[{"type":"script","script_name":"child.json","props":"${bad}"}]}"#.utf8))
        rejects { try run(dynamic) }
        let doc = try String(contentsOfFile: "scripts/json_dsl_schema.md", encoding: .utf8)
        let regex = try NSRegularExpression(pattern: "```json\n([\\s\\S]*?)\n```")
        let blocks = regex.matches(in: doc, range: NSRange(doc.startIndex..., in: doc))
        precondition(blocks.count == 1)
        for block in blocks {
            let json = String(doc[Range(block.range(at: 1), in: doc)!])
            _ = try WorkflowParser().parse(Data(json.utf8))
        }
        print("Props defaults, overrides, isolation, validation, and documentation examples passed")
    }
}
