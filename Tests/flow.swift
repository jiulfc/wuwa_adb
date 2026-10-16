import Foundation

@main
struct FlowCheck {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        func write(_ name: String, _ json: String) throws {
            let file = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(json.utf8).write(to: file)
        }
        func load(_ json: String) throws -> LoadedScript {
            try write("main.json", json)
            return try LoadedScript.load(from: root.appendingPathComponent("main.json"))
        }

        try write("before.json", #"{"version":3,"label":"prepare recording","deviceWidth":100,"deviceHeight":100,"repeatCount":2,"events":[{"type":"key","label":"leave screen","key":"back","t":0}]}"#)
        try write("combat.json", #"{"version":3,"deviceWidth":100,"deviceHeight":100,"events":[{"type":"key","key":"combat","t":0}]}"#)
        try write("after.json", #"{"version":3,"deviceWidth":100,"deviceHeight":100,"events":[{"type":"key","key":"home","t":0}]}"#)
        try write("nested/flow.json", #"{"version":3,"label":"nested flow","script_loop_count":2,"run":["../before.json"]}"#)

        let flow = try load(#"{"version":3,"label":"main flow","script_loop_count":2,"run":["nested/flow.json",{"id":"combat","name":"combat.json","label":"combat entry"},"after.json"]}"#)
        var events: [String] = []
        var ids: [String] = []
        var names: [String] = []
        var cancelled = false
        let runner = FlowRunner(checkCancelled: {
            if cancelled { throw replayError("cancelled") }
        }, recording: { script in
            if script.events[0].key == "back" {
                precondition(script.label == "prepare recording" && script.events[0].label == "leave screen")
            }
            events.append("\(script.events[0].key!):\(script.playbackRepeatCount)")
        }, progress: { _, _ in }, entryStarted: {
            ids.append($0.id)
            names.append($0.name)
        })
        try runner.run(flow)
        let namesPerLoop = ["flow.json", "before.json", "before.json", "combat.json", "after.json"]
        precondition(names == namesPerLoop + namesPerLoop)
        let eventsPerLoop = ["back:2", "back:2", "combat:1", "home:1"]
        precondition(events == eventsPerLoop + eventsPerLoop)
        precondition(ids.contains("combat") && ids.contains("step_1"))

        cancelled = true
        events = []
        do { try runner.run(flow); fatalError("Cancellation ignored") } catch { }
        precondition(events.isEmpty)

        var calls = 0
        let cancelBetween = FlowRunner(checkCancelled: {
            if calls == 1 { throw replayError("cancelled between actions") }
        }, recording: { _ in calls += 1 }, progress: { _, _ in }, entryStarted: { _ in })
        let recordings = try load(#"{"version":3,"run":["before.json","after.json"]}"#)
        do { try cancelBetween.run(recordings); fatalError("Cancellation between entries ignored") } catch { }
        precondition(calls == 1)

        for invalid in [
            #"{"version":3,"label":1,"run":["before.json"]}"#,
            #"{"version":3,"run":[{"name":"before.json","label":1}]}"#,
            #"{"version":3,"stop_when":{},"run":["before.json"]}"#,
            #"{"version":3,"run":[{"name":"before.json","interval":1}]}"#,
            #"{"version":3,"run":[{"name":"before.json","steps":1}]}"#,
            #"{"version":3,"run":[{"name":"before.json","stop_when":{}}]}"#,
            #"{"version":3,"run":[{"name":"before.json","when":"done"}]}"#,
            #"{"version":3,"run":[{"id":"","name":"before.json"}]}"#,
            #"{"version":3,"run":[{"id":"same","name":"before.json"},{"id":"same","name":"after.json"}]}"#,
            #"{"version":1,"events":[]}"#,
            #"{"version":2,"run":["before.json"]}"#,
            #"{"version":3,"run":[]}"#,
            #"{"version":3,"script_loop_count":0,"run":["before.json"]}"#,
            #"{"version":3,"run":[""]}"#,
            #"{"version":3,"run":["missing.json"]}"#,
            #"{"version":3,"run":["main.json"]}"#
        ] {
            do { _ = try load(invalid); fatalError("Invalid flow accepted: \(invalid)") } catch { }
        }
        do {
            _ = try Script.decode(from: Data(#"{"version":3,"label":1,"deviceWidth":100,"deviceHeight":100,"events":[]}"#.utf8))
            fatalError("Invalid recording label accepted")
        } catch { }

        try write("a.json", #"{"version":3,"run":["b.json"]}"#)
        try write("b.json", #"{"version":3,"run":["a.json"]}"#)
        do { _ = try load(#"{"version":3,"run":["a.json"]}"#); fatalError("Indirect cycle accepted") } catch { }
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("alias.json"),
                                                    withDestinationURL: root.appendingPathComponent("main.json"))
        do { _ = try load(#"{"version":3,"run":["alias.json"]}"#); fatalError("Symlink cycle accepted") } catch { }

        for type in ["battle", "pickup"] {
            try write("legacy.json", "{\"version\":3,\"type\":\"\(type)\"}")
            do { _ = try load(#"{"version":3,"run":["legacy.json"]}"#); fatalError("Legacy \(type) accepted") } catch { }
        }

        let absolute = root.appendingPathComponent("before.json").path
        let absoluteJSON = try JSONSerialization.data(withJSONObject: ["version": 3, "run": [absolute]])
        _ = try load(String(decoding: absoluteJSON, as: UTF8.self))

        let fixtures = URL(fileURLWithPath: "scripts", isDirectory: true)
        guard case .workflow = try LoadedScript.load(from: fixtures.appendingPathComponent("4c_xin_loop_team_kxq/main.json")),
              case .recording(let prepare) = try LoadedScript.load(from: fixtures.appendingPathComponent("4c_xin_loop_team_kxq/prepare.json")),
              case .workflow(let pickup) = try LoadedScript.load(from: fixtures.appendingPathComponent("4c_xin_loop_team_kxq/pickup.json")),
              case .workflow(let katixiya) = try LoadedScript.load(from: fixtures.appendingPathComponent("common/combat_role_katixiya.json")),
              case .workflow(let qianxiao) = try LoadedScript.load(from: fixtures.appendingPathComponent("common/combat_role_qianxiao.json")) else {
            fatalError("Expected current v3 workflows")
        }
        precondition(prepare.events.count == 121 && pickup.workflow.variables["phase"] == .number(0))
        precondition(katixiya.workflow.variables["e_roi"] == .array([.number(2276), .number(1188), .number(144), .number(144)]))
        precondition(qianxiao.workflow.variables["r_roi"] == .array([.number(2124), .number(1084), .number(120), .number(120)]))

        print("V3 recordings, DSL fixtures, nested flows, cancellation, errors, and cycles passed")
    }
}
