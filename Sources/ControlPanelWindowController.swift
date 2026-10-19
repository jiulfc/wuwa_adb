import AppKit

/// Actions supported by the control panel.
enum ControlAction: Int {
    case home = 0
    case back = 1
    case rotate = 2
    case power = 3
    case screenshot = 4
    case record = 5
    case playback = 6
}

/// Info for one control operation: operation name + absolute coordinates (device pixels) + relative coordinates (0~1).
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
    var selectedScriptName: String?
    var currentStep: String?
    var variables: [String: JSONValue] = [:]
    var latestWorkflowMessage: String?
    var playbackStatus = "Idle"
    var onChange: (() -> Void)?

    func updateWorkflowDebug(script: String, step: String, variables: [String: JSONValue]) -> Bool {
        let changed = runningScriptName != script || self.variables != variables || currentStep == nil
        setRunningScriptName(script)
        currentStep = step
        self.variables = variables
        return changed
    }

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
        guard runningScriptName != name else { return }
        currentStep = nil
        variables = [:]
        runningScriptName = name
        onChange?()
    }
}

/// Control panel window: shows device info, offers common action buttons, and can float on top.
final class ControlPanelWindowController: NSObject, NSWindowDelegate {
    private let window: NSWindow
    private let deviceLabel = NSTextField(labelWithString: "Device: —")
    private let pinButton = NSButton(checkboxWithTitle: "Always on Top", target: nil, action: nil)
    private let recordButton = NSButton()
    private let store: ControlInfoStore

    var onAction: ((ControlAction) -> Void)?

    init(store: ControlInfoStore) {
        self.store = store
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 180),
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
        window.title = "Control Panel"
        window.delegate = self

        let titleLabel = NSTextField(labelWithString: "Control Panel")
        titleLabel.font = .boldSystemFont(ofSize: 14)

        pinButton.target = self
        pinButton.action = #selector(togglePin)

        deviceLabel.font = .systemFont(ofSize: 13)
        // Action buttons (first row: device actions)
        let deviceActions: [(String, ControlAction)] = [
            ("Home", .home), ("Back", .back), ("Rotate", .rotate), ("Power", .power), ("Screenshot", .screenshot),
        ]
        let deviceButtons = deviceActions.map { (title, action) -> NSButton in
            let b = NSButton(title: title, target: self, action: #selector(actionTapped(_:)))
            b.bezelStyle = .rounded
            b.controlSize = .small
            b.font = .systemFont(ofSize: 11)
            b.tag = action.rawValue
            return b
        }
        let deviceStack = NSStackView(views: deviceButtons)
        deviceStack.orientation = .horizontal
        deviceStack.distribution = .fillEqually
        deviceStack.spacing = 4

        // Action buttons (second row: scripts)
        recordButton.title = "Record"
        recordButton.bezelStyle = .rounded
        recordButton.font = .systemFont(ofSize: 11)
        recordButton.target = self
        recordButton.action = #selector(actionTapped(_:))
        recordButton.tag = ControlAction.record.rawValue
        let playbackButton = NSButton(title: "Playback", target: self, action: #selector(actionTapped(_:)))
        playbackButton.bezelStyle = .rounded
        playbackButton.font = .systemFont(ofSize: 11)
        playbackButton.tag = ControlAction.playback.rawValue
        let scriptStack = NSStackView(views: [recordButton, playbackButton, NSView()])
        scriptStack.orientation = .horizontal
        scriptStack.distribution = .fill
        scriptStack.spacing = 8

        let content = window.contentView!
        let subviews: [NSView] = [titleLabel, pinButton, deviceLabel, deviceStack, scriptStack]
        for v in subviews {
            v.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(v)
        }
        NSLayoutConstraint.activate([
            recordButton.widthAnchor.constraint(equalTo: deviceButtons[0].widthAnchor),
            playbackButton.widthAnchor.constraint(equalTo: deviceButtons[0].widthAnchor),

            titleLabel.topAnchor.constraint(equalTo: content.topAnchor, constant: 14),
            titleLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),

            pinButton.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            pinButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),

            deviceLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 12),
            deviceLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),

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
            deviceLabel.stringValue = "Device: —"
        } else {
            deviceLabel.stringValue = "Device: \(store.deviceName)  (\(store.deviceWidth) × \(store.deviceHeight))"
        }
        recordButton.title = store.isRecording ? "Stop" : "Record"
    }

    /// Opens or closes the control panel.
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
