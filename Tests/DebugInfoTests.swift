import AppKit

@main
struct DebugInfoCheck {
    static func main() throws {
        let workflow = try WorkflowParser().parse(Data(#"{"version":3,"vars":{"loop_count":0},"steps":[{"type":"while","condition":"${loop_count < 2}","steps":[{"type":"assign","target":"${loop_count}","value":"${loop_count + 1}"}]},{"type":"wait","wait_ms":0}]}"#.utf8))
        var snapshots: [(String, [String: JSONValue])] = []
        try WorkflowRunner(checkCancelled: {}, script: { _, _, _ in },
                           vision: { _, _, _, _ in .null }, touch: { _, _ in }, log: { _ in },
                           debug: { snapshots.append(($0, $1)) }).run(workflow)
        precondition(snapshots.first?.1["loop_count"] == .number(0))
        precondition(snapshots.contains { $0.0.contains("assign") && $0.1["loop_count"] == .number(1) })
        precondition(snapshots.last?.1["loop_count"] == .number(2))
        precondition(snapshots.last?.0 == "Step 2/2 in block · wait (finished)")
        precondition(JSONValue.object(["b": .bool(true), "a": .null]).debugText == "{a: null, b: true}")

        _ = NSApplication.shared
        let store = ControlInfoStore()
        precondition(store.updateWorkflowDebug(script: "parent.json", step: "start", variables: ["max_loop": .number(10)]))
        precondition(!store.updateWorkflowDebug(script: "parent.json", step: "finished", variables: ["max_loop": .number(10)]))
        precondition(store.updateWorkflowDebug(script: "parent.json", step: "assign", variables: ["max_loop": .number(20)]))
        store.setRunningScriptName("empty.json")
        precondition(store.updateWorkflowDebug(script: "empty.json", step: "start", variables: [:]))
        precondition(!store.updateWorkflowDebug(script: "empty.json", step: "finished", variables: [:]))
        precondition(store.currentStep == "finished" && store.variables.isEmpty)
        store.variables = ["loop_count": .number(9)]
        store.currentStep = "old step"
        store.setRunningScriptName("child.json")
        precondition(store.variables.isEmpty && store.currentStep == nil)
        let panel = ControlPanelWindowController(store: store)
        let debug = DebugWindowController(store: store)
        panel.show()
        debug.show()
        let panelWindow = NSApp.windows.first { $0.title == "Control Panel" }!
        precondition(panelWindow.contentView!.frame.width == 460)
        panelWindow.contentView!.layoutSubtreeIfNeeded()
        precondition(panelWindow.contentView!.fittingSize.width <= 460)
        let debugWindow = NSApp.windows.first { $0.title == "Debug" }!
        let scroll = debugWindow.contentView!.subviews.compactMap { $0 as? NSScrollView }.first!
        let text = scroll.documentView as! NSTextView
        precondition(!text.string.contains("loop_count:"))
        let wrapper = try WorkflowParser().parse(Data(contentsOf: URL(fileURLWithPath:
            "scripts/4c/qianran_loop_team_kxq/workflow_10.json")))
        store.setRunningScriptName("workflow_10.json")
        store.variables = wrapper.variables
        debug.show()
        precondition(text.string.contains("max_loop: 10"))
        let loop = try WorkflowParser().parse(Data(contentsOf: URL(fileURLWithPath:
            "scripts/4c/qianran_loop_team_kxq/loop.json")))
        store.setRunningScriptName("loop.json")
        store.variables = loop.variables
        debug.show()
        precondition(text.string.contains("loop_count: 0"))
        precondition(text.string.contains("battle_text: \n"))
        precondition(text.string.contains("confirm_text: \n"))
        precondition(text.string.contains("props.max_loop: 10"))
        precondition(JSONValue.object(["nested": .object(["value": .number(1.5)])])
            .debugLines(name: "props") == ["props.nested.value: 1.5"])
        precondition(JSONValue.object([:]).debugLines(name: "props") == ["props: {}"])
        store.setRunningScriptName("parent.json")
        store.variables = ["loop_count": .number(9), "props": .object(["max_loop": .number(50)])]
        debug.show()
        precondition(text.string.contains("current script: parent.json"))
        precondition(text.string.contains("loop_count: 9"))
        precondition(text.string.contains("props.max_loop: 50"))
        store.setRunningScriptName("combat.json")
        store.variables = ["skill": .number(1)]
        debug.show()
        precondition(text.string.contains("current script: combat.json"))
        precondition(text.string.contains("skill: 1"))
        precondition(!text.string.contains("max_loop") && !text.string.contains("loop_count"))
        store.setRunningScriptName("empty.json")
        debug.show()
        precondition(!text.string.contains("skill:"))
        store.setRunningScriptName(nil)
        precondition(store.variables.isEmpty)
        let pin = debugWindow.contentView!.subviews.compactMap { $0 as? NSButton }.first!
        pin.performClick(nil)
        precondition(debugWindow.level == .floating)
        pin.performClick(nil)
        precondition(debugWindow.level == .normal)
        print("Debug snapshots, current script variables, compact layout, and pin toggle passed")
    }
}
