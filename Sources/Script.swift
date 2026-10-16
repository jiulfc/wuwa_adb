import Foundation

/// 一条可回放的控制事件。
struct ScriptEvent: Codable {
    var type: String          // "touch" | "scroll" | "key"
    var label: String? = nil  // optional user comment
    var action: Int?          // touch: 0=down, 1=up, 2=move
    var relX: Double?         // 相对横坐标 0~1
    var relY: Double?         // 相对纵坐标 0~1
    var hScroll: Int16?
    var vScroll: Int16?
    var key: String?          // "home" | "back" | "rotate" | "power"
    var t: Double             // 相对录制开始的时间（秒）
}

extension ScriptEvent {
    static func touch(action: Int, relX: Double, relY: Double, t: Double) -> ScriptEvent {
        ScriptEvent(type: "touch", action: action, relX: relX, relY: relY,
                    hScroll: nil, vScroll: nil, key: nil, t: t)
    }
    static func scroll(relX: Double, relY: Double, hScroll: Int16, vScroll: Int16, t: Double) -> ScriptEvent {
        ScriptEvent(type: "scroll", action: nil, relX: relX, relY: relY,
                    hScroll: hScroll, vScroll: vScroll, key: nil, t: t)
    }
    static func key(_ key: String, t: Double) -> ScriptEvent {
        ScriptEvent(type: "key", action: nil, relX: nil, relY: nil,
                    hScroll: nil, vScroll: nil, key: key, t: t)
    }
}

/// 一个录制脚本。
struct Script: Codable {
    var version: Int = 3
    var label: String? = nil
    var deviceWidth: UInt32
    var deviceHeight: UInt32
    var events: [ScriptEvent]
    var repeatCount: Int? = nil

    var playbackRepeatCount: Int { max(1, repeatCount ?? 1) }

    func validate() throws {
        guard version == 3 else { throw replayError("录制脚本需要 version=3。") }
        guard events.allSatisfy({ $0.t.isFinite && $0.t >= 0 && $0.t < 1e9 }) else {
            throw replayError("事件时间无效。")
        }
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    static func decode(from data: Data) throws -> Script {
        let script = try JSONDecoder().decode(Script.self, from: data)
        try script.validate()
        return script
    }
}
