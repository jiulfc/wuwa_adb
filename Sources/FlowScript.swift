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
            throw replayError("stop_when has been removed; use the DSL run_until instead.")
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
                    throw replayError("run no longer supports when; entries run in order, so remove when.")
                }
                guard !values.contains(.interval), !values.contains(.steps), !values.contains(.stop_when) else {
                    throw replayError("interval / steps / stop_when have been removed; use the DSL instead.")
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

    static func load(from url: URL, props: [String: JSONValue]? = nil) throws -> LoadedScript {
        let loaded = try load(from: url, ancestors: [])
        guard let props else { return loaded }
        guard case .workflow(let child) = loaded else {
            throw replayError("props are only supported for vars/steps DSL scripts.")
        }
        return .workflow(LoadedWorkflow(workflow: try child.workflow.applying(props: props), file: child.file))
    }

    private static func load(from url: URL, ancestors: Set<URL>) throws -> LoadedScript {
        let file = url.standardizedFileURL.resolvingSymlinksInPath()
        guard !ancestors.contains(file), ancestors.count < 64 else {
            throw replayError("Script cycle or nesting deeper than 64 levels: \(file.path)")
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
            guard header.version == 3 else { throw replayError("Only version=3 is supported.") }
            if header.vars != nil || header.steps != nil {
                return .workflow(LoadedWorkflow(workflow: try WorkflowParser().parse(data), file: file))
            }
            if header.events != nil {
                return .recording(try Script.decode(from: data))
            }
            switch header.type {
            case "battle": throw replayError("battle scripts should use the vars / steps DSL.")
            case "pickup": throw replayError("pickup scripts should use the vars / steps DSL.")
            case .some(let type): throw replayError("Unknown type: \(type)")
            case nil: break
            }
            let flow = try JSONDecoder().decode(FlowScript.self, from: data)
            guard (flow.script_loop_count ?? 1) > 0, !flow.run.isEmpty else {
                throw replayError("v3 requires a positive script_loop_count and a non-empty run.")
            }
            var ids = Set<String>()
            let entries = try flow.run.enumerated().map { index, entry -> LoadedEntry in
                let id = entry.id ?? "step_\(index + 1)"
                guard !entry.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      ids.insert(id).inserted else {
                    throw replayError("run requires non-empty name / id, and ids must be unique within one flow.")
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
        throw replayError("The current player has no version=3 DSL support configured.")
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
