import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let deviceListController = DeviceListWindowController()
    private let settingsController = SettingsWindowController()
    private let controlInfoStore = ControlInfoStore()
    private lazy var controlPanelController = ControlPanelWindowController(store: controlInfoStore)
    private lazy var orchestrationController = OrchestrationWindowController()
    private var streamingController: StreamingWindowController?
    private let mirrorSerial: String?

    init(mirrorSerial: String? = nil) {
        self.mirrorSerial = mirrorSerial
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        applyAppIcon()
        NSApp.activate(ignoringOtherApps: true)
        deviceListController.setOnSelect { [weak self] device in
            self?.startStreaming(device: device)
        }

        if let mirrorSerial {
            // 调试模式：直接镜像指定 serial 的设备。
            let device = Device(serial: mirrorSerial, state: "device", model: nil, product: nil, transport: nil)
            startStreaming(device: device)
        } else {
            deviceListController.show()
        }
    }

    /// 主动设置 Dock 图标，避免 LaunchServices 图标缓存导致显示成通用图标。
    private func applyAppIcon() {
        var icon: NSImage?
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns") {
            icon = NSImage(contentsOf: url)
        }
        if icon == nil {
            // 直接运行可执行文件（非 .app）时，回退到同目录 assets。
            let exeDir = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
            icon = NSImage(contentsOf: exeDir.appendingPathComponent("assets/AppIcon.icns"))
                ?? NSImage(contentsOf: exeDir.appendingPathComponent("assets/icon.png"))
        }
        if let icon {
            NSApp.applicationIconImage = icon
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }

    @objc func openSettings() {
        settingsController.show()
    }

    @objc func toggleControlPanel() {
        controlPanelController.toggle()
    }

    @objc func openOrchestration() {
        orchestrationController.show()
    }

    private func startStreaming(device: Device) {
        let controller = StreamingWindowController(device: device, controlInfoStore: controlInfoStore)
        controller.onReady = { [weak self] in
            // 视频尺寸已就绪、渲染窗口已按正确大小显示，再关闭设备列表。
            self?.deviceListController.close()
        }
        controller.onEnded = { [weak self] in
            self?.streamingController = nil
            self?.deviceListController.show()
        }
        streamingController = controller
        deviceListController.showConnecting("正在连接 \(device.displayName)…")

        // 控制面板的动作按钮路由到当前会话。
        controlPanelController.onAction = { [weak self] action in
            self?.streamingController?.handleAction(action)
        }

        // 设备列表保持显示，等 onReady 后再关闭，避免渲染窗口先小后大的跳变。
        controller.start()
    }
}
