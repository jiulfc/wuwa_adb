import Foundation

/// One connected ADB device.
struct Device {
    let serial: String
    let state: String
    let model: String?
    let product: String?
    let transport: String?
    var deviceName: String?
    var androidVersion: String?
    var resolution: String?

    var displayName: String {
        if let deviceName, !deviceName.isEmpty { return deviceName }
        if let model, !model.isEmpty { return model }
        if let product, !product.isEmpty { return product }
        return serial
    }

    var subtitle: String {
        var parts: [String] = []
        // Model: shown only when a distinct device name exists, to avoid duplicating the title
        if let deviceName, !deviceName.isEmpty,
           let model, !model.isEmpty, model != deviceName {
            parts.append(model)
        }
        if let androidVersion, !androidVersion.isEmpty {
            parts.append("Android \(androidVersion)")
        }
        if let resolution, !resolution.isEmpty {
            parts.append(resolution)
        }
        if parts.isEmpty { return serial }
        return parts.joined(separator: " · ")
    }
}

enum AdbError: LocalizedError {
    case commandFailed(String)
    case serverNotFound

    var errorDescription: String? {
        switch self {
        case .commandFailed(let message):
            return message.isEmpty ? "Command failed" : message
        case .serverNotFound:
            return "scrcpy-server not found; specify its path in Settings"
        }
    }
}

/// App settings, persisted with UserDefaults.
enum AppSettings {
    private static let adbPathKey = "adbPath"
    private static let serverPathKey = "scrcpyServerPath"
    static var turnScreenOffOnConnect: Bool {
        get { UserDefaults.standard.object(forKey: "turnScreenOffOnConnect") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "turnScreenOffOnConnect") }
    }

    static var classifierProjectPath: String {
        get {
            if let value = UserDefaults.standard.string(forKey: "classifierProjectPath"), !value.isEmpty { return value }
            let bundle = Bundle.main.bundleURL
            let project = bundle.pathExtension == "app" ? bundle.deletingLastPathComponent() : bundle
            return project.deletingLastPathComponent().appendingPathComponent("wuwa_classify").path
        }
        set { UserDefaults.standard.set(newValue, forKey: "classifierProjectPath") }
    }

    private static let captureDirKey = "captureDirectory"

    static var adbPath: String {
        get {
            if let v = UserDefaults.standard.string(forKey: adbPathKey), !v.isEmpty { return v }
            return defaultAdbPath()
        }
        set { UserDefaults.standard.set(newValue, forKey: adbPathKey) }
    }

    static var serverPath: String {
        get {
            if let v = UserDefaults.standard.string(forKey: serverPathKey), !v.isEmpty { return v }
            return defaultServerPath()
        }
        set { UserDefaults.standard.set(newValue, forKey: serverPathKey) }
    }

    /// Screenshot save directory; defaults to the system Downloads folder.
    static var captureDirectory: String {
        get {
            if let v = UserDefaults.standard.string(forKey: captureDirKey), !v.isEmpty { return v }
            return defaultCaptureDirectory()
        }
        set { UserDefaults.standard.set(newValue, forKey: captureDirKey) }
    }

    static func defaultCaptureDirectory() -> String {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first?.path
            ?? (NSHomeDirectory() + "/Downloads")
    }

    static func defaultAdbPath() -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            home + "/Library/Android/sdk/platform-tools/adb",
            "/opt/homebrew/bin/adb",
            "/usr/local/bin/adb",
            "/opt/local/bin/adb",
            "/usr/bin/adb",
        ]
        for c in candidates where FileManager.default.isExecutableFile(atPath: c) {
            return c
        }
        return "adb"
    }

    static func defaultServerPath() -> String {
        let candidates = [
            "/opt/homebrew/share/scrcpy/scrcpy-server",
            "/usr/local/share/scrcpy/scrcpy-server",
            "/usr/share/scrcpy/scrcpy-server",
        ]
        for c in candidates where FileManager.default.isReadableFile(atPath: c) {
            return c
        }
        return ""
    }
}
