import Foundation

/// Pushes scrcpy-server to the device, sets up the reverse tunnel, and exchanges video/control streams.
final class ScrcpyClient {
    let device: Device
    var onVideoSize: ((UInt32, UInt32) -> Void)?
    var onDeviceName: ((String) -> Void)?
    var onConnectionFailed: ((String) -> Void)?
    /// Device clipboard change callback (main thread), used to sync to the Mac clipboard.
    var onClipboardText: ((String) -> Void)?

    private(set) var controlSender: ControlSender?

    private let cancel = AtomicFlag()
    private let connectionQueue = DispatchQueue(label: "adbquick.connection")
    private let controlReadQueue = DispatchQueue(label: "adbquick.control-read")

    private var server: TcpServer?
    private var serverProcess: Process?
    private var videoSocket: PosixSocket?
    private var controlSocket: PosixSocket?
    private var socketName: String?
    private let decoder: VideoDecoder
    private let turnScreenOffOnConnect: Bool

    init(device: Device, decoder: VideoDecoder) {
        self.device = device
        self.decoder = decoder
        self.turnScreenOffOnConnect = AppSettings.turnScreenOffOnConnect
    }

    func start() {
        connectionQueue.async { [weak self] in
            self?.run()
        }
    }

    private func run() {
        log("Connecting to device \(device.serial)")
        let adb = AdbClient(adbPath: AppSettings.adbPath)
        do {
            let serverPath = AppSettings.serverPath
            guard !serverPath.isEmpty, FileManager.default.isReadableFile(atPath: serverPath) else {
                throw AdbError.serverNotFound
            }
            log("server path: \(serverPath)")

            // 1. Push the server
            log("Pushing scrcpy-server…")
            try adb.push(serial: device.serial, local: serverPath, remote: "/data/local/tmp/scrcpy-server.jar")
            log("Push complete")

            // 2. Reverse tunnel + local listener
            let scid = UInt32.random(in: 0...0x7FFFFFFF)
            socketName = String(format: "scrcpy_%08x", scid)
            let tcpServer = try TcpServer()
            self.server = tcpServer
            log("Local listening port: \(tcpServer.port)")
            try adb.reverse(serial: device.serial,
                            remote: "localabstract:\(socketName!)",
                            localPort: tcpServer.port)
            log("reverse complete: \(socketName!)")

            // 3. Start the server (the device connects back to the local port)
            let process = try adb.spawnServer(serial: device.serial, scid: scid)
            self.serverProcess = process
            log("server started")

            // 4. Accept the video and control connections in order
            guard let video = try tcpServer.accept(timeout: 15) else {
                throw AdbError.commandFailed("Timed out connecting the video stream")
            }
            self.videoSocket = video
            log("Video connection accepted")
            guard let control = try tcpServer.accept(timeout: 15) else {
                throw AdbError.commandFailed("Timed out connecting the control stream")
            }
            self.controlSocket = control
            log("Control connection accepted")

            DispatchQueue.main.async { [weak self] in
                guard let self, !self.cancel.value else { return }
                self.controlSender = ControlSender(socket: control)
            }

            // Start reading device messages (clipboard sync etc.)
            startDeviceMessageReader(socket: control)

            // 5. Read the video stream (blocks until the connection drops)
            try readVideo(socket: video)
        } catch {
            if cancel.value { return }
            log("Connection failed: \(error.localizedDescription)")
            DispatchQueue.main.async { [weak self] in
                self?.onConnectionFailed?(error.localizedDescription)
            }
        }
    }

    func log(_ message: String) {
        let line = "[AdbQuick] \(message)"
        print(line)
        let url = URL(fileURLWithPath: "/tmp/adbquick.log")
        let data = (line + "\n").data(using: .utf8) ?? Data()
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: url, options: .atomic)
        }
    }

    private func readVideo(socket: PosixSocket) throws {
        // Device name (64 bytes, NUL-terminated)
        let nameData = try socket.readExact(64)
        let nameBytes = [UInt8](nameData)
        let nameEnd = nameBytes.firstIndex(of: 0) ?? nameBytes.count
        let deviceName = String(data: Data(nameBytes[0..<nameEnd]), encoding: .utf8) ?? device.displayName
        DispatchQueue.main.async { [weak self] in
            self?.onDeviceName?(deviceName)
        }

        // Codec id (u32, big-endian); h264 = 0x68323634
        _ = try socket.readUInt32()

        var receivedFirstFrame = false
        while !cancel.value {
            let header = try socket.readExact(12)
            let b = [UInt8](header)
            if b[0] & 0x80 != 0 {
                // Session packet: width, height
                let width = u32(b, 4)
                let height = u32(b, 8)
                decoder.reset()
                DispatchQueue.main.async { [weak self] in
                    self?.onVideoSize?(width, height)
                }
            } else {
                let ptsAndFlags = u64(b, 0)
                let size = u32(b, 8)
                let payload = try socket.readExact(Int(size))
                let isConfig = (ptsAndFlags & (UInt64(1) << 62)) != 0
                if isConfig {
                    decoder.setConfig(payload)
                } else {
                    decoder.enqueue(payload)
                    if !receivedFirstFrame {
                        receivedFirstFrame = true
                        if turnScreenOffOnConnect {
                            DispatchQueue.main.async { [weak self] in
                                guard let self, !self.cancel.value else { return }
                                self.controlSender?.sendSetDisplayPower(false)
                                self.log("Video stream connected; requested screen off")
                            }
                        }
                    }
                }
            }
        }
    }

    private func u32(_ b: [UInt8], _ off: Int) -> UInt32 {
        UInt32(b[off]) << 24 | UInt32(b[off + 1]) << 16 | UInt32(b[off + 2]) << 8 | UInt32(b[off + 3])
    }

    private func u64(_ b: [UInt8], _ off: Int) -> UInt64 {
        (0..<8).reduce(0) { ($0 << 8) | UInt64(b[off + $1]) }
    }

    // MARK: - Device messages (device → client)

    private func startDeviceMessageReader(socket: PosixSocket) {
        controlReadQueue.async { [weak self] in
            self?.readDeviceMessages(socket: socket)
        }
    }

    private func readDeviceMessages(socket: PosixSocket) {
        while !cancel.value {
            do {
                let typeData = try socket.readExact(1)
                let type = typeData[0]
                switch type {
                case 0: // TYPE_CLIPBOARD
                    let len = try socket.readUInt32()
                    let textData = try socket.readExact(Int(len))
                    let text = String(data: textData, encoding: .utf8) ?? ""
                    DispatchQueue.main.async { [weak self] in
                        self?.onClipboardText?(text)
                    }
                case 1: // TYPE_ACK_CLIPBOARD
                    _ = try socket.readExact(8) // sequence
                case 2: // TYPE_UHID_OUTPUT
                    _ = try socket.readExact(2) // id
                    let sizeBytes = try socket.readExact(2)
                    let size = Int(sizeBytes[0]) << 8 | Int(sizeBytes[1])
                    _ = try socket.readExact(size)
                default:
                    return // unknown type, stop reading
                }
            } catch {
                break // connection closed or error
            }
        }
    }

    func stop() {
        cancel.value = true
        server?.close()
        videoSocket?.close()
        controlSocket?.close()
        serverProcess?.terminate()

        // Clean up the reverse tunnel in the background to avoid blocking the main thread (when closing the window).
        let serial = device.serial
        let name = socketName
        if let name {
            DispatchQueue.global().async {
                AdbClient(adbPath: AppSettings.adbPath)
                    .removeReverse(serial: serial, remote: "localabstract:\(name)")
            }
        }
    }
}
