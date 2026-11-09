import Foundation

struct InputRecordingTarget {
    let serial: String
    let name: String
    let width: UInt32
    let height: UInt32
}

struct GetEventTouchDevice: Equatable {
    let path: String
    let xMin: Int
    let xMax: Int
    let yMin: Int
    let yMax: Int

    static func parse(from output: String) throws -> GetEventTouchDevice {
        struct Candidate {
            var path = ""
            var xRange: (Int, Int)?
            var yRange: (Int, Int)?
            var hasSlots = false
            var isDirect = false
        }

        var candidates: [Candidate] = []
        var current: Candidate?

        func finish(_ candidate: Candidate?) {
            if let candidate, !candidate.path.isEmpty { candidates.append(candidate) }
        }

        for rawLine in output.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("add device "), let range = line.range(of: ": /dev/input/") {
                finish(current)
                current = Candidate(path: String(line[range.lowerBound...].dropFirst(2)))
            } else if line.contains("ABS_MT_POSITION_X") {
                current?.xRange = axisRange(from: line)
            } else if line.contains("ABS_MT_POSITION_Y") {
                current?.yRange = axisRange(from: line)
            } else if line.contains("ABS_MT_SLOT") {
                current?.hasSlots = true
            } else if line.contains("INPUT_PROP_DIRECT") {
                current?.isDirect = true
            }
        }
        finish(current)

        // shortcut: protocol-B touch slots only; add protocol-A framing if a target lacks ABS_MT_SLOT.
        let usable = candidates.filter {
            $0.hasSlots && $0.xRange != nil && $0.yRange != nil
        }
        guard let selected = usable.first(where: { $0.isDirect }) ?? usable.first,
            let xRange = selected.xRange, let yRange = selected.yRange,
            xRange.1 > xRange.0, yRange.1 > yRange.0
        else {
            throw GetEventRecorderError.noTouchscreen
        }
        return GetEventTouchDevice(
            path: selected.path,
            xMin: xRange.0, xMax: xRange.1,
            yMin: yRange.0, yMax: yRange.1)
    }

    private static func axisRange(from line: String) -> (Int, Int)? {
        guard let min = integer(after: "min ", in: line),
            let max = integer(after: "max ", in: line)
        else { return nil }
        return (min, max)
    }

    private static func integer(after marker: String, in text: String) -> Int? {
        guard let range = text.range(of: marker) else { return nil }
        let tail = text[range.upperBound...].drop(while: { $0.isWhitespace })
        let value = tail.prefix(while: { $0 == "-" || $0.isNumber })
        return Int(value)
    }
}

final class GetEventTouchParser {
    private struct Slot {
        var trackingId: Int64?
        var x: Int?
        var y: Int?
        var pendingDown = false
        var pendingUp = false
        var moved = false
    }

    let device: GetEventTouchDevice
    let rotation: Int
    private var slots: [Int: Slot] = [:]
    private var currentSlot = 0
    private var firstTimestamp: Double?
    private var lastTimestamp = 0.0

    init(device: GetEventTouchDevice, rotation: Int) {
        self.device = device
        self.rotation = rotation
    }

    static func surfaceRotation(from output: String) throws -> Int {
        for line in output.components(separatedBy: .newlines) {
            if line.contains("SurfaceOrientation:"),
                let value = decimalInteger(after: "SurfaceOrientation:", in: line)
            {
                return value & 3
            }
            if line.contains("mCurrentOrientation="),
                let value = decimalInteger(after: "mCurrentOrientation=", in: line)
            {
                return value & 3
            }
            if line.contains("Viewport INTERNAL:"),
                let value = decimalInteger(after: "orientation=", in: line)
            {
                return value & 3
            }
        }
        throw GetEventRecorderError.unknownOrientation
    }

