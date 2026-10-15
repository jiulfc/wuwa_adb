import Foundation
import Darwin

@main
struct ScreenSettingsCheck {
    static func main() throws {
        let defaults = UserDefaults.standard
        let key = "turnScreenOffOnConnect"
        let original = defaults.object(forKey: key)
        defer {
            if let original { defaults.set(original, forKey: key) }
            else { defaults.removeObject(forKey: key) }
        }
        defaults.removeObject(forKey: key)
        precondition(AppSettings.turnScreenOffOnConnect)
        AppSettings.turnScreenOffOnConnect = false
        precondition(!AppSettings.turnScreenOffOnConnect)
        precondition(defaults.object(forKey: key) as? Bool == false)
        AppSettings.turnScreenOffOnConnect = true
        precondition(AppSettings.turnScreenOffOnConnect)

        var fds: [Int32] = [0, 0]
        precondition(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0)
        let senderSocket = PosixSocket(fd: fds[0])
        let receiver = PosixSocket(fd: fds[1])
        defer { senderSocket.close(); receiver.close() }
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        precondition(setsockopt(receiver.fd, SOL_SOCKET, SO_RCVTIMEO, &timeout,
                               socklen_t(MemoryLayout<timeval>.size)) == 0)
        let sender = ControlSender(socket: senderSocket)
        sender.sendSetDisplayPower(false)
        let message = try receiver.readExact(2)
        precondition(message == Data([10, 0]))
        print("Screen-off default, saved toggle, and display-power control message passed")
    }
}
