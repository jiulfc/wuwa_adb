import Foundation

@main
struct CirclePercentageTests {
    static func main() throws {
        let size = 72
        func ring(color: (UInt8, UInt8, UInt8)?) -> [UInt8] {
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
                    guard radius >= 30, radius <= 36 else { continue }
                    let pixel = angle < 144 ? color ?? (220, 220, 220) : (220, 220, 220)
                    pixels[offset] = pixel.0
                    pixels[offset + 1] = pixel.1
                    pixels[offset + 2] = pixel.2
                }
            }
            return pixels
        }

        for color: (UInt8, UInt8, UInt8) in [(220, 40, 40), (40, 220, 160), (40, 80, 220)] {
            let percentage = try CirclePercentageDetector.percentage(rgba: ring(color: color))
            precondition(abs(percentage - 0.4) < 0.02, "Expected 40%, got \(percentage)")
        }
        let whitePercentage = try CirclePercentageDetector.percentage(rgba: ring(color: nil))
        precondition(whitePercentage == 0)
        print("Red, green, and blue: 40%; white: 0%")

        if CommandLine.arguments.count == 2 {
            let actual = try CirclePercentageDetector.percentage(
                in: URL(fileURLWithPath: CommandLine.arguments[1]), roi: [0, 0, 72, 72])
            precondition(actual >= 0.3 && actual <= 0.45, "Expected real image near 40%, got \(actual)")
            print("Real circle percentage: \(actual)")
        }
    }
}
