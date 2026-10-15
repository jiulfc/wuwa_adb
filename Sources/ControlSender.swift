import Foundation

/// 常用 Android 按键码。
enum AndroidKeyCode: Int32 {
    case home = 3
    case back = 4
    case power = 26
    case volumeUp = 24
    case volumeDown = 25
    case enter = 66
    case delete = 67
}

/// 将输入事件按 scrcpy 控制协议序列化并发送。
final class ControlSender {
    // 控制消息类型（与 scrcpy server 的 ControlMessage 保持一致）。
    private static let typeInjectKeycode: UInt8 = 0
    private static let typeInjectTouchEvent: UInt8 = 2
    private static let typeInjectScrollEvent: UInt8 = 3
    private static let typeBackOrScreenOn: UInt8 = 4
    private static let typeGetClipboard: UInt8 = 8
    private static let typeSetClipboard: UInt8 = 9
    private static let typeSetDisplayPower: UInt8 = 10
    private static let typeRotateDevice: UInt8 = 11

    // 剪贴板复制键。
    static let copyKeyCopy: UInt8 = 1

    // MotionEvent 动作。
    static let actionDown: UInt8 = 0
    static let actionUp: UInt8 = 1
    static let actionMove: UInt8 = 2

    private let socket: PosixSocket
    private let queue = DispatchQueue(label: "adbquick.control")

    init(socket: PosixSocket) {
        self.socket = socket
    }

    private func send(_ data: Data) {
        queue.async { [socket] in
            do { try socket.write(data) } catch { /* 忽略写入错误 */ }
        }
    }

    func sendTouch(action: UInt8, x: Int32, y: Int32,
                   screenWidth: UInt16, screenHeight: UInt16,
                   actionButton: Int32, buttons: Int32) {
        var d = Data()
        d.append(Self.typeInjectTouchEvent)
        d.append(action)
        d.appendBE(Int64(-1))            // pointerId（鼠标）
        d.appendBE(x)
        d.appendBE(y)
        d.appendBE(screenWidth)
        d.appendBE(screenHeight)
        d.appendBE(UInt16(0xFFFF))       // pressure = 1.0
        d.appendBE(actionButton)
        d.appendBE(buttons)
        send(d)
    }

    func sendKeycode(_ keycode: Int32, action: UInt8) {
        var d = Data()
        d.append(Self.typeInjectKeycode)
        d.append(action)
        d.appendBE(keycode)
        d.appendBE(Int32(0))             // repeat
        d.appendBE(Int32(0))             // metastate
        send(d)
    }

    func sendScroll(x: Int32, y: Int32,
                    screenWidth: UInt16, screenHeight: UInt16,
                    hScroll: Int16, vScroll: Int16) {
        var d = Data()
        d.append(Self.typeInjectScrollEvent)
        d.appendBE(x)
        d.appendBE(y)
        d.appendBE(screenWidth)
        d.appendBE(screenHeight)
        d.appendBE(hScroll)
        d.appendBE(vScroll)
        d.appendBE(Int32(1))             // buttons（主键按下）
        send(d)
    }

    func sendBack() {
        sendKeycode(AndroidKeyCode.back.rawValue, action: Self.actionDown)
        sendKeycode(AndroidKeyCode.back.rawValue, action: Self.actionUp)
    }

    func sendHome() {
        sendKeycode(AndroidKeyCode.home.rawValue, action: Self.actionDown)
        sendKeycode(AndroidKeyCode.home.rawValue, action: Self.actionUp)
    }

    func sendPower() {
        sendKeycode(AndroidKeyCode.power.rawValue, action: Self.actionDown)
        sendKeycode(AndroidKeyCode.power.rawValue, action: Self.actionUp)
    }

    func sendBackOrScreenOn(action: UInt8) {
        var d = Data()
        d.append(Self.typeBackOrScreenOn)
        d.append(action)
        send(d)
    }

    func sendRotate() {
        var d = Data()
        d.append(Self.typeRotateDevice)
        send(d)
    }

    func sendSetDisplayPower(_ on: Bool) {
        var d = Data()
        d.append(Self.typeSetDisplayPower)
        d.append(on ? 1 : 0)
        send(d)
    }

    /// 设置设备剪贴板，可选在设备上执行粘贴。
    func sendSetClipboard(text: String, paste: Bool, sequence: UInt64 = 0) {
        var d = Data()
        d.append(Self.typeSetClipboard)
        d.appendBE(sequence)
        d.append(paste ? 1 : 0)
        let utf8 = Data(text.utf8)
        d.appendBE(UInt32(utf8.count))
        d.append(utf8)
        send(d)
    }

    /// 请求设备剪贴板内容（设备会回发 TYPE_CLIPBOARD 消息）。
    func sendGetClipboard(copyKey: UInt8 = ControlSender.copyKeyCopy) {
        var d = Data()
        d.append(Self.typeGetClipboard)
        d.append(copyKey)
        send(d)
    }
}