    func consume(_ line: String) -> [ScriptEvent] {
        guard let timestamp = Self.timestamp(from: line) else { return [] }
        lastTimestamp = timestamp

        if line.contains("ABS_MT_SLOT"), let value = Self.hexValue(from: line) {
            currentSlot = Int(value)
        } else if line.contains("ABS_MT_TRACKING_ID"), let value = Self.hexValue(from: line) {
            var slot = slots[currentSlot] ?? Slot()
            if value == -1 {
                slot.pendingUp = slot.trackingId != nil
            } else {
                slot = Slot(trackingId: value, pendingDown: true)
            }
            slots[currentSlot] = slot
        } else if line.contains("ABS_MT_POSITION_X"), let value = Self.hexValue(from: line) {
            var slot = slots[currentSlot] ?? Slot()
            slot.x = Int(value)
            slot.moved = true
            slots[currentSlot] = slot
        } else if line.contains("ABS_MT_POSITION_Y"), let value = Self.hexValue(from: line) {
            var slot = slots[currentSlot] ?? Slot()
            slot.y = Int(value)
            slot.moved = true
            slots[currentSlot] = slot
        } else if line.contains("SYN_REPORT") {
            return flush(at: timestamp)
        }
        return []
    }

    func finish() -> [ScriptEvent] {
        var events: [ScriptEvent] = []
        for index in slots.keys.sorted() {
            guard let slot = slots[index], let pointerId = slot.trackingId,
                !slot.pendingDown, let x = slot.x, let y = slot.y
            else { continue }
            events.append(
                event(
                    action: 1, pointerId: pointerId, x: x, y: y,
                    timestamp: lastTimestamp))
        }
        slots.removeAll()
        return events
    }

    func normalized(x: Int, y: Int) -> (Double, Double) {
        let rawX = min(1, max(0, Double(x - device.xMin) / Double(device.xMax - device.xMin)))
        let rawY = min(1, max(0, Double(y - device.yMin) / Double(device.yMax - device.yMin)))
        switch rotation & 3 {
        case 1: return (rawY, 1 - rawX)
        case 2: return (1 - rawX, 1 - rawY)
        case 3: return (1 - rawY, rawX)
        default: return (rawX, rawY)
        }
    }

    private func flush(at timestamp: Double) -> [ScriptEvent] {
        var events: [ScriptEvent] = []
        for index in slots.keys.sorted() {
            guard var slot = slots[index], let pointerId = slot.trackingId,
                let x = slot.x, let y = slot.y
            else { continue }
            if slot.pendingUp {
                events.append(
                    event(
                        action: 1, pointerId: pointerId, x: x, y: y,
                        timestamp: timestamp))
                slots[index] = Slot()
            } else if slot.pendingDown {
                events.append(
                    event(
                        action: 0, pointerId: pointerId, x: x, y: y,
                        timestamp: timestamp))
                slot.pendingDown = false
                slot.moved = false
                slots[index] = slot
            } else if slot.moved {
                events.append(
                    event(
                        action: 2, pointerId: pointerId, x: x, y: y,
                        timestamp: timestamp))
                slot.moved = false
                slots[index] = slot
            }
        }
        return events
    }

    private func event(
        action: Int, pointerId: Int64, x: Int, y: Int,
        timestamp: Double
    ) -> ScriptEvent {
        if firstTimestamp == nil { firstTimestamp = timestamp }
        let point = normalized(x: x, y: y)
        return .touch(
            action: action, relX: point.0, relY: point.1,
            t: max(0, timestamp - (firstTimestamp ?? timestamp)), pointerId: pointerId)
    }

    private static func timestamp(from line: String) -> Double? {
        guard let open = line.firstIndex(of: "["),
            let close = line[open...].firstIndex(of: "]")
        else { return nil }
        return Double(line[line.index(after: open)..<close].trimmingCharacters(in: .whitespaces))
    }

    private static func hexValue(from line: String) -> Int64? {
        guard let token = line.split(whereSeparator: { $0.isWhitespace }).last else { return nil }
        let text = token.hasPrefix("0x") ? String(token.dropFirst(2)) : String(token)
        guard let value = UInt32(text, radix: 16) else { return nil }
        return value == UInt32.max ? -1 : Int64(value)
    }

    private static func decimalInteger(after marker: String, in text: String) -> Int? {
        guard let range = text.range(of: marker) else { return nil }
        let tail = text[range.upperBound...].drop(while: { $0.isWhitespace })
        return Int(tail.prefix(while: { $0.isNumber }))
    }
}

