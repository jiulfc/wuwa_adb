import Foundation

func near(_ lhs: Double?, _ rhs: Double, _ message: String) {
    precondition(abs((lhs ?? -10) - rhs) < 0.000_001, message)
}

@main
struct GetEventRecorderTests {
    static func main() throws {
        let deviceListing = """
            add device 1: /dev/input/event1
              events:
                ABS (0003): ABS_MT_SLOT : value 0, min 0, max 9
                            ABS_MT_POSITION_X : value 0, min 0, max 500
                            ABS_MT_POSITION_Y : value 0, min 0, max 1000
            add device 2: /dev/input/event2
              events:
                ABS (0003): ABS_MT_SLOT : value 0, min 0, max 9
                            ABS_MT_POSITION_X : value 0, min 0, max 1000
                            ABS_MT_POSITION_Y : value 0, min 0, max 2000
              input props:
                INPUT_PROP_DIRECT
            """

        let device = try GetEventTouchDevice.parse(from: deviceListing)
        precondition(device.path == "/dev/input/event2")
        precondition(device.xMax == 1000 && device.yMax == 2000)
        let parsedRotation = try GetEventTouchParser.surfaceRotation(from: "SurfaceOrientation: 3")
        precondition(parsedRotation == 3)
        let viewportRotation = try GetEventTouchParser.surfaceRotation(
            from:
                "Viewport INTERNAL: displayId=0, orientation=1, logicalFrame=[0, 0, 3168, 1440]")
        precondition(viewportRotation == 1)

        let rotationChecks: [(Int, Double, Double)] = [
            (0, 0.1, 0.1), (1, 0.1, 0.9), (2, 0.9, 0.9), (3, 0.9, 0.1),
        ]
        for (rotation, x, y) in rotationChecks {
            let point = GetEventTouchParser(device: device, rotation: rotation).normalized(
                x: 100, y: 200)
            near(point.0, x, "rotation \(rotation) x")
            near(point.1, y, "rotation \(rotation) y")
        }

        let parser = GetEventTouchParser(device: device, rotation: 1)
        let lines = [
            "[ 10.000000] /dev/input/event2: EV_ABS ABS_MT_SLOT 00000000",
            "[ 10.000000] /dev/input/event2: EV_ABS ABS_MT_TRACKING_ID 0000002a",
            "[ 10.000000] /dev/input/event2: EV_ABS ABS_MT_POSITION_X 00000064",
            "[ 10.000000] /dev/input/event2: EV_ABS ABS_MT_POSITION_Y 000000c8",
            "[ 10.000000] /dev/input/event2: EV_SYN SYN_REPORT 00000000",
            "[ 10.100000] /dev/input/event2: EV_ABS ABS_MT_SLOT 00000001",
            "[ 10.100000] /dev/input/event2: EV_ABS ABS_MT_TRACKING_ID 0000002b",
            "[ 10.100000] /dev/input/event2: EV_ABS ABS_MT_POSITION_X 0000012c",
            "[ 10.100000] /dev/input/event2: EV_ABS ABS_MT_POSITION_Y 00000190",
            "[ 10.100000] /dev/input/event2: EV_SYN SYN_REPORT 00000000",
            "[ 10.200000] /dev/input/event2: EV_ABS ABS_MT_SLOT 00000000",
            "[ 10.200000] /dev/input/event2: EV_ABS ABS_MT_POSITION_X 00000078",
            "[ 10.200000] /dev/input/event2: EV_ABS ABS_MT_POSITION_Y 000000dc",
            "[ 10.200000] /dev/input/event2: EV_ABS ABS_MT_SLOT 00000001",
            "[ 10.200000] /dev/input/event2: EV_ABS ABS_MT_POSITION_X 00000140",
            "[ 10.200000] /dev/input/event2: EV_ABS ABS_MT_POSITION_Y 000001a4",
            "[ 10.200000] /dev/input/event2: EV_SYN SYN_REPORT 00000000",
            "[ 10.300000] /dev/input/event2: EV_ABS ABS_MT_SLOT 00000001",
            "[ 10.300000] /dev/input/event2: EV_ABS ABS_MT_TRACKING_ID ffffffff",
            "[ 10.300000] /dev/input/event2: EV_SYN SYN_REPORT 00000000",
        ]
        var events = lines.flatMap(parser.consume)
        events.append(contentsOf: parser.finish())

        precondition(events.map(\.action) == [0, 0, 2, 2, 1, 1])
        precondition(events.map(\.pointerId) == [42, 43, 42, 43, 43, 42])
        precondition(events.dropLast(2).allSatisfy { (0.45...0.75).contains($0.pressure ?? -1) })
        precondition(Set(events.dropLast(2).compactMap(\.pressure)).count > 1)
        precondition(events.suffix(2).allSatisfy { $0.pressure == 0 })
        near(events[0].relX, 0.1, "rotated first x")
        near(events[0].relY, 0.9, "rotated first y")
        near(events[1].relX, 0.2, "rotated second x")
        near(events[1].relY, 0.7, "rotated second y")
        near(events[1].t, 0.1, "relative time")

        let script = Script(deviceWidth: 2000, deviceHeight: 1000, events: events)
        let decoded = try Script.decode(from: script.encoded())
        precondition(decoded.events.map(\.pointerId) == events.map(\.pointerId))
        precondition(decoded.events.map(\.pressure) == events.map(\.pressure))

        let legacy = try Script.decode(from: Data(#"{"version":3,"deviceWidth":100,"deviceHeight":100,"events":[{"type":"touch","action":0,"relX":0.5,"relY":0.5,"t":0}]}"#.utf8))
        precondition(legacy.events[0].pressure == nil)
        for pressure in [-0.01, 1.01] {
            let invalid = "{\"version\":3,\"deviceWidth\":100,\"deviceHeight\":100,\"events\":[{\"type\":\"touch\",\"action\":0,\"relX\":0.5,\"relY\":0.5,\"pressure\":\(pressure),\"t\":0}]}"
            do { _ = try Script.decode(from: Data(invalid.utf8)); fatalError("Invalid pressure accepted") }
            catch { }
        }

        let incomplete = GetEventTouchParser(device: device, rotation: 0)
        _ = incomplete.consume("[ 11.000000] /dev/input/event2: EV_ABS ABS_MT_TRACKING_ID 0000002c")
        _ = incomplete.consume("[ 11.000000] /dev/input/event2: EV_ABS ABS_MT_POSITION_X 00000064")
        _ = incomplete.consume("[ 11.000000] /dev/input/event2: EV_ABS ABS_MT_POSITION_Y 000000c8")
        precondition(
            incomplete.finish().isEmpty, "An uncommitted down must not produce an orphan up")

        if CommandLine.arguments.count == 3 {
            let adb = AdbClient(adbPath: CommandLine.arguments[1])
            let serial = CommandLine.arguments[2]
            let liveListing = try adb.run(["-s", serial, "shell", "getevent", "-lp"])
            let liveDevice = try GetEventTouchDevice.parse(from: liveListing.stdout)
            let liveInput = try adb.run(["-s", serial, "shell", "dumpsys", "input"])
            let liveRotation = try GetEventTouchParser.surfaceRotation(from: liveInput.stdout)
            print("Live device: \(liveDevice.path), rotation \(liveRotation)")
        }

        print("GetEvent recorder checks passed")
    }
}
