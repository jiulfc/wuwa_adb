import AppKit

/// Settings window: pick the local ADB command location, the scrcpy-server path, and the screenshot save directory.
final class SettingsWindowController: NSObject {
    private let window: NSWindow
    private let adbField = NSTextField(string: "")
    private let serverField = NSTextField(string: "")
    private let classifierField = NSTextField(string: "")
    private let captureField = NSTextField(string: "")
    private let screenOffCheckbox = NSButton(checkboxWithTitle: "Turn off phone screen after connecting (applies to the next connection)", target: nil, action: nil)

    override init() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 330),
                          styleMask: [.titled, .closable],
                          backing: .buffered, defer: false)
        super.init()
        window.isReleasedWhenClosed = false
        configure()
    }

    private func configure() {
        window.title = "Settings"

        let adbLabel = NSTextField(labelWithString: "ADB Path")
        let serverLabel = NSTextField(labelWithString: "scrcpy-server Path")
        let classifierLabel = NSTextField(labelWithString: "wuwa_classify Project")
        let captureLabel = NSTextField(labelWithString: "Screenshot Directory")
        adbLabel.alignment = .right
        serverLabel.alignment = .right
        captureLabel.alignment = .right

        for field in [adbField, serverField, captureField, classifierField] {
            field.usesSingleLineMode = true
            field.lineBreakMode = .byTruncatingMiddle
        }

        let adbBrowse = NSButton(title: "Browse…", target: self, action: #selector(browseAdb))
        let serverBrowse = NSButton(title: "Browse…", target: self, action: #selector(browseServer))
        let captureBrowse = NSButton(title: "Browse…", target: self, action: #selector(browseCapture))

        let classifierBrowse = NSButton(title: "Browse…", target: self, action: #selector(browseClassifier))

        let grid = NSGridView(views: [
            [adbLabel, adbField, adbBrowse],
            [serverLabel, serverField, serverBrowse],
            [captureLabel, captureField, captureBrowse],
            [classifierLabel, classifierField, classifierBrowse],
        ])
        grid.rowSpacing = 14
        grid.columnSpacing = 8
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).xPlacement = .fill

        let saveButton = NSButton(title: "Save", target: self, action: #selector(save))
        saveButton.keyEquivalent = "\r"
        saveButton.bezelStyle = .rounded

        let content = window.contentView!
        content.addSubview(grid)
        content.addSubview(screenOffCheckbox)
        content.addSubview(saveButton)
        grid.translatesAutoresizingMaskIntoConstraints = false
        screenOffCheckbox.translatesAutoresizingMaskIntoConstraints = false
        saveButton.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
            grid.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            grid.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),

            adbField.widthAnchor.constraint(greaterThanOrEqualToConstant: 260),
            serverField.widthAnchor.constraint(greaterThanOrEqualToConstant: 260),
            captureField.widthAnchor.constraint(greaterThanOrEqualToConstant: 260),

            screenOffCheckbox.topAnchor.constraint(equalTo: grid.bottomAnchor, constant: 18),
            screenOffCheckbox.leadingAnchor.constraint(equalTo: grid.leadingAnchor),
            saveButton.topAnchor.constraint(equalTo: screenOffCheckbox.bottomAnchor, constant: 18),
            saveButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            saveButton.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -18),
        ])
    }

    func show() {
        adbField.stringValue = AppSettings.adbPath
        serverField.stringValue = AppSettings.serverPath
        captureField.stringValue = AppSettings.captureDirectory
        classifierField.stringValue = AppSettings.classifierProjectPath
        screenOffCheckbox.state = AppSettings.turnScreenOffOnConnect ? .on : .off
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func browseAdb() {
        pickFile(title: "Choose the ADB executable", into: adbField)
    }

    @objc private func browseServer() {
        pickFile(title: "Choose the scrcpy-server file", into: serverField)
    }

    @objc private func browseCapture() {
        let panel = NSOpenPanel()
        panel.title = "Choose screenshot directory"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.beginSheetModal(for: window) { response in
            if response == .OK, let url = panel.url {
                self.captureField.stringValue = url.path
            }
        }
    }

    @objc private func browseClassifier() {
        let panel = NSOpenPanel()
        panel.title = "Choose the wuwa_classify project directory"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.beginSheetModal(for: window) { response in
            if response == .OK, let url = panel.url { self.classifierField.stringValue = url.path }
        }
    }

    private func pickFile(title: String, into field: NSTextField) {
        let panel = NSOpenPanel()
        panel.title = title
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.beginSheetModal(for: window) { response in
            if response == .OK, let url = panel.url {
                field.stringValue = url.path
            }
        }
    }

    @objc private func save() {
        AppSettings.adbPath = adbField.stringValue
        AppSettings.serverPath = serverField.stringValue
        AppSettings.captureDirectory = captureField.stringValue
        AppSettings.classifierProjectPath = classifierField.stringValue
        AppSettings.turnScreenOffOnConnect = screenOffCheckbox.state == .on
        window.close()
    }
}
