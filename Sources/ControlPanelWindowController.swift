import AppKit

/// 控制面板支持的动作。
enum ControlAction: Int {
    case home = 0
    case back = 1
    case rotate = 2
    case power = 3
    case screenshot = 4
    case record = 5
    case playback = 6
}

/// 一次控制操作的信息：操作名 + 绝对坐标（设备像素）+ 相对坐标（0~1）。
final class ControlInfoStore {
    struct Entry {
        let operation: String
        let absX: Int32
        let absY: Int32
        let relX: Double
        let relY: Double
    }

    private(set) var deviceName: String = ""
    private(set) var deviceWidth: UInt32 = 0
    private(set) var deviceHeight: UInt32 = 0
    private(set) var current: Entry?
    private(set) var isRecording = false
    private(set) var runningScriptName: String?
    private(set) var scriptRepeatProgress: String?
    var onChange: (() -> Void)?

    func setDeviceName(_ name: String) {
        deviceName = name
        onChange?()
    }

    func setDeviceSize(width: UInt32, height: UInt32) {
        deviceWidth = width
        deviceHeight = height
        onChange?()
    }

    func update(_ entry: Entry) {
        current = entry
        onChange?()
    }

    func setRecording(_ recording: Bool) {
        isRecording = recording
        onChange?()
    }

    func setScriptRepeatProgress(_ progress: String?) {
        scriptRepeatProgress = progress
        onChange?()
    }

    func setRunningScriptName(_ name: String?) {
        runningScriptName = name
        onChange?()
    }
}

/// 控制面板窗口：显示设备信息、当前操作与坐标，提供常用动作按钮，支持固定在最上方。
final class ControlPanelWindowController: NSObject, NSWindowDelegate {
    private let window: NSWindow
    private let deviceLabel = NSTextField(labelWithString: "设备: —")
    private let operationLabel = NSTextField(labelWithString: "无操作")
    private let absLabel = NSTextField(labelWithString: "绝对坐标: —")
    private let relLabel = NSTextField(labelWithString: "相对坐标: —")
    private let pinButton = NSButton(checkboxWithTitle: "置顶", target: nil, action: nil)
    private let recordButton = NSButton()
    private let store: ControlInfoStore

    var onAction: ((ControlAction) -> Void)?

    init(store: ControlInfoStore) {
        self.store = store
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 334),
                          styleMask: [.titled, .closable],
                          backing: .buffered, defer: false)
        super.init()
        window.isReleasedWhenClosed = false
        configure()

        store.onChange = { [weak self] in
            DispatchQueue.main.async { self?.render() }
        }
        render()
    }

    private func configure() {
        window.title = "控制面板"
        window.delegate = self

        let titleLabel = NSTextField(labelWithString: "控制面板")
        titleLabel.font = .boldSystemFont(ofSize: 14)

        pinButton.target = self
        pinButton.action = #selector(togglePin)

        deviceLabel.font = .systemFont(ofSize: 13)
        operationLabel.font = .systemFont(ofSize: 13)
        operationLabel.lineBreakMode = .byWordWrapping
        operationLabel.maximumNumberOfLines = 3
        absLabel.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        relLabel.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        relLabel.textColor = .secondaryLabelColor

        // 动作按钮（第一行：设备操作）
        let deviceActions: [(String, ControlAction)] = [
            ("主页", .home), ("返回", .back), ("旋转", .rotate), ("电源", .power), ("截图", .screenshot),
        ]
        let deviceButtons = deviceActions.map { (title, action) -> NSButton in
            let b = NSButton(title: title, target: self, action: #selector(actionTapped(_:)))
            b.bezelStyle = .rounded
            b.tag = action.rawValue
            return b
        }
        let deviceStack = NSStackView(views: deviceButtons)
        deviceStack.orientation = .horizontal
        deviceStack.distribution = .fillEqually
        deviceStack.spacing = 8

        // 动作按钮（第二行：脚本）
        recordButton.title = "录制"
        recordButton.bezelStyle = .rounded
        recordButton.target = self
        recordButton.action = #selector(actionTapped(_:))
        recordButton.tag = ControlAction.record.rawValue
        let playbackButton = NSButton(title: "回放", target: self, action: #selector(actionTapped(_:)))
        playbackButton.bezelStyle = .rounded
        playbackButton.tag = ControlAction.playback.rawValue
        // 用等宽占位视图，让「录制/回放」与第一行按钮保持同样宽度（各占 1/5）。
        let scriptStack = NSStackView(views: [recordButton, playbackButton, NSView(), NSView(), NSView()])
        scriptStack.orientation = .horizontal
        scriptStack.distribution = .fillEqually
        scriptStack.spacing = 8

        let content = window.contentView!
        let subviews: [NSView] = [titleLabel, pinButton, deviceLabel, operationLabel, absLabel, relLabel, deviceStack, scriptStack]
        for v in subviews {
            v.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(v)
        }
        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: content.topAnchor, constant: 14),
            titleLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),

            pinButton.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            pinButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),

            deviceLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 12),
            deviceLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),

            operationLabel.topAnchor.constraint(equalTo: deviceLabel.bottomAnchor, constant: 8),
            operationLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            operationLabel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),

            absLabel.topAnchor.constraint(equalTo: operationLabel.bottomAnchor, constant: 8),
            absLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),

            relLabel.topAnchor.constraint(equalTo: absLabel.bottomAnchor, constant: 8),
            relLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),

            deviceStack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            deviceStack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            deviceStack.bottomAnchor.constraint(equalTo: scriptStack.topAnchor, constant: -8),
            deviceStack.heightAnchor.constraint(equalToConstant: 28),

            scriptStack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            scriptStack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            scriptStack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14),
            scriptStack.heightAnchor.constraint(equalToConstant: 28),
        ])
    }

    @objc private func togglePin() {
        window.level = (pinButton.state == .on) ? .floating : .normal
    }

    @objc private func actionTapped(_ sender: NSButton) {
        if let action = ControlAction(rawValue: sender.tag) {
            onAction?(action)
        }
    }

    private func render() {
        if store.deviceName.isEmpty {
            deviceLabel.stringValue = "设备: —"
        } else {
            deviceLabel.stringValue = "设备: \(store.deviceName)  (\(store.deviceWidth) × \(store.deviceHeight))"
        }
        recordButton.title = store.isRecording ? "停止" : "录制"
        let operation = store.current?.operation ?? "无操作"
        operationLabel.stringValue = [
            store.runningScriptName.map { "script: \($0)" },
            store.scriptRepeatProgress.map { "round: \($0)" },
            operation,
        ].compactMap { $0 }.joined(separator: " · ")
        operationLabel.toolTip = operationLabel.stringValue

        guard let entry = store.current else {
            absLabel.stringValue = "绝对坐标: —"
            relLabel.stringValue = "相对坐标: —"
            return
        }
        absLabel.stringValue = String(format: "绝对坐标: (%d, %d)", entry.absX, entry.absY)
        relLabel.stringValue = "相对坐标: (\(fmt(entry.relX)), \(fmt(entry.relY)))"
    }

    private func fmt(_ v: Double) -> String {
        if v == 0 { return "0" }
        var s = String(format: "%.3f", v)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s
    }

    /// 打开/关闭控制面板。
    func toggle() {
        if window.isVisible {
            window.orderOut(nil)
        } else {
            show()
        }
    }

    func show() {
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
