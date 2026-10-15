import Foundation
import Darwin

/// One worker per replay; only the replay queue uses the request/response pipes.
final class SkillClassifier {
    private let lock = NSLock()
    private let cancelSignal = DispatchSemaphore(value: 0)
    private var process: Process?
    private var cancelled = false
    private let input = Pipe()
    private let output = Pipe()
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("adbquick-\(UUID().uuidString)")

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func start(project: String) throws {
        let root = URL(fileURLWithPath: project)
        let python = root.appendingPathComponent(".venv/bin/python")
        let helper = root.appendingPathComponent("live.py")
        guard FileManager.default.isExecutableFile(atPath: python.path),
              FileManager.default.isReadableFile(atPath: helper.path) else {
            throw replayError("请在设置中选择 wuwa_classify 项目，确保 .venv/bin/python 和 live.py 存在。")
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let log = directory.appendingPathComponent("worker.log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let logHandle = try FileHandle(forWritingTo: log)
        defer { try? logHandle.close() }
        let child = Process()
        child.executableURL = python
        child.arguments = ["-u", helper.path]
        child.currentDirectoryURL = root
        child.standardInput = input
        child.standardOutput = output
        child.standardError = logHandle
        lock.lock()
        if cancelled { lock.unlock(); throw replayError("回放已停止。") }
        do {
            try child.run()
            process = child
            lock.unlock()
        } catch {
            lock.unlock()
            throw error
        }
        // Close the parent's copies so worker exit produces EOF on the reader.
        try? output.fileHandleForWriting.close()
        try? input.fileHandleForReading.close()
        let ready = try receive(timeout: 60)
        guard ready["ready"] as? Bool == true else { throw replayError("分类器未就绪。") }
    }

    func classify(frame: URL, regions: [String: [Double]]) throws -> [String: String] {
        if isCancelled { throw replayError("回放已停止。") }
        var data = try JSONSerialization.data(withJSONObject: ["image": frame.path, "regions": regions])
        data.append(10)
        try input.fileHandleForWriting.write(contentsOf: data)
        let result = try receive(timeout: 15)
        guard let labels = result["labels"] as? [String: String] else {
            throw replayError("分类器返回格式错误。")
        }
        return labels
    }

    private func receive(timeout: Double) throws -> [String: Any] {
        let deadline = DispatchWorkItem { [weak self] in self?.stop() }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: deadline)
        defer { deadline.cancel() }
        var line = Data()
        while line.count < 1_048_576 {
            guard let byte = try output.fileHandleForReading.read(upToCount: 1), !byte.isEmpty else {
                let log = (try? String(contentsOf: directory.appendingPathComponent("worker.log"), encoding: .utf8)) ?? ""
                throw replayError("分类器退出或超时。\n" + String(log.suffix(4000)))
            }
            if byte[0] == 10 {
                guard let response = try JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                    throw replayError("分类器返回格式错误。")
                }
                if let error = response["error"] as? String { throw replayError(error) }
                return response
            }
            line.append(byte)
        }
        throw replayError("分类器响应过长。")
    }

    func wait(until deadline: DispatchTime) {
        _ = cancelSignal.wait(timeout: deadline)
    }

    func stop() {
        lock.lock()
        cancelled = true
        let child = process
        if let child, child.isRunning {
            child.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                if child.isRunning { kill(child.processIdentifier, SIGKILL) }
            }
        }
        lock.unlock()
        cancelSignal.signal()
    }

    /// Called by the replay queue after pending I/O has finished.
    func cleanup() {
        stop()
        process?.waitUntilExit()
        try? input.fileHandleForWriting.close()
        try? output.fileHandleForReading.close()
        try? FileManager.default.removeItem(at: directory)
    }
}