enum GetEventRecorderError: LocalizedError {
    case commandFailed(String)
    case noTouchscreen
    case unknownOrientation

    var errorDescription: String? {
        switch self {
        case .commandFailed(let message): return message.isEmpty ? "adb getevent failed." : message
        case .noTouchscreen: return "No direct multi-touch input device was found."
        case .unknownOrientation: return "Could not read the device display orientation."
        }
    }
}

final class ADBInputRecorder {
    private let adbPath: String
    private let target: InputRecordingTarget
    private let queue = DispatchQueue(label: "adbquick.getevent-recorder")
    private let lock = NSLock()
    private var process: Process?
    private var stopRequested = false

    init(adbPath: String, target: InputRecordingTarget) {
        self.adbPath = adbPath
        self.target = target
    }

    func start(
        onStarted: @escaping (GetEventTouchDevice, Int) -> Void,
        onEventCount: @escaping (Int) -> Void,
        completion: @escaping (Result<Script, Error>) -> Void
    ) {
        queue.async { [self] in
            do {
                let adb = AdbClient(adbPath: adbPath)
                let devices = try adb.run(["-s", target.serial, "shell", "getevent", "-lp"])
                guard devices.exitCode == 0 else {
                    throw GetEventRecorderError.commandFailed(devices.stderr)
                }
                let touchDevice = try GetEventTouchDevice.parse(from: devices.stdout)

                let inputDump = try adb.run(["-s", target.serial, "shell", "dumpsys", "input"])
                guard inputDump.exitCode == 0 else {
                    throw GetEventRecorderError.commandFailed(inputDump.stderr)
                }
                let rotation = try GetEventTouchParser.surfaceRotation(from: inputDump.stdout)
                let parser = GetEventTouchParser(device: touchDevice, rotation: rotation)

                lock.lock()
                let shouldStop = stopRequested
                lock.unlock()
                guard !shouldStop else {
                    completion(
                        .success(
                            Script(
                                deviceWidth: target.width, deviceHeight: target.height, events: []))
                    )
                    return
                }

                let process = Process()
                let output = Pipe()
                process.executableURL = URL(fileURLWithPath: adbPath)
                process.arguments = [
                    "-s", target.serial, "shell", "getevent", "-lt", touchDevice.path,
                ]
                process.standardInput = FileHandle.nullDevice
                process.standardOutput = output
                process.standardError = output
                try process.run()

                lock.lock()
                self.process = process
                let stoppedDuringLaunch = stopRequested
                lock.unlock()
                if stoppedDuringLaunch {
                    process.terminate()
                } else {
                    onStarted(touchDevice, rotation)
                }

                var events: [ScriptEvent] = []
                var buffer = Data()
                while true {
                    let data = output.fileHandleForReading.availableData
                    if data.isEmpty { break }
                    buffer.append(data)
                    while let newline = buffer.firstIndex(of: 0x0a) {
                        let line = String(decoding: buffer[..<newline], as: UTF8.self)
                        buffer.removeSubrange(...newline)
                        let newEvents = parser.consume(line)
                        if !newEvents.isEmpty {
                            events.append(contentsOf: newEvents)
                            onEventCount(events.count)
                        }
                    }
                }
                process.waitUntilExit()
                if !buffer.isEmpty {
                    events.append(
                        contentsOf: parser.consume(String(decoding: buffer, as: UTF8.self)))
                }
                events.append(contentsOf: parser.finish())

                lock.lock()
                let wasStopped = stopRequested
                self.process = nil
                lock.unlock()
                guard wasStopped || process.terminationStatus == 0 else {
                    throw GetEventRecorderError.commandFailed(
                        "adb getevent exited with status \(process.terminationStatus).")
                }
                completion(
                    .success(
                        Script(
                            deviceWidth: target.width, deviceHeight: target.height,
                            events: events)))
            } catch {
                completion(.failure(error))
            }
        }
    }

    func stop() {
        lock.lock()
        stopRequested = true
        let process = self.process
        lock.unlock()
        if process?.isRunning == true { process?.terminate() }
    }

    deinit { stop() }
}
