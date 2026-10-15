import Foundation

struct BattleScript: Decodable {
    let priority: [String]
    let regions: [String: [Double]]

    func validate() throws {
        guard !priority.isEmpty, Set(priority).count == priority.count,
              priority.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw replayError("battle 需要非空且不重复的 priority。")
        }
        for skill in priority {
            guard let region = regions[skill] else { throw replayError("缺少技能区域：\(skill)") }
            try TextStopCondition(text: skill, region: region).validate()
        }
    }

    func selectedSkill(labels: [String: String]) throws -> String? {
        guard priority.allSatisfy({ labels[$0] == "useable" || labels[$0] == "not_useable" }) else {
            throw replayError("分类器返回了缺失或未知的技能分类。")
        }
        return priority.first { labels[$0] == "useable" }
    }
}

struct FlowStopCondition: Decodable {
    let match: Match
    let check_interval: Double

    struct Match: Decodable {
        let type: String
        let text: [String]
        let text_regions: [[Double]]
    }

    private enum CodingKeys: String, CodingKey { case match, check_interval }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        match = try values.decode(Match.self, forKey: .match)
        check_interval = try values.decodeIfPresent(Double.self, forKey: .check_interval) ?? 0.5
    }

    func validate() throws {
        guard match.type == "text_any", !match.text_regions.isEmpty,
              check_interval.isFinite, check_interval > 0, check_interval < 1e9 else {
            throw replayError("stop_when 需要 match.type=text_any、非空 text_regions 和正数 check_interval。")
        }
        for region in match.text_regions { try TextStopCondition(text: match.text, region: region).validate() }
    }
}

struct PickupScript: Decodable {
    let pickup_text: PickupTextCondition
    let movement: PickupMovement

    func validate() throws {
        try pickup_text.validate()
        try movement.validate()
    }
}

struct FlowScript: Decodable {
    let version: Int
    let script_loop_count: Int?
    let run: [Entry]

    private enum CodingKeys: String, CodingKey { case version, script_loop_count, run, stop_when }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        guard !values.contains(.stop_when) else {
            throw replayError("请将 stop_when 移到 run 的 battle 条目内。")
        }
        version = try values.decode(Int.self, forKey: .version)
        script_loop_count = try values.decodeIfPresent(Int.self, forKey: .script_loop_count)
        run = try values.decode([Entry].self, forKey: .run)
    }

    struct Entry: Decodable {
        let name: String
        let interval: Double?
        let steps: Int?
        let id: String?
        let stop_when: FlowStopCondition?

        private enum CodingKeys: String, CodingKey { case name, interval, steps, id, when, stop_when }
        init(from decoder: Decoder) throws {
            if let name = try? decoder.singleValueContainer().decode(String.self) {
                self.name = name
                interval = nil
                steps = nil
                id = nil
                stop_when = nil
            } else {
                let values = try decoder.container(keyedBy: CodingKeys.self)
                name = try values.decode(String.self, forKey: .name)
                interval = try values.decodeIfPresent(Double.self, forKey: .interval)
                steps = try values.decodeIfPresent(Int.self, forKey: .steps)
                id = try values.decodeIfPresent(String.self, forKey: .id)
                stop_when = try values.decodeIfPresent(FlowStopCondition.self, forKey: .stop_when)
                guard !values.contains(.when) else {
                    throw replayError("run 不再支持 when；条目按顺序执行，请移除 when。")
                }
            }
        }
    }
}

struct LoadedWorkflow {
    let workflow: Workflow
    let file: URL
}

