import Foundation

/// 负责把 scrcpy-server 推到设备、建立反向隧道并收发视频/控制流。
final class ScrcpyClient {
    let device: Device
    var onVideoSize: ((UInt32, UInt32) -> Void)?
    var onDeviceName: ((String) -> Void)?
    var onConnectionFailed: ((String) -> Void)?
    /// 设备剪贴板变化回调（主线程），用于同步到电脑剪贴板。
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
        log("开始连接设备 \(device.serial)")
        let adb = AdbClient(adbPath: AppSettings.adbPath)
        do {
            let serverPath = AppSettings.serverPath
            guard !serverPath.isEmpty, FileManager.default.isReadableFile(atPath: serverPath) else {
                throw AdbError.serverNotFound
            }
            log("server 路径: \(serverPath)")

            // 1. 推送 server
            log("推送 scrcpy-server…")
            try adb.push(serial: device.serial, local: serverPath, remote: "/data/local/tmp/scrcpy-server.jar")
            log("推送完成")

            // 2. 反向隧道 + 本地监听
            let scid = UInt32.random(in: 0...0x7FFFFFFF)
            socketName = String(format: "scrcpy_%08x", scid)
            let tcpServer = try TcpServer()
            self.server = tcpServer
            log("本地监听端口: \(tcpServer.port)")
            try adb.reverse(serial: device.serial,
                            remote: "localabstract:\(socketName!)",
                            localPort: tcpServer.port)
            log("reverse 完成: \(socketName!)")

            // 3. 启动 server（设备会连回本地监听端口）
            let process = try adb.spawnServer(serial: device.serial, scid: scid)
            self.serverProcess = process
            log("server 已启动")

            // 4. 依次接受视频、控制连接
            guard let video = try tcpServer.accept(timeout: 15) else {
                throw AdbError.commandFailed("连接视频流超时")
            }
            self.videoSocket = video
            log("视频连接已接受")
            guard let control = try tcpServer.accept(timeout: 15) else {
                throw AdbError.commandFailed("连接控制流超时")
            }
            self.controlSocket = control
            log("控制连接已接受")

            DispatchQueue.main.async { [weak self] in
                guard let self, !self.cancel.value else { return }
                self.controlSender = ControlSender(socket: control)
            }

            // 启动设备消息读取（剪贴板同步等）
            startDeviceMessageReader(socket: control)

            // 5. 读取视频流（阻塞直至连接断开）
            try readVideo(socket: video)
        } catch {
            if cancel.value { return }
            log("连接失败: \(error.localizedDescription)")
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
        // 设备名（64 字节，以 \0 结尾）
        let nameData = try socket.readExact(64)
        let nameBytes = [UInt8](nameData)
        let nameEnd = nameBytes.firstIndex(of: 0) ?? nameBytes.count
        let deviceName = String(data: Data(nameBytes[0..<nameEnd]), encoding: .utf8) ?? device.displayName
        DispatchQueue.main.async { [weak self] in
            self?.onDeviceName?(deviceName)
        }

        // 编解码器 id（u32，大端）；h264 = 0x68323634
        _ = try socket.readUInt32()

        var receivedFirstFrame = false
        while !cancel.value {
            let header = try socket.readExact(12)
            let b = [UInt8](header)
            if b[0] & 0x80 != 0 {
                // 会话包：宽度、高度
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
                                self.log("视频流已连接，已请求关闭手机屏幕")
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

    // MARK: - 设备消息（device → client）

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
                    return // 未知类型，停止读取
                }
            } catch {
                break // 连接关闭或出错
            }
        }
    }

    func stop() {
        cancel.value = true
        server?.close()
        videoSocket?.close()
        controlSocket?.close()
        serverProcess?.terminate()

        // 清理 reverse 隧道放到后台，避免阻塞主线程（关闭窗口时）。
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
