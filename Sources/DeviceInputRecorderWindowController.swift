import AppKit
import UniformTypeIdentifiers

final class DeviceInputRecorderWindowController: NSObject, NSWindowDelegate {
    private let window: NSWindow
    private let deviceLabel = NSTextField(labelWithString: "Device: —")
    private let statusLabel = NSTextField(
        wrappingLabelWithString: "Connect a mirrored device to begin.")
    private let recordButton = NSButton(title: "Record Device", target: nil, action: nil)
    private let stopButton = NSButton(title: "Stop", target: nil, action: nil)
    private let saveButton = NSButton(title: "Save Script…", target: nil, action: nil)
    private let replayButton = NSButton(title: "Replay", target: nil, action: nil)
    private let targetProvider: () -> InputRecordingTarget?
    private let prepareDevice: () -> Void
    private let replay: (Script) throws -> Void
    private var recorder: ADBInputRecorder?
    private var recordedScript: Script?
    private var recordedSerial: String?
    private var isRecording = false

    init(
        targetProvider: @escaping () -> InputRecordingTarget?,
        prepareDevice: @escaping () -> Void,
        replay: @escaping (Script) throws -> Void
    ) {
        self.targetProvider = targetProvider
        self.prepareDevice = prepareDevice
        self.replay = replay
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 210),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered, defer: false)
        super.init()
        window.isReleasedWhenClosed = false
        configure()
    }

    private func configure() {
        window.title = "Device Input Recorder"
        window.delegate = self

        let title = NSTextField(labelWithString: "Physical Device Input")
        title.font = .boldSystemFont(ofSize: 15)
        let help = NSTextField(
            wrappingLabelWithString:
                "Records touches made directly on the Android device with adb getevent. Mirror-window clicks are not captured."
        )
        help.textColor = .secondaryLabelColor
        statusLabel.textColor = .secondaryLabelColor

        recordButton.target = self
        recordButton.action = #selector(startRecording)
        stopButton.target = self
        stopButton.action = #selector(stopRecording)
        saveButton.target = self
        saveButton.action = #selector(saveScript)
        replayButton.target = self
        replayButton.action = #selector(replayScript)

        let buttons = NSStackView(views: [
            recordButton, stopButton, saveButton, replayButton, NSView(),
        ])
        buttons.orientation = .horizontal
        buttons.spacing = 8

        let content = window.contentView!
        for view in [title, help, deviceLabel, statusLabel, buttons] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            title.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            help.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 8),
            help.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            help.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            deviceLabel.topAnchor.constraint(equalTo: help.bottomAnchor, constant: 14),
            deviceLabel.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            statusLabel.topAnchor.constraint(equalTo: deviceLabel.bottomAnchor, constant: 7),
            statusLabel.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            statusLabel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            buttons.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            buttons.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            buttons.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
        ])
        render()
    }

    func show() {
        render()
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func startRecording() {
        guard !isRecording, let target = targetProvider() else {
            statusLabel.stringValue = "Connect a mirrored device before recording."
            return
        }
        prepareDevice()
        recordedScript = nil
        recordedSerial = nil
        isRecording = true
        statusLabel.stringValue = "Finding the device touchscreen and orientation…"
        let recorder = ADBInputRecorder(adbPath: AppSettings.adbPath, target: target)
        self.recorder = recorder
        render()

        recorder.start(
            onStarted: { [weak self] device, rotation in
                DispatchQueue.main.async {
                    self?.statusLabel.stringValue =
                        "Recording physical touches from \(device.path) · rotation \(rotation)"
                }
            },
            onEventCount: { [weak self] count in
                DispatchQueue.main.async {
                    self?.statusLabel.stringValue = "Recording physical touches · \(count) events"
                }
            },
            completion: { [weak self] result in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.recorder = nil
                    self.isRecording = false
                    switch result {
                    case .success(let script):
                        if let current = self.targetProvider(), current.serial == target.serial,
                            current.width == target.width, current.height == target.height
                        {
                            self.recordedScript = script
                            self.recordedSerial = target.serial
                            self.statusLabel.stringValue =
                                script.events.isEmpty
                                ? "Stopped · no device touches recorded"
                                : "Stopped · \(script.events.count) events ready to save or replay"
                        } else {
                            self.statusLabel.stringValue =
                                "Recording discarded because the device or orientation changed."
                        }
                    case .failure(let error):
                        self.statusLabel.stringValue =
                            "Recording failed: \(error.localizedDescription)"
                    }
                    self.render()
                }
            })
    }

    @objc private func stopRecording() {
        guard isRecording else { return }
        statusLabel.stringValue = "Stopping…"
        recorder?.stop()
    }

    @objc private func saveScript() {
        guard let script = recordedScript, !script.events.isEmpty else { return }
        let panel = NSSavePanel()
        panel.title = "Save Device Input Script"
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = defaultScriptName()
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try script.encoded().write(to: url)
                self?.statusLabel.stringValue = "Saved \(url.lastPathComponent)"
            } catch {
                self?.showAlert("Save Failed", error.localizedDescription)
            }
        }
    }

    @objc private func replayScript() {
        guard let script = recordedScript, !script.events.isEmpty,
            targetProvider()?.serial == recordedSerial
        else { return }
        do {
            try replay(script)
            statusLabel.stringValue =
                "Replaying \(script.events.count) events in the mirror session"
        } catch {
            showAlert("Replay Failed", error.localizedDescription)
        }
    }

    private func render() {
        if let target = targetProvider() {
            deviceLabel.stringValue = "Device: \(target.name)  (\(target.width) × \(target.height))"
        } else {
            deviceLabel.stringValue = "Device: —"
        }
        recordButton.isEnabled = !isRecording && targetProvider() != nil
        stopButton.isEnabled = isRecording
        saveButton.isEnabled = !isRecording && !(recordedScript?.events.isEmpty ?? true)
        replayButton.isEnabled = saveButton.isEnabled && targetProvider()?.serial == recordedSerial
    }

    private func defaultScriptName() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "device-input-\(formatter.string(from: Date())).json"
    }

    private func showAlert(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.beginSheetModal(for: window)
    }

    func windowWillClose(_ notification: Notification) {
        recorder?.stop()
    }
}
