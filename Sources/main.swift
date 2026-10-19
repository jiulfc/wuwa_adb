import AppKit

// Parse command-line arguments (mainly for debugging: --mirror <serial> mirrors the given device directly).
let arguments = CommandLine.arguments
let mirrorSerial: String? = {
    if let idx = arguments.firstIndex(of: "--mirror"), idx + 1 < arguments.count {
        return arguments[idx + 1]
    }
    return nil
}()

// Early startup logging, to help diagnose behavior when launched via `open`.
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
earlyLog("Startup, args=\(arguments), mirrorSerial=\(mirrorSerial ?? "nil")")

// App entry point: set up NSApplication manually so the menu bar and windows work even without an .app bundle.
let app = NSApplication.shared
let delegate = AppDelegate(mirrorSerial: mirrorSerial)
app.delegate = delegate
app.setActivationPolicy(.regular)

let mainMenu = NSMenu()

// App menu
let appMenuItem = NSMenuItem()
mainMenu.addItem(appMenuItem)
let appMenu = NSMenu()
appMenu.addItem(withTitle: "About Adb Quick",
                action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                keyEquivalent: "")
appMenu.addItem(.separator())

let settingsItem = NSMenuItem(title: "Settings…",
                              action: #selector(AppDelegate.openSettings),
                              keyEquivalent: ",")
settingsItem.target = delegate
appMenu.addItem(settingsItem)
appMenu.addItem(.separator())

appMenu.addItem(withTitle: "Quit Adb Quick",
                action: #selector(NSApplication.terminate(_:)),
                keyEquivalent: "q")
appMenuItem.submenu = appMenu

// View menu
let viewMenuItem = NSMenuItem()
mainMenu.addItem(viewMenuItem)
let viewMenu = NSMenu(title: "View")
let controlPanelItem = NSMenuItem(title: "Control Panel",
                                  action: #selector(AppDelegate.toggleControlPanel),
                                  keyEquivalent: "k")
controlPanelItem.target = delegate
viewMenu.addItem(controlPanelItem)
let debugItem = NSMenuItem(title: "Debug", action: #selector(AppDelegate.openDebug), keyEquivalent: "")
debugItem.target = delegate
viewMenu.addItem(debugItem)
let orchestrationItem = NSMenuItem(title: "Flow Orchestrator",
                                   action: #selector(AppDelegate.openOrchestration),
                                   keyEquivalent: "o")
orchestrationItem.target = delegate
viewMenu.addItem(orchestrationItem)
viewMenuItem.submenu = viewMenu

// Window menu
let windowMenuItem = NSMenuItem()
mainMenu.addItem(windowMenuItem)
let windowMenu = NSMenu(title: "Window")
windowMenu.addItem(withTitle: "Minimize",
                   action: #selector(NSWindow.performMiniaturize(_:)),
                   keyEquivalent: "m")
windowMenu.addItem(withTitle: "Zoom",
                   action: #selector(NSWindow.performZoom(_:)),
                   keyEquivalent: "")
windowMenu.addItem(.separator())
windowMenu.addItem(withTitle: "Bring All to Front",
                   action: #selector(NSApplication.arrangeInFront(_:)),
                   keyEquivalent: "")
windowMenuItem.submenu = windowMenu
app.windowsMenu = windowMenu

app.mainMenu = mainMenu
app.run()
