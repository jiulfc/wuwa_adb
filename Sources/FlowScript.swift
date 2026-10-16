import Foundation

struct FlowScript: Decodable {
    let version: Int
    let script_loop_count: Int?
    let run: [Entry]

    private enum CodingKeys: String, CodingKey { case version, script_loop_count, run, stop_when, label }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        _ = try values.decodeIfPresent(String.self, forKey: .label)
        guard !values.contains(.stop_when) else {
            throw replayError("stop_when 已移除，请使用 DSL run_until。")
        }
        version = try values.decode(Int.self, forKey: .version)
        script_loop_count = try values.decodeIfPresent(Int.self, forKey: .script_loop_count)
        run = try values.decode([Entry].self, forKey: .run)
    }

    struct Entry: Decodable {
        let name: String
        let id: String?

        private enum CodingKeys: String, CodingKey { case name, interval, steps, id, when, stop_when, label }
        init(from decoder: Decoder) throws {
            if let name = try? decoder.singleValueContainer().decode(String.self) {
                self.name = name
                id = nil
            } else {
                let values = try decoder.container(keyedBy: CodingKeys.self)
                _ = try values.decodeIfPresent(String.self, forKey: .label)
                name = try values.decode(String.self, forKey: .name)
                id = try values.decodeIfPresent(String.self, forKey: .id)
                guard !values.contains(.when) else {
                    throw replayError("run 不再支持 when；条目按顺序执行，请移除 when。")
                }
                guard !values.contains(.interval), !values.contains(.steps), !values.contains(.stop_when) else {
                    throw replayError("interval / steps / stop_when 已移除，请使用 DSL。")
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
    case workflow(LoadedWorkflow)

    struct LoadedEntry {
        let script: LoadedScript
        let name: String
        let id: String
    }

    static func load(from url: URL) throws -> LoadedScript {
        try load(from: url, ancestors: [])
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
            case "battle": throw replayError("battle 请使用 vars / steps DSL。")
            case "pickup": throw replayError("pickup 请使用 vars / steps DSL。")
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
                let childURL = URL(fileURLWithPath: entry.name, relativeTo: file.deletingLastPathComponent())
                let child = try load(from: childURL, ancestors: ancestors.union([file]))
                return LoadedEntry(script: child, name: childURL.lastPathComponent, id: id)
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
    var workflow: (LoadedWorkflow) throws -> Void = { _ in
        throw replayError("当前回放器未配置 version=3 DSL 支持。")
    }
    let progress: (Int, Int) -> Void
    let entryStarted: (LoadedScript.LoadedEntry) -> Void

    func run(_ script: LoadedScript) throws {
        try checkCancelled()
        switch script {
        case .recording(let script): try recording(script)
        case .workflow(let script): try workflow(script)
        case .flow(let loops, let entries):
            for loop in 0..<loops {
                try checkCancelled()
                progress(loop + 1, loops)
                for entry in entries {
                    try checkCancelled()
                    entryStarted(entry)
                    try run(entry.script)
                }
            }
        }
    }
}
