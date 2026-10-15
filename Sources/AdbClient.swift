import Foundation

/// 对本地 ADB 命令的封装。
struct AdbClient {
    let adbPath: String

    /// 同步执行一条 adb 命令，返回标准输出、标准错误与退出码。
    func run(_ args: [String]) throws -> (stdout: String, stderr: String, exitCode: Int32) {
        let (out, err, code) = try runRaw(args)
        return (String(data: out, encoding: .utf8) ?? "",
                String(data: err, encoding: .utf8) ?? "",
                code)
    }

    /// 执行 adb 命令并返回原始二进制标准输出（用于 screencap 等）。
    func runBinary(_ args: [String]) throws -> Data {
        let (out, err, code) = try runRaw(args)
        guard code == 0 else {
            throw AdbError.commandFailed(String(data: err, encoding: .utf8) ?? "")
        }
        return out
    }

    /// 执行 adb 并并发排空 stdout/stderr，避免大输出填满管道缓冲导致死锁。
    private func runRaw(_ args: [String]) throws -> (stdout: Data, stderr: Data, exitCode: Int32) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: adbPath)
        process.arguments = args
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = FileHandle.nullDevice
        try process.run()

        let group = DispatchGroup()
        var outData = Data()
        var errData = Data()

        group.enter()
        DispatchQueue.global().async {
            outData = outPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        group.enter()
        DispatchQueue.global().async {
            errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }

        process.waitUntilExit()
        group.wait()

        return (outData, errData, process.terminationStatus)
    }

    /// 截取设备屏幕，返回 PNG 数据。
    func screencap(serial: String) throws -> Data {
        try runBinary(["-s", serial, "exec-out", "screencap", "-p"])
    }

    /// 列出已连接（且已授权）的设备。
    func devices() throws -> [Device] {
        let (out, _, code) = try run(["devices", "-l"])
        guard code == 0 else { throw AdbError.commandFailed("adb devices 执行失败") }
        return parseDevices(out)
    }

    private func parseDevices(_ output: String) -> [Device] {
        var result: [Device] = []
        for line in output.split(separator: "\n") {
            let s = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
            if s.isEmpty || s.hasPrefix("List of devices") { continue }
            let tokens = s.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            guard tokens.count >= 2 else { continue }
            let serial = tokens[0]
            let state = tokens[1]
            var model: String?
            var product: String?
            var transport: String?
            for t in tokens.dropFirst(2) {
                if t.hasPrefix("model:") {
                    model = String(t.dropFirst("model:".count))
                } else if t.hasPrefix("product:") {
                    product = String(t.dropFirst("product:".count))
                } else if t.hasPrefix("transport_id:") {
                    transport = String(t.dropFirst("transport_id:".count))
                }
            }
            result.append(Device(serial: serial, state: state, model: model, product: product, transport: transport))
        }
        return result.filter { $0.state == "device" }
    }

    /// 获取设备名字、Android 版本与屏幕分辨率（一次 shell 命令）。
    func deviceInfo(serial: String) -> (name: String?, version: String?, resolution: String?) {
        guard let result = try? run(["-s", serial, "shell", "settings get global device_name; getprop ro.build.version.release; wm size"]),
              result.exitCode == 0 else {
            return (nil, nil, nil)
        }
        var name: String?
        var version: String?
        var resolution: String?
        var nonSizeLines = 0
        for line in result.stdout.split(separator: "\n") {
            let s = String(line).trimmingCharacters(in: .whitespaces)
            if s.isEmpty { continue }
            if s.contains("size:") {
                // "Physical size: 1440x3168" / "Override size: 1080x2376"
                if let range = s.range(of: ":") {
                    let size = s[s.index(after: range.upperBound)...].trimmingCharacters(in: .whitespaces)
                    resolution = size.replacingOccurrences(of: "x", with: "×")
                }
            } else {
                nonSizeLines += 1
                if nonSizeLines == 1 {
                    // 设备名字（settings 未设置时返回 "null"）
                    name = (s == "null") ? nil : s
                } else if nonSizeLines == 2 {
                    version = s
                }
            }
        }
        return (name, version, resolution)
    }

    /// 建立反向端口转发（设备上的 localabstract 指向本机 tcp 端口）。
    func reverse(serial: String, remote: String, localPort: UInt16) throws {
        let (_, err, code) = try run(["-s", serial, "reverse", remote, "tcp:\(localPort)"])
        guard code == 0 else { throw AdbError.commandFailed("adb reverse 失败：\(err)") }
    }

    func removeReverse(serial: String, remote: String) {
        _ = try? run(["-s", serial, "reverse", "--remove", remote])
    }

    /// 推送 scrcpy-server 到设备。
    func push(serial: String, local: String, remote: String) throws {
        let (_, err, code) = try run(["-s", serial, "push", local, remote])
        guard code == 0 else { throw AdbError.commandFailed("adb push 失败：\(err)") }
    }

    /// 在设备上启动 scrcpy-server（长驻进程），返回可终止的 Process。
    func spawnServer(serial: String, scid: UInt32) throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: adbPath)
        let scidHex = String(format: "%08x", scid)
        process.arguments = [
            "-s", serial, "shell",
            "CLASSPATH=/data/local/tmp/scrcpy-server.jar",
            "app_process", "/", "com.genymobile.scrcpy.Server",
            "5.0.1",
            "scid=\(scidHex)",
            "log_level=info",
            "audio=false",
        ]
        process.standardInput = FileHandle.nullDevice

        // 把 server 日志写入文件（不用 readabilityHandler，避免进程终止后 FileHandle 悬垂导致崩溃）。
        let logURL = URL(fileURLWithPath: "/tmp/adbquick-server.log")
        if !FileManager.default.fileExists(atPath: logURL.path) {
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
        }
        if let logHandle = try? FileHandle(forWritingTo: logURL) {
            try? logHandle.truncate(atOffset: 0)
            process.standardOutput = logHandle
            process.standardError = logHandle
        } else {
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
        }

        try process.run()
        return process
    }
}
