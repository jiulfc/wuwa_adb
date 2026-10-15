import Foundation
import AVFoundation
import AppKit

@main
struct Check {
    static func main() throws {
        setbuf(stdout, nil)
        let regions = Dictionary(uniqueKeysWithValues: ["R", "E", "A", "D"].map { ($0, [0.25, 0.25, 0.5, 0.5]) })
        let program = BattleScript(
                                        priority: ["R", "E", "A", "D"], regions: regions)
        try program.validate()
        for mask in 0..<16 {
            let labels = Dictionary(uniqueKeysWithValues: program.priority.enumerated().map {
                ($0.element, mask & (1 << $0.offset) == 0 ? "not_useable" : "useable")
            })
            let expected = program.priority.enumerated().first { mask & (1 << $0.offset) != 0 }?.element
            let selected = try program.selectedSkill(labels: labels)
            precondition(selected == expected)
        }
        do { _ = try program.selectedSkill(labels: ["R": "useable"]); fatalError("Missing labels accepted") }
        catch { }
        for invalid in [[0.0, 0, 0, 0], [-0.1, 0, 0.5, 0.5], [0.9, 0, 0.5, 0.5], [0, 0, Double.nan, 1]] {
            let bad = BattleScript(
                                        priority: ["R"], regions: ["R": invalid])
            do { try bad.validate(); fatalError("Invalid region accepted") } catch { }
        }
        let old = Script(deviceWidth: 1584, deviceHeight: 720,
                         events: [.touch(action: 0, relX: 0.5, relY: 0.5, t: 0), .touch(action: 1, relX: 0.5, relY: 0.5, t: 0.1)])
        let restored = try Script.decode(from: old.encoded())
        precondition(restored.version == 3 && restored.events.count == 2)
        precondition(restored.repeatCount == nil && restored.playbackRepeatCount == 1)
        for count in [Int.min, -1, 0, 1, 2, 3, Int.max] {
            var repeated = old
            repeated.repeatCount = count
            let decoded = try Script.decode(from: repeated.encoded())
            precondition(decoded.repeatCount == count && decoded.playbackRepeatCount == max(1, count))
            precondition(decoded.events.count == 2 && decoded.events[1].t == 0.1)
        }
        let explicit = try Script.decode(from: Data(#"{"version":3,"deviceWidth":1584,"deviceHeight":720,"repeatCount":3,"events":[]}"#.utf8))
        precondition(explicit.playbackRepeatCount == 3 && explicit.events.isEmpty)
        for invalid in ["1.5", "\"3\""] {
            let json = "{\"version\":3,\"deviceWidth\":1584,\"deviceHeight\":720,\"repeatCount\":\(invalid),\"events\":[]}"
            do { _ = try Script.decode(from: Data(json.utf8)); fatalError("Invalid v3 repeatCount accepted") } catch { }
        }
        for version in [1, 2] {
            let json = "{\"version\":\(version),\"deviceWidth\":1584,\"deviceHeight\":720,\"events\":[]}"
            do { _ = try Script.decode(from: Data(json.utf8)); fatalError("Unsupported version accepted") } catch { }
        }
        print("V3 optional repeatCount, version rejection, integer validation, and event timing round-trip passed")
        print("Priority combinations, invalid regions, missing labels, and v3 round-trip passed")
        try checkPickupMovement()
        try checkTextStop()

        guard CommandLine.arguments.count == 2 else { return }
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let worker = SkillClassifier()
        defer { worker.cleanup() }
        try worker.start(project: root.path)
        let labels = try worker.classify(frame: root.appendingPathComponent("data/rand/crop_2.jpg"), regions: ["R": [0, 0, 1, 1]])
        precondition(["useable", "not_useable"].contains(labels["R"] ?? ""))
        print("Swift ↔ Python real-model protocol passed")

        let decoder = VideoDecoder(layer: AVSampleBufferDisplayLayer())
        let asset = AVURLAsset(url: root.appendingPathComponent("video_tools/xin.mp4"))
        guard let track = asset.tracks(withMediaType: .video).first else { fatalError("No video track") }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(output)
        precondition(reader.startReading())
        var configured = false
        for _ in 0..<10 {
            guard let sample = output.copyNextSampleBuffer() else {
                throw replayError("No sample: status=\(reader.status.rawValue), error=\(String(describing: reader.error))")
            }
            if CMSampleBufferGetNumSamples(sample) == 0 { continue } // MP4 edit-boundary marker.
            guard let desc = CMSampleBufferGetFormatDescription(sample) else {
                throw replayError("No format: \(sample)")
            }
            guard let block = CMSampleBufferGetDataBuffer(sample) else {
                throw replayError("No data block: \(sample)")
            }
            if !configured {
                var config = Data()
                for index in 0..<2 {
                    var pointer: UnsafePointer<UInt8>?
                    var size = 0
                    let status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(desc, parameterSetIndex: index,
                        parameterSetPointerOut: &pointer, parameterSetSizeOut: &size,
                        parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
                    precondition(status == noErr)
                    config.append(contentsOf: [0, 0, 0, 1])
                    config.append(pointer!, count: size)
                }
                decoder.setConfig(config)
                configured = true
            }
            var avcc = Data(count: CMBlockBufferGetDataLength(block))
            let copied = avcc.withUnsafeMutableBytes {
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!)
            }
            precondition(copied == noErr)
            var annexb = Data(), offset = 0
            while offset + 4 <= avcc.count {
                let size = (0..<4).reduce(0) { ($0 << 8) | Int(avcc[offset + $1]) }
                offset += 4
                precondition(size > 0 && offset + size <= avcc.count)
                annexb.append(contentsOf: [0, 0, 0, 1])
                annexb.append(avcc[offset..<offset + size])
                offset += size
            }
            decoder.enqueue(annexb)
        }
        reader.cancelReading()
        let image = worker.directory.appendingPathComponent("decoded.png")
        let deadline = Date().addingTimeInterval(10)
        var size: (Int, Int)?
        while Date() < deadline && size == nil {
            size = try? decoder.saveCurrentFrame(to: image)
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        guard let size else { _ = try decoder.saveCurrentFrame(to: image); fatalError("No decoded frame") }
        precondition(size.0 == 1584 && size.1 == 720)
        let classified = try worker.classify(frame: image, regions: ["R": [1062.0 / 1584, 542.0 / 720, 60.0 / 1584, 60.0 / 720]])
        precondition(["useable", "not_useable"].contains(classified["R"] ?? ""))
        print("H.264 → VideoToolbox → PNG → YOLO passed (1584×720)")
    }

    static func checkTextStop() throws {
        let alternatives = try JSONDecoder().decode(TextStopCondition.self,
            from: Data(#"{"text":["BATTLE DONE","领取"],"region":[0,0,1,1]}"#.utf8))
        try alternatives.validate()
        precondition(alternatives.matches("battle\n done"))
        precondition(alternatives.matches("领取奖励"))
        precondition(!alternatives.matches("BATTLE START"))
        for invalid in ["[]", "[\"\"]", "[\"DONE\",\" \"]", "[\"DONE\",1]", "null", "42"] {
            let json = "{\"text\":\(invalid),\"region\":[0,0,1,1]}"
            do {
                let bad = try JSONDecoder().decode(TextStopCondition.self, from: Data(json.utf8))
                try bad.validate()
                fatalError("Invalid text alternatives accepted")
            } catch { }
        }
        let condition = try JSONDecoder().decode(TextStopCondition.self,
            from: Data(#"{"text":"BATTLE DONE","region":[0,0,1,0.5]}"#.utf8))
        try condition.validate()
        precondition(condition.matches("  battle\n DONE  "))
        precondition(!condition.matches("BATTLE START"))
        for invalid in [TextStopCondition(text: " ", region: [0, 0, 1, 1]),
                        TextStopCondition(text: "DONE", region: [0, 0.9, 1, 0.5]),
                        TextStopCondition(text: "DONE", region: [])] {
            do { try invalid.validate(); fatalError("Invalid text condition accepted") } catch { }
        }
        print("Text string/array decoding, any-phrase matching, and invalid alternatives passed")
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1000, pixelsHigh: 400,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: 1000, height: 400).fill()
        ("BATTLE DONE" as NSString).draw(at: NSPoint(x: 60, y: 280), withAttributes: [
            .font: NSFont.systemFont(ofSize: 64), .foregroundColor: NSColor.black])
        NSGraphicsContext.restoreGraphicsState()
        let frame = FileManager.default.temporaryDirectory.appendingPathComponent("ocr-check-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: frame) }
        try bitmap.representation(using: .png, properties: [:])!.write(to: frame)
        let recognized = try condition.recognize(in: frame)
        precondition(condition.matches(recognized), "OCR missed top region: \(recognized)")
        let bottom = TextStopCondition(text: "BATTLE DONE", region: [0, 0.5, 1, 0.5])
        let outside = try bottom.recognize(in: frame)
        precondition(!bottom.matches(outside), "OCR included text outside region")
        let pickupAreas = try JSONDecoder().decode(PickupTextCondition.self,
            from: Data(#"{"text":["BATTLE DONE","领取"],"regions":[[0,0.5,1,0.5],[0,0,1,0.5],[0,0,1,1]]}"#.utf8))
        var checked: [Bool] = []
        let matchedRegion = try pickupAreas.matchingRegion(in: frame) { _, _, matched in
            checked.append(matched)
        }
        precondition(matchedRegion == [0, 0, 1, 0.5] && checked == [false, true],
                     "Pickup must select the first matching area and stop checking")
        let noMatch = try JSONDecoder().decode(PickupTextCondition.self,
            from: Data(#"{"text":"ABSENT","regions":[[0,0,1,0.5],[0,0.5,1,0.5]]}"#.utf8))
        checked = []
        let missingRegion = try noMatch.matchingRegion(in: frame) { _, _, matched in
            checked.append(matched)
        }
        precondition(missingRegion == nil && checked == [false, false])
        for invalid in ["[]", "[[0,0,1,1],[]]", "[[0,0,1,1],[0,0.9,1,0.5]]", "[0,0,1,1]", "null"] {
            let json = "{\"text\":\"DONE\",\"regions\":\(invalid)}"
            do {
                let bad = try JSONDecoder().decode(PickupTextCondition.self, from: Data(json.utf8))
                try bad.validate()
                fatalError("Invalid pickup regions accepted")
            } catch { }
        }
        print("Pickup multiple areas, first-match selection, no match, and invalid regions passed")
        let chinese = TextStopCondition(text: "领取", region: [216.0 / 3168, 400.0 / 1440, 174.0 / 3168, 46.0 / 1440])
        let demo = URL(fileURLWithPath: "demo.png")
        let start = Date()
        let chineseText = try chinese.recognize(in: demo)
        precondition(chinese.matches(chineseText), "OCR missed Chinese game text: \(chineseText)")
        let pickup = TextStopCondition(text: "吸收", region: [1900.0 / 3168, 520.0 / 1440, 500.0 / 3168, 200.0 / 1440])
        let pickupText = try pickup.recognize(in: demo)
        precondition(pickup.matches(pickupText), "OCR missed pickup text: \(pickupText)")
        print("Game screenshot OCR: \(chineseText), matched=true, \(Date().timeIntervalSince(start))s")
        print("Optional text config, matching, validation, and real OCR region checks passed")
    }

    static func checkPickupMovement() throws {
        for seconds in [0.1, 0.25, 0.3, 1.0, 1.1, 10.0] {
            let bursts = Array(PickupMovement.Step(direction: .up, seconds: seconds).bursts)
            precondition(bursts.allSatisfy { $0 > 0 && $0 <= 0.25 })
            precondition(abs(bursts.reduce(0, +) - seconds) < 1e-9, "Bursts changed total movement time")
        }
        let partial = Array(PickupMovement.Step(direction: .right, seconds: 0.3).bursts)
        precondition(partial.count == 2 && abs(partial[1] - 0.05) < 1e-9)
        let movement = try JSONDecoder().decode(PickupMovement.self, from: Data(#"{"joystick":[0.2,0.7],"radius":[0.05,0.1],"steps":[{"direction":"up","seconds":1},{"direction":"right","seconds":2},{"direction":"down","seconds":3},{"direction":"left","seconds":4},{"direction":"up","seconds":5},{"direction":"right","seconds":6}]}"#.utf8))
        try movement.validate()
        let expected = [(0.2, 0.6), (0.25, 0.7), (0.2, 0.8), (0.15, 0.7), (0.2, 0.6), (0.25, 0.7)]
        for (step, expectedPoint) in zip(movement.steps, expected) {
            let point = movement.point(for: step.direction)
            precondition(abs(point.0 - expectedPoint.0) < 1e-9 && abs(point.1 - expectedPoint.1) < 1e-9)
        }
        for bad in [PickupMovement(joystick: [], radius: [0.1, 0.1], steps: movement.steps),
                    PickupMovement(joystick: [0, 0], radius: [0.1, 0.1], steps: movement.steps),
                    PickupMovement(joystick: [0.5, 0.5], radius: [0.1, 0.1], steps: []),
                    PickupMovement(joystick: [0.5, 0.5], radius: [0.1, 0.1], steps: [.init(direction: .up, seconds: -.infinity)]),
                    PickupMovement(joystick: [0.5, 0.5], radius: [0.1, 0.1], steps: [.init(direction: .up, seconds: 0)])] {
            do { try bad.validate(); fatalError("Invalid movement accepted") } catch { }
        }
        print("Pickup route geometry and configuration validation passed")
    }
}
