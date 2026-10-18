import Foundation

@main
struct CirclePercentageTests {
    static func main() throws {
        let size = 72
        var pixels = [UInt8](repeating: 0, count: size * size * 4)
        for y in 0..<size {
            for x in 0..<size {
                let offset = (y * size + x) * 4
                pixels[offset + 3] = 255
                let dx = Double(x) - Double(size) / 2
                let dy = Double(y) - Double(size) / 2
                let radius = hypot(dx, dy)
                var angle = atan2(dy, dx) * 180 / .pi
                if angle < 0 { angle += 360 }
                if radius >= 30, radius <= 36, angle < 144 {
                    pixels[offset] = 40
                    pixels[offset + 1] = 220
                    pixels[offset + 2] = 160
                }
            }
        }

        let percentage = try CirclePercentageDetector.percentage(rgba: pixels)
        precondition(abs(percentage - 0.4) < 0.02, "Expected 40%, got \(percentage)")
        print("Synthetic circle percentage: \(percentage)")

        if CommandLine.arguments.count == 2 {
            let actual = try CirclePercentageDetector.percentage(
                in: URL(fileURLWithPath: CommandLine.arguments[1]), roi: [0, 0, 72, 72])
            precondition(actual >= 0.3 && actual <= 0.45, "Expected real image near 40%, got \(actual)")
            print("Real circle percentage: \(actual)")
        }
    }
}
