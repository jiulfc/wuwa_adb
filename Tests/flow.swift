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
        try write("before.json", #"{"version":3,"deviceWidth":100,"deviceHeight":100,"repeatCount":2,"events":[{"type":"key","key":"back","t":0}]}"#)
        try write("after.json", #"{"version":3,"deviceWidth":100,"deviceHeight":100,"events":[{"type":"key","key":"home","t":0}]}"#)
        try write("battle.json", #"{"version":3,"deviceWidth":100,"deviceHeight":100,"type":"battle","priority":["R"],"regions":{"R":[0,0,100,100]},"lock_enemy":{"button":"R","interval":2}}"#)
        try write("pickup.json", #"{"version":3,"deviceWidth":100,"deviceHeight":100,"type":"pickup","pickup_text":{"text":"吸收","regions":[[0,0,100,100]]},"movement":{"joystick":[0.5,0.5],"radius":[0.1,0.1],"steps":[{"direction":"up","seconds":0.3}]}}"#)
        try write("nested/flow.json", #"{"version":3,"script_loop_count":2,"run":["../before.json"]}"#)
        let json = #"{"version":3,"script_loop_count":2,"run":["nested/flow.json",{"name":"battle.json","interval":0.7,"steps":3,"stop_when":{"check_interval":0.2,"match":{"type":"text_any","text":["DONE","OK"],"text_regions":[[0,0,1,1]]}}},{"id":"pickup","name":"pickup.json"},"after.json"]}"#
        let flow = try load(json)
        for json in [
            #"{"version":3,"deviceWidth":100,"deviceHeight":100,"type":"battle","priority":["R"],"regions":{"R":[0,0,100,100]},"lock_enemy":{"button":"missing","interval":1}}"#,
            #"{"version":3,"deviceWidth":100,"deviceHeight":100,"type":"battle","priority":["R"],"regions":{"R":[0,0,100,100]},"lock_enemy":{"button":"R","interval":0}}"#
        ] {
            let battle = try JSONDecoder().decode(BattleScript.self, from: Data(json.utf8))
            do { try battle.validate(); fatalError("Invalid lock_enemy accepted: \(json)") } catch { }
        }
        var events: [String] = []
        var ids: [String] = []
        var scriptNames: [String] = []
        var cancelled = false
        var matched = true
        var failBattle = false
        let runner = FlowRunner(checkCancelled: {
            if cancelled { throw replayError("cancelled") }
        }, recording: { script in
            events.append("\(script.events[0].key!):\(script.playbackRepeatCount)")
        }, battle: { script, interval, steps, stop in
            precondition(script.priority == ["R"] && script.lock_enemy?.button == "R" && script.lock_enemy?.interval == 2 && interval == 0.7 && steps == 3)
            precondition(script.normalizedRegion(script.regions["R"]!) == [0, 0, 1, 1])
            precondition(stop?.match.text == ["DONE", "OK"] && stop?.check_interval == 0.2)
            events.append("battle")
            if failBattle { throw replayError("battle failed") }
            return matched
        }, pickup: { script in
            precondition(script.deviceWidth == 100 && script.deviceHeight == 100 &&
                         script.pickup_text.regions == [[0, 0, 100, 100]] && script.movement.steps[0].seconds == 0.3)
            precondition(script.pickup_text.normalizedRegion(script.pickup_text.regions[0],
                                                              deviceWidth: 100, deviceHeight: 100) == [0, 0, 1, 1])
            events.append("pickup")
        }, progress: { _, _ in }, entryStarted: {
            ids.append($0.id)
            scriptNames.append($0.name)
        })
        try runner.run(flow)
        let namesPerLoop = ["flow.json", "before.json", "before.json", "battle.json", "pickup.json", "after.json"]
        precondition(scriptNames == namesPerLoop + namesPerLoop, "Active filenames must follow nested execution order")
        let oneLoop = ["back:2", "back:2", "battle", "pickup", "home:1"]
        precondition(events == oneLoop + oneLoop, "Nested loop/order/repeat mismatch")
        events = []
        matched = false
        try runner.run(flow)
        precondition(events == oneLoop + oneLoop, "Pickup must also run after step exhaustion")
        events = []
        failBattle = true
        do { try runner.run(flow); fatalError("Battle error ignored") } catch { }
        precondition(events == ["back:2", "back:2", "battle"], "Actions continued after failure")
        cancelled = true
        events = []
        do { try runner.run(flow); fatalError("Cancellation ignored") } catch { }
        precondition(events.isEmpty)
        var calls = 0
        let cancelBetween = FlowRunner(checkCancelled: {
            if calls == 1 { throw replayError("cancelled between actions") }
        }, recording: { _ in calls += 1 }, battle: { _, _, _, _ in fatalError() },
        pickup: { _ in fatalError() }, progress: { _, _ in }, entryStarted: { ids.append($0.id) })
        let recordings = try load(#"{"version":3,"run":["before.json","after.json"]}"#)
        do { try cancelBetween.run(recordings); fatalError("Cancellation between entries ignored") } catch { }
        precondition(calls == 1)

        // Conditions belong only to their battle entry, including inside nested flows.
        try write("nested/battle.json", #"{"version":3,"run":["../battle.json"]}"#)
        let scoped = try load(json.replacingOccurrences(of: "nested/flow.json", with: "nested/battle.json"))
        var scopedConditions: [[String]?] = []
        let scopeRunner = FlowRunner(checkCancelled: {}, recording: { _ in },
            battle: { _, _, _, stop in scopedConditions.append(stop?.match.text); return true },
            pickup: { _ in }, progress: { _, _ in }, entryStarted: { _ in })
        try scopeRunner.run(scoped)
        precondition(scopedConditions == [nil, ["DONE", "OK"], nil, ["DONE", "OK"]])
        let reset = try load(#"{"version":3,"script_loop_count":2,"run":[{"id":"pickup","name":"pickup.json"},"battle.json"]}"#)
        var pickups = 0
        let resetRunner = FlowRunner(checkCancelled: {}, recording: { _ in },
            battle: { _, interval, steps, _ in precondition(interval == 0.5 && steps == 200); return true },
            pickup: { _ in pickups += 1 }, progress: { _, _ in }, entryStarted: { ids.append($0.id) })
        try resetRunner.run(reset)
        precondition(pickups == 2)
        let unconditional = try load(#"{"version":3,"run":["pickup.json"]}"#)
        try resetRunner.run(unconditional)
        precondition(pickups == 3)

        precondition(ids.contains("pickup") && ids.contains("step_1"))
        for bad in [
            #"{"version":3,"stop_when":{"match":{"type":"text_any","text":["DONE"],"text_regions":[[0,0,1,1]]}},"run":["battle.json"]}"#,
            #"{"version":3,"run":[{"name":"before.json","stop_when":{"match":{"type":"text_any","text":["DONE"],"text_regions":[[0,0,1,1]]}}}]}"#,
            #"{"version":3,"run":[{"name":"battle.json","stop_when":{"type":"text_any","text":["DONE"],"text_regions":[[0,0,1,1]]}}]}"#,
            #"{"version":3,"run":[{"name":"pickup.json","when":"battle_stopped"}]}"#,
            #"{"version":3,"run":[{"id":"","name":"before.json"}]}"#,
            #"{"version":3,"run":[{"id":"  ","name":"before.json"}]}"#,
            #"{"version":3,"run":[{"id":1,"name":"before.json"}]}"#,
            #"{"version":3,"run":[{"id":"same","name":"before.json"},{"id":"same","name":"after.json"}]}"#,
            #"{"version":3,"run":["before.json",{"id":"step_1","name":"after.json"}]}"#,
            #"{"type":"battle","deviceWidth":100,"deviceHeight":100,"priority":["R"],"regions":{"R":[0,0,100,100]}}"#,
            #"{"version":1,"deviceWidth":100,"deviceHeight":100,"events":[]}"#,
            #"{"version":2,"run":["before.json"]}"#,
            #"{"version":3,"run":[]}"#,
            #"{"version":3,"script_loop_count":0,"run":["before.json"]}"#,
            #"{"version":3,"script_loop_count":1.5,"run":["before.json"]}"#,
            #"{"version":3,"run":[""]}"#,
            #"{"version":3,"run":["missing.json"]}"#,
            #"{"version":3,"run":[{"name":"battle.json","steps":0}]}"#,
            #"{"version":3,"run":[{"name":"battle.json","steps":1.5}]}"#,
            #"{"version":3,"run":[{"name":"battle.json","interval":0}]}"#,
            #"{"version":3,"run":[{"name":"before.json","steps":3}]}"#,
            #"{"version":3,"run":[{"name":"pickup.json","when":"unknown"}]}"#,
            #"{"version":3,"run":[{"name":"battle.json","stop_when":{"check_interval":0.5,"match":{"type":"text_any","text":["DONE"],"text_regions":[]}}}]}"#,
            #"{"version":3,"run":[{"name":"battle.json","stop_when":{"check_interval":0.5,"match":{"type":"text_any","text":[""],"text_regions":[[0,0,1,1]]}}}]}"#,
            #"{"version":3,"run":[{"name":"battle.json","stop_when":{"check_interval":0.5,"match":{"type":"unknown","text":["DONE"],"text_regions":[[0,0,1,1]]}}}]}"#,
            #"{"version":3,"run":[{"name":"battle.json","stop_when":{"check_interval":-1,"match":{"type":"text_any","text":["DONE"],"text_regions":[[0,0,1,1]]}}}]}"#,
            #"{"version":3,"run":["main.json"]}"#
        ] {
            do { _ = try load(bad); fatalError("Invalid flow accepted: \(bad)") } catch { }
        }
        try write("a.json", #"{"version":3,"run":["b.json"]}"#)
        try write("b.json", #"{"version":3,"run":["a.json"]}"#)
        do { _ = try load(#"{"version":3,"run":["a.json"]}"#); fatalError("Indirect cycle accepted") } catch { }
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("alias.json"), withDestinationURL: root.appendingPathComponent("main.json"))
        do { _ = try load(#"{"version":3,"run":["alias.json"]}"#); fatalError("Symlink cycle accepted") } catch { }
        try write("bad.json", #"{"version":3,"deviceWidth":100,"deviceHeight":100,"type":"battle","priority":["R"],"regions":{"R":[0,0,0,100]}}"#)
        do { _ = try load(#"{"version":3,"run":["bad.json"]}"#); fatalError("Bad battle accepted") } catch { }
        try write("bad.json", #"{"version":3,"deviceWidth":100,"deviceHeight":100,"type":"pickup","pickup_text":{"text":"吸收","regions":[]},"movement":{"joystick":[],"radius":[],"steps":[]}}"#)
        do { _ = try load(#"{"version":3,"run":["bad.json"]}"#); fatalError("Bad pickup accepted") } catch { }
        let absolute = root.appendingPathComponent("before.json").path
        let absoluteJSON = try JSONSerialization.data(withJSONObject: ["version": 3, "run": [absolute]])
        _ = try load(String(decoding: absoluteJSON, as: UTF8.self))
        _ = try LoadedScript.load(from: root.appendingPathComponent("before.json"))
        do { _ = try LoadedScript.load(from: root.appendingPathComponent("battle.json")); fatalError("Bare battle root accepted") } catch { }
        let fixtures = URL(fileURLWithPath: "scripts/4c_xin_loop_team_kxq", isDirectory: true)
        guard case .workflow = try LoadedScript.load(from: fixtures.appendingPathComponent("main.json")),
              case .recording(let prepare) = try LoadedScript.load(from: fixtures.appendingPathComponent("prepare.json")),
              case .recording(let finish) = try LoadedScript.load(from: fixtures.appendingPathComponent("finish.json")) else {
            fatalError("Expected v3 workflow and recordings")
        }
        precondition(prepare.version == 3 && prepare.events.count == 121 && prepare.events.first?.t == 1.82292902469635)
        precondition(finish.version == 3 && finish.events.last?.t == 15)
        guard case .flow(_, let pickupEntries) = try LoadedScript.load(from: fixtures.appendingPathComponent("pickup_flow.json")),
              pickupEntries.count == 1, case .pickup(let pickup) = pickupEntries[0].script,
              case .flow(_, let battleEntries) = try LoadedScript.load(from: URL(fileURLWithPath: "scripts/common/combat_role_katixiya_flow.json")),
              battleEntries.count == 1, case .battle(let battle) = battleEntries[0].script,
              case .flow(_, let qianxiaoEntries) = try LoadedScript.load(from: URL(fileURLWithPath: "scripts/common/combat_role_qianxiao_flow.json")),
              qianxiaoEntries.count == 1, case .battle(let qianxiao) = qianxiaoEntries[0].script else {
            fatalError("Expected v3 pickup and battle wrappers")
        }
        precondition(battle.priority == ["E", "S", "A"] && battle.regions["L"] == [935, 1200, 40, 40] &&
                     qianxiao.priority == ["R", "E", "S", "A"] && qianxiao.regions["R"] == [2124, 1084, 120, 120] &&
                     pickup.pickup_text.regions == [[2041, 589, 111, 46], [2041, 715, 111, 46]])

        print("V3 load, recordings, configs, nested flows, defaults, cancellation, errors, cycles, and current fixtures passed")
    }
}
