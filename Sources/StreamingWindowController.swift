import AppKit
import UniformTypeIdentifiers

/// 实时渲染窗口：大小 = 设备大小、方向 = 设备方向，接收触摸/按键/滚动控制。
///
/// 为避免「窗口先按默认尺寸出现、再突然放大到设备尺寸」的突兀体验，
/// 窗口会等到拿到第一帧视频尺寸（ready）后再以正确尺寸显示。
final class StreamingWindowController: NSObject, NSWindowDelegate {
    private let device: Device
    private let window: NSWindow
    private let videoView = VideoView(frame: .zero)
    private let decoder: VideoDecoder
    private let controlInfoStore: ControlInfoStore
    private var client: ScrcpyClient?
    private var lastAbsPoint: (Int32, Int32) = (0, 0)
    private var deviceName: String = ""
    private var isPlayingBack = false
    private var playbackGeneration = 0
    private var playbackTouch: (Double, Double)?
    private var classifier: SkillClassifier?
    private let replayQueue = DispatchQueue(label: "adbquick.replay")

    /// 拿到视频尺寸、窗口准备显示时回调（用于关闭设备列表等）。
    var onReady: (() -> Void)?
    /// 会话结束（连接失败或窗口关闭）时回调（用于重新展示设备列表）。
    var onEnded: (() -> Void)?

    private(set) var deviceWidth: UInt32 = 0
    private(set) var deviceHeight: UInt32 = 0

    private var isPresented = false
    private var didFinish = false

    // 脚本录制/回放状态
    private var isRecording = false
    private var recordedEvents: [ScriptEvent] = []
    private var recordStartTime: Date?

