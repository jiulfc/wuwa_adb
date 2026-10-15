import AppKit

// 解析命令行参数（主要用于调试：--mirror <serial> 直接镜像指定设备）。
let arguments = CommandLine.arguments
let mirrorSerial: String? = {
    if let idx = arguments.firstIndex(of: "--mirror"), idx + 1 < arguments.count {
        return arguments[idx + 1]
    }
    return nil
}()

// 启动早期日志，便于排查 open 启动环境下的行为。
func earlyLog(_ message: String) {
    let line = "[startup] \(message)"
    let url = URL(fileURLWithPath: "/tmp/adbquick.log")
    let data = (line + "\n").data(using: .utf8) ?? Data()
    if let handle = try? FileHandle(forWritingTo: url) {
        handle.seekToEndOfFile()
        handle.write(data)
        try? handle.close()
    } else {
        try? data.write(to: url, options: .atomic)
    }
}
earlyLog("启动, args=\(arguments), mirrorSerial=\(mirrorSerial ?? "nil")")

// 应用入口：手动搭建 NSApplication，保证无 .app 包裹也能正常显示菜单栏与窗口。
let app = NSApplication.shared
let delegate = AppDelegate(mirrorSerial: mirrorSerial)
app.delegate = delegate
app.setActivationPolicy(.regular)

let mainMenu = NSMenu()

// 应用菜单
let appMenuItem = NSMenuItem()
mainMenu.addItem(appMenuItem)
let appMenu = NSMenu()
appMenu.addItem(withTitle: "关于 Adb Quick",
                action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                keyEquivalent: "")
appMenu.addItem(.separator())

let settingsItem = NSMenuItem(title: "设置…",
                              action: #selector(AppDelegate.openSettings),
                              keyEquivalent: ",")
settingsItem.target = delegate
appMenu.addItem(settingsItem)
appMenu.addItem(.separator())

appMenu.addItem(withTitle: "退出 Adb Quick",
                action: #selector(NSApplication.terminate(_:)),
                keyEquivalent: "q")
appMenuItem.submenu = appMenu

// 视图菜单
let viewMenuItem = NSMenuItem()
mainMenu.addItem(viewMenuItem)
let viewMenu = NSMenu(title: "视图")
let controlPanelItem = NSMenuItem(title: "控制面板",
                                  action: #selector(AppDelegate.toggleControlPanel),
                                  keyEquivalent: "k")
controlPanelItem.target = delegate
viewMenu.addItem(controlPanelItem)
let orchestrationItem = NSMenuItem(title: "流程编排器",
                                   action: #selector(AppDelegate.openOrchestration),
                                   keyEquivalent: "o")
orchestrationItem.target = delegate
viewMenu.addItem(orchestrationItem)
viewMenuItem.submenu = viewMenu

// 窗口菜单
let windowMenuItem = NSMenuItem()
mainMenu.addItem(windowMenuItem)
let windowMenu = NSMenu(title: "窗口")
windowMenu.addItem(withTitle: "最小化",
                   action: #selector(NSWindow.performMiniaturize(_:)),
                   keyEquivalent: "m")
windowMenu.addItem(withTitle: "缩放",
                   action: #selector(NSWindow.performZoom(_:)),
                   keyEquivalent: "")
windowMenu.addItem(.separator())
windowMenu.addItem(withTitle: "前置全部窗口",
                   action: #selector(NSApplication.arrangeInFront(_:)),
                   keyEquivalent: "")
windowMenuItem.submenu = windowMenu
app.windowsMenu = windowMenu

app.mainMenu = mainMenu
app.run()
