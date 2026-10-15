import AppKit

/// 设置窗口：选择本地 ADB 命令位置、scrcpy-server 路径，以及截图保存目录。
final class SettingsWindowController: NSObject {
    private let window: NSWindow
    private let adbField = NSTextField(string: "")
    private let serverField = NSTextField(string: "")
    private let classifierField = NSTextField(string: "")
    private let captureField = NSTextField(string: "")
    private let screenOffCheckbox = NSButton(checkboxWithTitle: "连接后关闭手机屏幕（下次连接生效）", target: nil, action: nil)

    override init() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 330),
                          styleMask: [.titled, .closable],
                          backing: .buffered, defer: false)
        super.init()
        window.isReleasedWhenClosed = false
        configure()
    }

    private func configure() {
        window.title = "设置"

        let adbLabel = NSTextField(labelWithString: "ADB 路径")
        let serverLabel = NSTextField(labelWithString: "scrcpy-server 路径")
        let classifierLabel = NSTextField(labelWithString: "wuwa_classify 项目")
        let captureLabel = NSTextField(labelWithString: "截图保存目录")
        adbLabel.alignment = .right
        serverLabel.alignment = .right
        captureLabel.alignment = .right

        for field in [adbField, serverField, captureField, classifierField] {
            field.usesSingleLineMode = true
            field.lineBreakMode = .byTruncatingMiddle
        }

        let adbBrowse = NSButton(title: "浏览…", target: self, action: #selector(browseAdb))
        let serverBrowse = NSButton(title: "浏览…", target: self, action: #selector(browseServer))
        let captureBrowse = NSButton(title: "浏览…", target: self, action: #selector(browseCapture))

        let classifierBrowse = NSButton(title: "浏览…", target: self, action: #selector(browseClassifier))

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

        let saveButton = NSButton(title: "保存", target: self, action: #selector(save))
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
        pickFile(title: "选择 ADB 可执行文件", into: adbField)
    }

    @objc private func browseServer() {
        pickFile(title: "选择 scrcpy-server 文件", into: serverField)
    }

    @objc private func browseCapture() {
        let panel = NSOpenPanel()
        panel.title = "选择截图保存目录"
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
        panel.title = "选择 wuwa_classify 项目目录"
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