indirect enum LoadedScript {
    case recording(Script)
    case flow(loops: Int, entries: [LoadedEntry])
    case battle(BattleScript)
    case pickup(PickupScript)
    case workflow(LoadedWorkflow)

    struct LoadedEntry {
        let script: LoadedScript
        let name: String
        let interval: Double
        let steps: Int
        let id: String
        let stop: FlowStopCondition?
    }

    static func load(from url: URL) throws -> LoadedScript {
        let script = try load(from: url, ancestors: [])
        switch script {
        case .recording, .flow, .workflow: return script
        default: throw replayError("请选择 version=3 录制脚本或流程；battle/pickup 配置须通过流程引用。")
        }
    }

    private static func load(from url: URL, ancestors: Set<URL>) throws -> LoadedScript {
        let file = url.standardizedFileURL.resolvingSymlinksInPath()
        guard !ancestors.contains(file), ancestors.count < 64 else {
            throw replayError("脚本循环引用或嵌套超过 64 层：\(file.path)")
        }
        do {
            let data = try Data(contentsOf: file)
            struct Header: Decodable {
                let version: Int?
                let type: String?
                let vars: JSONValue?
                let steps: JSONValue?
                let events: JSONValue?
            }
            let header = try JSONDecoder().decode(Header.self, from: data)
            guard header.version == 3 else { throw replayError("仅支持 version=3。") }
            if header.vars != nil || header.steps != nil {
                return .workflow(LoadedWorkflow(workflow: try WorkflowParser().parse(data), file: file))
            }
            if header.events != nil {
                return .recording(try Script.decode(from: data))
            }
            switch header.type {
            case "battle":
                let battle = try JSONDecoder().decode(BattleScript.self, from: data)
                try battle.validate()
                return .battle(battle)
            case "pickup":
                let pickup = try JSONDecoder().decode(PickupScript.self, from: data)
                try pickup.validate()
                return .pickup(pickup)
            case .some(let type): throw replayError("未知 type：\(type)")
            case nil: break
            }
            let flow = try JSONDecoder().decode(FlowScript.self, from: data)
            guard (flow.script_loop_count ?? 1) > 0, !flow.run.isEmpty else {
                throw replayError("v3 需要正整数 script_loop_count 和非空 run。")
            }
            var ids = Set<String>()
            let entries = try flow.run.enumerated().map { index, entry -> LoadedEntry in
                let id = entry.id ?? "step_\(index + 1)"
                guard !entry.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      ids.insert(id).inserted else {
                    throw replayError("run 需要非空 name / id，且同一流程内 id 不能重复。")
                }
                try entry.stop_when?.validate()
                let childURL = URL(fileURLWithPath: entry.name, relativeTo: file.deletingLastPathComponent())
                let child = try load(from: childURL, ancestors: ancestors.union([file]))
                let interval = entry.interval ?? 0.5
                let steps = entry.steps ?? 200
                guard interval.isFinite, interval > 0, interval < 1e9, steps > 0 else {
                    throw replayError("run 的 interval 需要正数，steps 需要正整数。")
                }
                if case .battle = child { } else if entry.interval != nil || entry.steps != nil || entry.stop_when != nil {
                    throw replayError("interval / steps / stop_when 仅用于 battle：\(entry.name)")
                }
                return LoadedEntry(script: child, name: childURL.lastPathComponent, interval: interval, steps: steps,
                                   id: id, stop: entry.stop_when)
            }
            return .flow(loops: flow.script_loop_count ?? 1, entries: entries)
        } catch {
            throw replayError("\(file.lastPathComponent): \(error.localizedDescription)")
        }
    }
}

// Runs on the replay queue; device operations are supplied by the window controller.
struct FlowRunner {
    let checkCancelled: () throws -> Void
    let recording: (Script) throws -> Void
    let battle: (BattleScript, Double, Int, FlowStopCondition?) throws -> Bool
    let pickup: (PickupScript) throws -> Void
    var workflow: (LoadedWorkflow) throws -> Void = { _ in
        throw replayError("当前回放器未配置 version=3 DSL 支持。")
    }
    let progress: (Int, Int) -> Void
    let entryStarted: (LoadedScript.LoadedEntry) -> Void

    func run(_ script: LoadedScript, stop: FlowStopCondition? = nil,
             interval: Double = 0.5, steps: Int = 200) throws {
        try checkCancelled()
        switch script {
        case .recording(let script): try recording(script)
        case .battle(let script): _ = try battle(script, interval, steps, stop)
        case .pickup(let script): try pickup(script)
        case .workflow(let script): try workflow(script)
        case .flow(let loops, let entries):
            for loop in 0..<loops {
                try checkCancelled()
                progress(loop + 1, loops)
                for entry in entries {
                    try checkCancelled()
                    entryStarted(entry)
                    try run(entry.script, stop: entry.stop,
                            interval: entry.interval, steps: entry.steps)
                }
            }
        }
    }
}
