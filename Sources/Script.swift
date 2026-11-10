import Foundation

/// One replayable control event.
struct ScriptEvent: Codable {
    var type: String          // "touch" | "scroll" | "key"
    var label: String? = nil  // optional user comment
    var action: Int?          // touch: 0=down, 1=up, 2=move
    var relX: Double?         // relative x, 0~1
    var relY: Double?         // relative y, 0~1
    var pressure: Double?     // touch pressure, 0~1; nil keeps old recordings compatible
    var hScroll: Int16?
    var vScroll: Int16?
    var key: String?          // "home" | "back" | "rotate" | "power"
    var t: Double             // seconds since recording start
    var pointerId: Int64? = nil // touch pointer; nil keeps legacy mouse behavior
}

extension ScriptEvent {
    static func touch(action: Int, relX: Double, relY: Double, t: Double,
                      pressure: Double? = nil, pointerId: Int64? = nil) -> ScriptEvent {
        ScriptEvent(type: "touch", action: action, relX: relX, relY: relY,
                    pressure: pressure ?? TouchPressure.simulated(action: action),
                    hScroll: nil, vScroll: nil, key: nil, t: t, pointerId: pointerId)
    }
    static func scroll(relX: Double, relY: Double, hScroll: Int16, vScroll: Int16, t: Double) -> ScriptEvent {
        ScriptEvent(type: "scroll", action: nil, relX: relX, relY: relY,
                    pressure: nil, hScroll: hScroll, vScroll: vScroll, key: nil, t: t, pointerId: nil)
    }
    static func key(_ key: String, t: Double) -> ScriptEvent {
        ScriptEvent(type: "key", action: nil, relX: nil, relY: nil,
                    pressure: nil, hScroll: nil, vScroll: nil, key: key, t: t, pointerId: nil)
    }
}

enum TouchPressure {
    static func simulated(action: Int) -> Double {
        action == 1 ? 0 : Double.random(in: 0.45...0.75)
    }
}

/// One recorded script.
struct Script: Codable {
    var version: Int = 3
    var label: String? = nil
    var deviceWidth: UInt32
    var deviceHeight: UInt32
    var events: [ScriptEvent]
    var repeatCount: Int? = nil

    var playbackRepeatCount: Int { max(1, repeatCount ?? 1) }

    func validate() throws {
        guard version == 3 else { throw replayError("Recorded scripts require version=3.") }
        guard events.allSatisfy({ $0.t.isFinite && $0.t >= 0 && $0.t < 1e9 }) else {
            throw replayError("Invalid event time.")
        }
        guard events.allSatisfy({ ($0.pointerId ?? -1) >= -1 }) else {
            throw replayError("Invalid touch pointer ID.")
        }
        guard events.allSatisfy({ event in
            guard let pressure = event.pressure else { return true }
            return event.type == "touch" && pressure.isFinite && (0...1).contains(pressure)
                && (event.action != 1 || pressure == 0)
        }) else {
            throw replayError("Invalid touch pressure.")
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
