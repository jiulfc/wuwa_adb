import Foundation
import ImageIO

enum CirclePercentageDetector {
    private static let size = 72
    private static let innerRadius = 30.0
    private static let outerRadius = 36.0

    static func percentage(in frame: URL, roi: [Double]) throws -> Double {
        guard roi.count == 4, roi.allSatisfy({ $0.isFinite && $0.rounded() == $0 }),
              roi[0] >= 0, roi[1] >= 0, roi[2] == Double(size), roi[3] == Double(size),
              let source = CGImageSourceCreateWithURL(frame as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              roi[0] + roi[2] <= Double(image.width),
              roi[1] + roi[3] <= Double(image.height),
              let crop = image.cropping(to: CGRect(x: roi[0], y: roi[1], width: roi[2], height: roi[3])) else {
            throw replayError("circle_percentage default profile requires a valid 72x72 pixel ROI.")
        }

        var pixels = [UInt8](repeating: 0, count: size * size * 4)
        let rendered = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: size, height: size,
                                          bitsPerComponent: 8, bytesPerRow: size * 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue |
                                              CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
            context.draw(crop, in: CGRect(x: 0, y: 0, width: size, height: size))
            return true
        }
        guard rendered else { throw replayError("circle_percentage could not render the ROI.") }

        return try percentage(rgba: pixels)
    }

    static func percentage(rgba pixels: [UInt8]) throws -> Double {
        guard pixels.count == size * size * 4 else {
            throw replayError("circle_percentage requires a 72x72 RGBA image.")
        }
        var totals = [Int](repeating: 0, count: 180)
        var hits = [Int](repeating: 0, count: 180)
        let center = Double(size) / 2
        for y in 0..<size {
            for x in 0..<size {
                let dx = Double(x) - center
                let dy = Double(y) - center
                let radius = hypot(dx, dy)
                guard radius >= innerRadius, radius <= outerRadius else { continue }
                var angle = atan2(dy, dx) * 180 / .pi
                if angle < 0 { angle += 360 }
                let bin = min(Int(angle / 2), totals.count - 1)
                totals[bin] += 1
                let offset = (y * size + x) * 4
                if isGreen(red: pixels[offset], green: pixels[offset + 1], blue: pixels[offset + 2]) {
                    hits[bin] += 1
                }
            }
        }

        var valid = 0
        var filled = 0
        for bin in totals.indices where totals[bin] > 0 {
            valid += 1
            if Double(hits[bin]) >= max(1, Double(totals[bin]) * 0.2) { filled += 1 }
        }
        guard valid > 0 else { throw replayError("circle_percentage ring has no pixels.") }
        return Double(filled) / Double(valid)
    }

    private static func isGreen(red: UInt8, green: UInt8, blue: UInt8) -> Bool {
        let r = Double(red), g = Double(green), b = Double(blue)
        let maximum = max(r, g, b)
        let minimum = min(r, g, b)
        let delta = maximum - minimum
        guard maximum >= 60, delta > 0, delta / maximum >= 60.0 / 255 else { return false }

        let hue: Double
        if maximum == r {
            hue = 60 * ((g - b) / delta).truncatingRemainder(dividingBy: 6)
        } else if maximum == g {
            hue = 60 * ((b - r) / delta + 2)
        } else {
            hue = 60 * ((r - g) / delta + 4)
        }
        let normalizedHue = hue < 0 ? hue + 360 : hue
        return normalizedHue >= 110 && normalizedHue <= 190
    }
}