    init(device: Device, controlInfoStore: ControlInfoStore) {
        self.device = device
        self.controlInfoStore = controlInfoStore
        self.decoder = VideoDecoder(layer: videoView.displayLayer)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 480),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        super.init()
        // 关键：关闭时不让系统额外 release 窗口，否则窗口会提前释放，
        // 控制器析构时再次释放已释放的窗口导致崩溃（double-release）。
        window.isReleasedWhenClosed = false
        deviceName = device.displayName
        window.title = deviceName
        window.contentView = videoView
        window.minSize = NSSize(width: 200, height: 200)
        window.delegate = self
    }

    func start() {
        // 先不显示窗口，等 ready 后再显示。
        setupCallbacks()

        let client = ScrcpyClient(device: device, decoder: decoder)
        client.onVideoSize = { [weak self] width, height in
            self?.handleVideoSize(width: width, height: height)
        }
        client.onDeviceName = { [weak self] name in
            DispatchQueue.main.async {
                guard let self else { return }
                self.deviceName = name
                self.updateWindowTitle()
                self.controlInfoStore.setDeviceName(name)
            }
        }
        client.onConnectionFailed = { [weak self] message in
            self?.handleFailure(message)
        }
        client.onClipboardText = { [weak self] text in
            self?.setComputerClipboard(text)
        }
        self.client = client
        client.start()
    }

    private func setupCallbacks() {
        videoView.onMouseDown = { [weak self] p in self?.sendTouch(p, action: ControlSender.actionDown) }
        videoView.onMouseDragged = { [weak self] p in self?.sendTouch(p, action: ControlSender.actionMove) }
        videoView.onMouseUp = { [weak self] p in self?.sendTouch(p, action: ControlSender.actionUp) }
        videoView.onScroll = { [weak self] e in self?.handleScroll(e) }
        videoView.onKeyDown = { [weak self] e in self?.handleKey(e) }
    }

    private func sendTouch(_ p: NSPoint, action: UInt8) {
        guard let (x, y) = pointToDevice(p), let sender = client?.controlSender else { return }
        let actionButton: Int32 = (action == ControlSender.actionMove) ? 0 : 1
        let buttons: Int32 = (action == ControlSender.actionUp) ? 0 : 1
        sender.sendTouch(action: action, x: x, y: y,
                         screenWidth: UInt16(deviceWidth), screenHeight: UInt16(deviceHeight),
                         actionButton: actionButton, buttons: buttons)

        let operation: String
        switch action {
        case ControlSender.actionDown: operation = "触摸按下"
        case ControlSender.actionMove: operation = "触摸拖动"
        case ControlSender.actionUp: operation = "触摸抬起"
        default: operation = "触摸"
        }
        reportInfo(operation, point: (x, y))

        let relX = deviceWidth > 0 ? Double(x) / Double(deviceWidth) : 0
        let relY = deviceHeight > 0 ? Double(y) / Double(deviceHeight) : 0
        recordEvent(.touch(action: Int(action), relX: relX, relY: relY, t: 0))
    }

    private func handleScroll(_ event: NSEvent) {
        guard let sender = client?.controlSender else { return }
        let p = videoView.convert(event.locationInWindow, from: nil)
        guard let (x, y) = pointToDevice(p) else { return }
        let hScroll = encodeScroll(Float(event.deltaX))
        let vScroll = encodeScroll(Float(event.deltaY))
        sender.sendScroll(x: x, y: y,
                          screenWidth: UInt16(deviceWidth), screenHeight: UInt16(deviceHeight),
                          hScroll: hScroll, vScroll: vScroll)
        reportInfo("滚动", point: (x, y))

        let relX = deviceWidth > 0 ? Double(x) / Double(deviceWidth) : 0
        let relY = deviceHeight > 0 ? Double(y) / Double(deviceHeight) : 0
        recordEvent(.scroll(relX: relX, relY: relY, hScroll: hScroll, vScroll: vScroll, t: 0))
    }

    private func encodeScroll(_ v: Float) -> Int16 {
        let clamped = max(Float(-16), min(Float(16), v))
        return Int16(clamped / 16.0 * 32767.0)
    }

    private func handleKey(_ event: NSEvent) {
        guard let sender = client?.controlSender else { return }
        let mods = event.modifierFlags
        let key = event.charactersIgnoringModifiers?.lowercased()
        if mods.contains(.command) && key == "v" && !mods.contains(.shift) {
            // Cmd+V：把电脑剪贴板粘贴到设备
            pasteComputerClipboard()
            reportInfo("粘贴", point: nil)
        } else if mods.contains(.command) && mods.contains(.shift) && key == "h" {
            sender.sendHome()
            reportInfo("主页", point: nil)
            recordEvent(.key("home", t: 0))
        } else if mods.contains(.command) && mods.contains(.shift) && key == "r" {
            sender.sendRotate()
            reportInfo("旋转设备", point: nil)
            recordEvent(.key("rotate", t: 0))
        } else if event.keyCode == 53 || event.keyCode == 51 { // ESC / Backspace
            sender.sendBack()
            reportInfo("返回", point: nil)
            recordEvent(.key("back", t: 0))
        }
    }

    /// 向控制面板上报当前操作与坐标。
    private func reportInfo(_ operation: String, point: (Int32, Int32)?) {
        if let point {
            lastAbsPoint = point
        }
        let relX = deviceWidth > 0 ? Double(lastAbsPoint.0) / Double(deviceWidth) : 0
        let relY = deviceHeight > 0 ? Double(lastAbsPoint.1) / Double(deviceHeight) : 0
        controlInfoStore.update(.init(operation: operation,
                                      absX: lastAbsPoint.0,
                                      absY: lastAbsPoint.1,
                                      relX: relX,
                                      relY: relY))
    }

    /// 把电脑剪贴板内容设置到设备并执行粘贴。
    private func pasteComputerClipboard() {
        guard let sender = client?.controlSender else { return }
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else { return }
        sender.sendSetClipboard(text: text, paste: true)
    }

    /// 把设备剪贴板内容写入电脑剪贴板。
    private func setComputerClipboard(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    private func pointToDevice(_ p: NSPoint) -> (Int32, Int32)? {
        let size = videoView.bounds.size
        guard size.width > 0, size.height > 0, deviceWidth > 0, deviceHeight > 0 else { return nil }
        let x = Int32(p.x / size.width * CGFloat(deviceWidth))
        // AppKit 视图坐标系：原点在左下、y 向上；设备/视频坐标系：原点在左上、y 向下。
        // 因此 y 需要翻转，否则触摸位置会上下颠倒（表现为方向错乱）。
        let y = Int32((size.height - p.y) / size.height * CGFloat(deviceHeight))
        return (x, y)
    }

    private func handleVideoSize(width: UInt32, height: UInt32) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.classifier != nil && (self.deviceWidth != width || self.deviceHeight != height) {
                self.stopPlayback()
                self.showAlert("回放已停止", "视频尺寸或方向发生变化，请检查技能区域后重新运行。")
            }
            let first = !self.isPresented
            self.deviceWidth = width
            self.deviceHeight = height
            self.controlInfoStore.setDeviceSize(width: width, height: height)
            self.resizeWindowToDevice()
            if first {
                // 首次拿到尺寸，此时窗口已按正确大小设置好，再显示出来。
                self.isPresented = true
                self.window.makeKeyAndOrderFront(nil)
                self.window.makeFirstResponder(self.videoView)
                NSApp.activate(ignoringOtherApps: true)
                self.onReady?()
            }
        }
    }

    private func resizeWindowToDevice() {
        let w = CGFloat(deviceWidth)
        let h = CGFloat(deviceHeight)
        guard w > 0, h > 0 else { return }

        var size = NSSize(width: w, height: h)
        if let screen = window.screen ?? NSScreen.main {
            let visible = screen.visibleFrame
            let maxW = max(200, visible.width - 40)
            let maxH = max(200, visible.height - 80)
            let scale = min(1, min(maxW / w, maxH / h))
            size = NSSize(width: w * scale, height: h * scale)
        }

        window.contentAspectRatio = NSSize(width: w, height: h)
        window.setContentSize(size)
        window.center()
    }

    /// 处理控制面板发来的动作。
    func handleAction(_ action: ControlAction) {
        switch action {
        case .home:
            client?.controlSender?.sendHome()
            reportInfo("主页", point: nil)
            recordEvent(.key("home", t: 0))
        case .back:
            client?.controlSender?.sendBack()
            reportInfo("返回", point: nil)
            recordEvent(.key("back", t: 0))
        case .rotate:
            client?.controlSender?.sendRotate()
            reportInfo("旋转设备", point: nil)
            recordEvent(.key("rotate", t: 0))
        case .power:
            client?.controlSender?.sendPower()
            reportInfo("电源", point: nil)
            recordEvent(.key("power", t: 0))
        case .screenshot:
            takeScreenshot()
        case .record:
            toggleRecording()
        case .playback:
            openPlayback()
        }
    }

    private func takeScreenshot() {
        let serial = device.serial
        let adbPath = AppSettings.adbPath
        let dir = AppSettings.captureDirectory

        DispatchQueue.global().async { [weak self] in
            do {
                let data = try AdbClient(adbPath: adbPath).screencap(serial: serial)
                try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
                let name = "screenshot-\(formatter.string(from: Date())).png"
                let url = URL(fileURLWithPath: dir).appendingPathComponent(name)
                try data.write(to: url)

                DispatchQueue.main.async {
                    self?.reportInfo("截图已保存", point: nil)
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            } catch {
                DispatchQueue.main.async {
                    self?.reportInfo("截图失败", point: nil)
                    let alert = NSAlert()
                    alert.messageText = "截图失败"
                    alert.informativeText = error.localizedDescription
                    alert.alertStyle = .warning
                    alert.runModal()
                }
            }
        }
    }

    // MARK: - 脚本录制 / 回放

    /// 若正在录制，记录一条事件并带上相对开始的时间戳。
    private func recordEvent(_ event: ScriptEvent) {
        guard isRecording, let start = recordStartTime else { return }
        var e = event
        e.t = Date().timeIntervalSince(start)
        recordedEvents.append(e)
    }

    private func toggleRecording() {
        if isRecording {
            stopRecordingAndSave()
        } else {
            startRecording()
        }
    }

    /// 根据录制/回放状态组合窗口标题。
    private func updateWindowTitle() {
        if isRecording {
            window.title = "\(deviceName) - 脚本录制中"
        } else if isPlayingBack {
            window.title = "\(deviceName) - 脚本回放中"
        } else {
            window.title = deviceName
        }
    }

    private func startRecording() {
        stopPlayback()
        recordedEvents = []
        recordStartTime = Date()
        isRecording = true
        controlInfoStore.setRecording(true)
        updateWindowTitle()
    }

    private func stopRecordingAndSave() {
        guard isRecording else { return }
        isRecording = false
        controlInfoStore.setRecording(false)
        updateWindowTitle()

        let script = Script(version: 3, deviceWidth: deviceWidth, deviceHeight: deviceHeight,
                            events: recordedEvents)

        let panel = NSSavePanel()
        panel.title = "保存录制脚本"
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = defaultScriptName()
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            guard response == .OK, let url = panel.url else {
                return
            }
            do {
                try script.encoded().write(to: url)
            } catch {
                self.showAlert("保存失败", error.localizedDescription)
            }
        }
    }

    private func openPlayback() {
        if isPlayingBack { stopPlayback(); reportInfo("回放已停止", point: nil); return }
        guard !isRecording else { showAlert("回放失败", "请先结束录制。"); return }
        let panel = NSOpenPanel()
        panel.title = "选择回放脚本（再次点击回放可停止）"
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            guard response == .OK, let url = panel.url else { return }
            self.loadAndPlay(url)
        }
    }

    private func loadAndPlay(_ url: URL) {
        do {
            let script = try LoadedScript.load(from: url)
            if case .recording(let recording) = script { play(recording) }
            else { playFlow(script) }
            controlInfoStore.setRunningScriptName(url.lastPathComponent)
            reportInfo("回放中", point: nil)
            client?.log("[Replay] Running \(url.lastPathComponent)")
        } catch {
            showAlert("回放失败", error.localizedDescription)
        }
    }

    private func play(_ script: Script) {
        stopPlayback()
        isPlayingBack = true
        playbackGeneration += 1
        let generation = playbackGeneration
        updateWindowTitle()
        playCycle(script, remaining: script.playbackRepeatCount, generation: generation) { [weak self] in
            self?.isPlayingBack = false
            self?.controlInfoStore.setRunningScriptName(nil)
            self?.updateWindowTitle()
        }
    }

    private func playCycle(_ script: Script, remaining: Int, generation: Int,
                           completion: @escaping () -> Void) {
        let started = DispatchTime.now()
        let cycle = script.playbackRepeatCount - remaining + 1
        client?.log("[Replay v3 \(cycle)/\(script.playbackRepeatCount)] Starting \(script.events.count) events")
        for (index, event) in script.events.enumerated() {
            let nanos = Int(event.t * 1_000_000_000)
            DispatchQueue.main.asyncAfter(deadline: started + .nanoseconds(nanos)) { [weak self] in
                guard let self, self.playbackGeneration == generation, self.isPlayingBack else { return }
                self.executeEvent(event)
                let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1_000_000_000
                self.client?.log("[Replay v3 \(cycle)/\(script.playbackRepeatCount)] Event \(index + 1)/\(script.events.count): type=\(event.type), action=\(event.action ?? -1), scheduled=\(event.t)s, dispatched=\(elapsed)s")
            }
        }

        // Schedule only one cycle at a time, including the existing end-of-cycle margin.
        let maxT = script.events.map { $0.t }.max() ?? 0
        let finishAt = Int((maxT + 0.1) * 1_000_000_000)
        DispatchQueue.main.asyncAfter(deadline: started + .nanoseconds(finishAt)) { [weak self] in
            guard let self, self.playbackGeneration == generation, self.isPlayingBack else { return }
            if remaining > 1, !script.events.isEmpty {
                self.playCycle(script, remaining: remaining - 1, generation: generation, completion: completion)
            } else {
                completion()
            }
        }
    }

    private func stopPlayback() {
        if let point = playbackTouch {
            executeEvent(.touch(action: Int(ControlSender.actionUp), relX: point.0, relY: point.1, t: 0))
        }
        playbackGeneration += 1
        classifier?.stop()
        classifier = nil
        isPlayingBack = false
        controlInfoStore.setRunningScriptName(nil)
        controlInfoStore.setScriptRepeatProgress(nil)
        updateWindowTitle()
    }

    private func playFlow(_ script: LoadedScript) {
        stopPlayback()
        let worker = SkillClassifier()
        classifier = worker
        isPlayingBack = true
        let generation = playbackGeneration
        let project = AppSettings.classifierProjectPath
        updateWindowTitle()
        replayQueue.async { [weak self] in
            guard let self else { worker.cleanup(); return }
            var failure: String?
            do {
                try FileManager.default.createDirectory(at: worker.directory, withIntermediateDirectories: true)
                var classifierStarted = false
                let check = {
                    try DispatchQueue.main.sync {
                        guard self.playbackGeneration == generation, self.isPlayingBack,
                              !self.didFinish, !worker.isCancelled, self.client?.controlSender != nil else {
                            throw replayError("回放已停止或设备状态已变化。")
                        }
                    }
                }
                var runLoaded: ((LoadedScript, @escaping WorkflowCancellationCheck, Set<URL>) throws -> Void)!
                runLoaded = { loadedScript, inheritedCheck, ancestors in
                    let combinedCheck = {
                        try check()
                        try inheritedCheck()
                    }
                    let runner = FlowRunner(checkCancelled: combinedCheck, recording: { recording in
                        try self.playRecording(recording, generation: generation, checkCancelled: combinedCheck)
                    }, workflow: { loadedWorkflow in
                        let file = loadedWorkflow.file.standardizedFileURL.resolvingSymlinksInPath()
                        guard !ancestors.contains(file), ancestors.count < 64 else {
                            throw replayError("脚本循环引用或嵌套超过 64 层：\(file.path)")
                        }
                        let nextAncestors = ancestors.union([file])
                        let workflowRunner = WorkflowRunner(checkCancelled: combinedCheck, script: { name, localCheck in
                            let childURL = URL(fileURLWithPath: name, relativeTo: file.deletingLastPathComponent())
                            let child = try LoadedScript.load(from: childURL)
                            DispatchQueue.main.sync {
                                self.controlInfoStore.setRunningScriptName(childURL.lastPathComponent)
                                self.client?.log("[Workflow] Running \(childURL.lastPathComponent)")
                            }
                            defer {
                                DispatchQueue.main.sync {
                                    self.controlInfoStore.setRunningScriptName(file.lastPathComponent)
                                }
                            }
                            try runLoaded(child, localCheck, nextAncestors)
                        }, vision: { kind, roi, parameters, localCheck in
                            try localCheck()
                            if kind == .skillCheck {
                                guard parameters["model"] == .string("default"),
                                      parameters["threshold"] == .number(0) else {
                                    throw replayError("skill_check 当前仅支持 model=default 和 threshold=0。")
                                }
                                if !classifierStarted {
                                    DispatchQueue.main.sync { self.reportInfo("分类器加载中", point: nil) }
                                    try worker.start(project: project)
                                    classifierStarted = true
                                }
                            }
                            let workflowFrame = worker.directory.appendingPathComponent("workflow-\(UUID().uuidString).png")
                            defer { try? FileManager.default.removeItem(at: workflowFrame) }
                            let size = try self.decoder.saveCurrentFrame(to: workflowFrame)
                            guard roi[0] + roi[2] <= Double(size.0), roi[1] + roi[3] <= Double(size.1) else {
                                throw replayError("\(kind.rawValue) ROI 超出当前画面范围。")
                            }
                            try DispatchQueue.main.sync {
                                guard self.playbackGeneration == generation, self.isPlayingBack, !self.didFinish,
                                      self.client?.controlSender != nil,
                                      self.deviceWidth == UInt32(size.0), self.deviceHeight == UInt32(size.1) else {
                                    throw replayError("视频尺寸已变化，回放已停止。")
                                }
                            }
                            let normalized = [roi[0] / Double(size.0), roi[1] / Double(size.1),
                                              roi[2] / Double(size.0), roi[3] / Double(size.1)]
                            switch kind {
                            case .ocrText:
                                let text = try TextStopCondition(text: "_", region: normalized).recognize(in: workflowFrame)
                                try localCheck()
                                return .string(text)
                            case .skillCheck:
                                guard case .string(let skill) = parameters["skill"] else {
                                    throw replayError("skill_check 缺少 skill。")
                                }
                                let labels = try worker.classify(frame: workflowFrame, regions: [skill: normalized])
                                try localCheck()
                                guard let label = labels[skill], label == "useable" || label == "not_useable" else {
                                    throw replayError("分类器返回了缺失或未知的技能分类。")
                                }
                                return .object([
                                    "state": .string(label == "useable" ? "usable" : "unusable"),
                                    "confidence": .null,
                                    "box": .array(roi.map(JSONValue.number)),
                                    "point": .array([.number(roi[0] + roi[2] / 2),
                                                     .number(roi[1] + roi[3] / 2)])
                                ])
                            case .circlePercentage:
                                guard parameters["profile"] == .string("default") else {
                                    throw replayError("circle_percentage currently only supports profile=default.")
                                }
                                let percentage = try CirclePercentageDetector.percentage(in: workflowFrame, roi: roi)
                                try localCheck()
                                return .number(percentage)
                            case .templateMatch:
                                throw replayError("当前设备回放尚不支持 \(kind.rawValue)；需要对应的已校准视觉后端。")
                            }
                        }, touch: { point, action in
                            try DispatchQueue.main.sync {
                                guard self.playbackGeneration == generation, self.isPlayingBack, !self.didFinish,
                                      self.client?.controlSender != nil,
                                      point[0] < Double(self.deviceWidth), point[1] < Double(self.deviceHeight),
                                      self.deviceWidth > 0, self.deviceHeight > 0 else {
                                    throw replayError("触摸坐标超出范围或设备状态已变化。")
                                }
                                let x = point[0] / Double(self.deviceWidth)
                                let y = point[1] / Double(self.deviceHeight)
                                let eventAction: UInt8
                                switch action {
                                case .down: eventAction = ControlSender.actionDown
                                case .move: eventAction = ControlSender.actionMove
                                case .up: eventAction = ControlSender.actionUp
                                }
                                self.executeEvent(.touch(action: Int(eventAction), relX: x, relY: y, t: 0))
                                self.client?.log("[Workflow] Touch \(action.rawValue): pixel=(\(Int(point[0])), \(Int(point[1])))")
                            }
                        }, log: { message in
                            DispatchQueue.main.sync { self.client?.log(message) }
                        })
                        try workflowRunner.run(loadedWorkflow.workflow)
                    }, progress: { current, total in
                        DispatchQueue.main.sync {
                            guard self.playbackGeneration == generation, self.isPlayingBack else { return }
                            self.controlInfoStore.setScriptRepeatProgress("\(current)/\(total)")
                            self.client?.log("[Flow \(current)/\(total)] Starting sequence")
                        }
                    }, entryStarted: { entry in
                        DispatchQueue.main.sync {
                            guard self.playbackGeneration == generation, self.isPlayingBack else { return }
                            self.controlInfoStore.setRunningScriptName(entry.name)
                            self.reportInfo("回放中", point: nil)
                            self.client?.log("[Flow] Running \(entry.name), id=\(entry.id)")
                        }
                    })
                    try runner.run(loadedScript)
                }
                try runLoaded(script, check, [])
            } catch { failure = error.localizedDescription }
            worker.cleanup()
            let message = failure
            DispatchQueue.main.async { [weak self] in
                guard let self, self.playbackGeneration == generation, !self.didFinish else { return }
                self.stopPlayback()
                if let message { self.showAlert("回放失败", message) }
                else { self.reportInfo("流程回放完成", point: nil) }
            }
        }
    }

    private func playRecording(_ script: Script, generation: Int,
                               checkCancelled: WorkflowCancellationCheck) throws {
        guard !script.events.isEmpty else { return }
        defer {
            DispatchQueue.main.sync {
                guard self.playbackGeneration == generation, let point = self.playbackTouch else { return }
                self.executeEvent(.touch(action: Int(ControlSender.actionUp), relX: point.0, relY: point.1, t: 0))
            }
        }
        for cycle in 1...script.playbackRepeatCount {
            let started = DispatchTime.now()
            for (index, event) in script.events.enumerated() {
                try wait(until: started + event.t, checkCancelled: checkCancelled)
                try DispatchQueue.main.sync {
                    guard self.playbackGeneration == generation, self.isPlayingBack, !self.didFinish,
                          self.client?.controlSender != nil else {
                        throw replayError("回放已停止。")
                    }
                    self.executeEvent(event)
                    self.client?.log("[Replay v3 \(cycle)/\(script.playbackRepeatCount)] Event \(index + 1)/\(script.events.count)")
                }
            }
            let end = (script.events.map { $0.t }.max() ?? 0) + 0.1
            try wait(until: started + end, checkCancelled: checkCancelled)
        }
    }

    private func wait(until deadline: DispatchTime,
                      checkCancelled: WorkflowCancellationCheck) throws {
        while DispatchTime.now() < deadline {
            try checkCancelled()
            _ = DispatchSemaphore(value: 0).wait(timeout: min(deadline, .now() + 0.05))
        }
        try checkCancelled()
    }

    private func executeEvent(_ event: ScriptEvent) {
        guard let sender = client?.controlSender, deviceWidth > 0, deviceHeight > 0 else { return }
        switch event.type {
        case "touch":
            guard let action = event.action, (0...2).contains(action),
                  let relX = event.relX, let relY = event.relY,
                  relX.isFinite, relY.isFinite, (0...1).contains(relX), (0...1).contains(relY) else { return }
            playbackTouch = action == Int(ControlSender.actionUp) ? nil : (relX, relY)
            let x = min(Int32(deviceWidth) - 1, Int32(relX * Double(deviceWidth)))
            let y = min(Int32(deviceHeight) - 1, Int32(relY * Double(deviceHeight)))
            let actionButton: Int32 = (action == ControlSender.actionMove) ? 0 : 1
            let buttons: Int32 = (action == ControlSender.actionUp) ? 0 : 1
            sender.sendTouch(action: UInt8(action), x: x, y: y,
                             screenWidth: UInt16(deviceWidth), screenHeight: UInt16(deviceHeight),
                             actionButton: actionButton, buttons: buttons)
        case "scroll":
            guard let relX = event.relX, let relY = event.relY,
                  relX.isFinite, relY.isFinite, (0...1).contains(relX), (0...1).contains(relY) else { return }
            let x = Int32(relX * Double(deviceWidth))
            let y = Int32(relY * Double(deviceHeight))
            sender.sendScroll(x: x, y: y,
                              screenWidth: UInt16(deviceWidth), screenHeight: UInt16(deviceHeight),
                              hScroll: event.hScroll ?? 0, vScroll: event.vScroll ?? 0)
        case "key":
            switch event.key {
            case "home": sender.sendHome()
            case "back": sender.sendBack()
            case "rotate": sender.sendRotate()
            case "power": sender.sendPower()
            default: break
            }
        default:
            break
        }
    }

    private func defaultScriptName() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "script-\(formatter.string(from: Date())).json"
    }

    private func showAlert(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.beginSheetModal(for: window)
    }

    private func handleFailure(_ message: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.didFinish else { return }
            self.stopPlayback()
            let alert = NSAlert()
            alert.messageText = "连接失败"
            alert.informativeText = message
            alert.alertStyle = .warning
            if self.isPresented {
                // 窗口已显示：在窗口上弹 sheet，关闭后结束会话。
                alert.beginSheetModal(for: self.window) { _ in
                    self.window.close()
                }
            } else {
                // 窗口还没显示：用模态弹窗提示，结束后回到设备列表。
                alert.runModal()
                self.finish()
            }
        }
    }

    func windowWillClose(_ notification: Notification) {
        finish()
    }

    private func finish() {
        if didFinish { return }
        didFinish = true
        stopPlayback()
        client?.stop()

        // 解除窗口与 delegate 的关联，避免关闭流程中回调已释放的控制器。
        window.delegate = nil

        // 延后回调到下一个 runloop，避免在 windowWillClose 调用栈内释放 self（窗口 delegate），
        // 否则窗口关闭收尾阶段可能访问到已释放的 delegate 导致崩溃。
        let onEnded = self.onEnded
        self.onEnded = nil
        if let onEnded {
            DispatchQueue.main.async {
                onEnded()
            }
        }
    }
}
