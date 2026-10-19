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
            // Debug mode: directly mirror the device with the given serial.
            let device = Device(serial: mirrorSerial, state: "device", model: nil, product: nil, transport: nil)
            startStreaming(device: device)
        } else {
            deviceListController.show()
        }
    }

    /// Sets the Dock icon proactively so a stale LaunchServices icon cache can't show the generic icon.
    private func applyAppIcon() {
        var icon: NSImage?
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns") {
            icon = NSImage(contentsOf: url)
        }
        if icon == nil {
            // When running the bare executable (not the .app), fall back to the assets folder next to it.
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
            // Close the device list only after the video size is ready and the render window is shown at the correct size.
            self?.deviceListController.close()
        }
        controller.onEnded = { [weak self] in
            self?.streamingController = nil
            self?.deviceListController.show()
        }
        streamingController = controller
        deviceListController.showConnecting("Connecting to \(device.displayName)…")

        // Route the control panel action buttons to the current session.
        controlPanelController.onAction = { [weak self] action in
            self?.streamingController?.handleAction(action)
        }

        // Keep the device list visible until onReady fires, avoiding the render window jumping from small to large.
        controller.start()
    }
}
