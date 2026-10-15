import Foundation

struct PickupMovement: Decodable {
    let joystick: [Double]
    let radius: [Double]
    let steps: [Step]

    struct Step: Decodable {
        let direction: Direction
        let seconds: Double

        var bursts: some Sequence<Double> {
            stride(from: 0.0, to: seconds, by: 0.25).lazy.map { min(0.25, self.seconds - $0) }
        }
    }

    enum Direction: String, Decodable {
        case up, right, down, left
    }

    func point(for direction: Direction) -> (Double, Double) {
        switch direction {
        case .up: return (joystick[0], joystick[1] - radius[1])
        case .right: return (joystick[0] + radius[0], joystick[1])
        case .down: return (joystick[0], joystick[1] + radius[1])
        case .left: return (joystick[0] - radius[0], joystick[1])
        }
    }

    func validate() throws {
        guard joystick.count == 2, radius.count == 2,
              (joystick + radius).allSatisfy({ $0.isFinite }),
              radius.allSatisfy({ $0 > 0 }),
              joystick[0] - radius[0] >= 0, joystick[0] + radius[0] <= 1,
              joystick[1] - radius[1] >= 0, joystick[1] + radius[1] <= 1,
              !steps.isEmpty,
              steps.allSatisfy({ $0.seconds.isFinite && $0.seconds > 0 && $0.seconds < 1e9 }) else {
            throw replayError("pickupMovement 需要有效的归一化 joystick/radius，以及正数 seconds 的方向 steps。")
        }
    }
}
