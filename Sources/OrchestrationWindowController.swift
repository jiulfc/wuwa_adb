import AppKit
import UniformTypeIdentifiers
import WebKit

/// v3 流程的本地网页编排器。文件读写和 DSL 校验留在原生侧。
final class OrchestrationWindowController: NSObject, WKScriptMessageHandler, WKUIDelegate {
    private let window: NSWindow
    private let webView: WKWebView
    private var fileURL: URL?
    private var loaded = false

    override init() {
        let configuration = WKWebViewConfiguration()
        let contentController = WKUserContentController()
        configuration.userContentController = contentController
        webView = WKWebView(frame: .zero, configuration: configuration)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1240, height: 820),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        super.init()

        contentController.add(self, name: "orchestration")
        webView.uiDelegate = self
        window.title = "流程编排器 — 未命名"
        window.minSize = NSSize(width: 880, height: 600)
        window.isReleasedWhenClosed = false
        webView.translatesAutoresizingMaskIntoConstraints = false
        window.contentView?.addSubview(webView)
        if let content = window.contentView {
            NSLayoutConstraint.activate([
                webView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
                webView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
                webView.topAnchor.constraint(equalTo: content.topAnchor),
                webView.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            ])
        }
    }

    func show() {
        if !loaded { loadEditor() }
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard message.name == "orchestration",
              let body = message.body as? [String: Any],
              let action = body["action"] as? String else { return }

        switch action {
        case "new":
            fileURL = nil
            window.title = "流程编排器 — 未命名"
        case "open":
            openFlow()
        case "save", "saveAs":
            guard let source = body["json"] as? String else { return }
            saveFlow(source, chooseLocation: action == "saveAs")
        case "validate":
            guard let source = body["json"] as? String else { return }
            validate(source)
        default:
            break
        }
    }

    private func loadEditor() {
        let bundled = Bundle.main.url(forResource: "orchestration", withExtension: "html")
        let executableDirectory = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
        let source = executableDirectory.appendingPathComponent("assets/orchestration.html")
        guard let url = bundled ?? (FileManager.default.fileExists(atPath: source.path) ? source : nil) else {
            report("找不到流程编排器网页资源。", alert: true)
            return
        }
        loaded = true
        webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
    }

    private func openFlow() {
        let panel = NSOpenPanel()
        panel.title = "打开 v3 流程"
        panel.allowedContentTypes = [.json]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let self, let url = panel.url else { return }
            do {
                let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size <= 1_048_576 else {
                    throw DSLParseError(path: "$", message: "Workflow exceeds 1 MiB")
                }
                let data = try Data(contentsOf: url)
                _ = try WorkflowParser().parse(data)
                guard let source = String(data: data, encoding: .utf8) else {
                    throw CocoaError(.fileReadInapplicableStringEncoding)
                }
                self.fileURL = url
                self.window.title = "流程编排器 — \(url.lastPathComponent)"
                self.call("loadDocument", arguments: [source])
                self.report("已打开 \(url.lastPathComponent)")
            } catch {
                self.report("无法打开流程：\(error.localizedDescription)", alert: true)
            }
        }
    }

    private func saveFlow(_ source: String, chooseLocation: Bool) {
        let data = Data(source.utf8)
        do {
            _ = try WorkflowParser().parse(data)
        } catch {
            report("保存前校验失败：\(error.localizedDescription)", alert: true)
            return
        }

        if let fileURL, !chooseLocation {
            write(data, to: fileURL)
            return
        }

        let panel = NSSavePanel()
        panel.title = "保存 v3 流程"
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = fileURL?.lastPathComponent ?? "workflow.json"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let self, let url = panel.url else { return }
            self.write(data, to: url)
        }
    }

    private func write(_ data: Data, to url: URL) {
        do {
            try data.write(to: url, options: .atomic)
            fileURL = url
            window.title = "流程编排器 — \(url.lastPathComponent)"
            call("markSaved", arguments: [])
            report("已保存 \(url.lastPathComponent)")
        } catch {
            report("保存失败：\(error.localizedDescription)", alert: true)
        }
    }

    private func validate(_ source: String) {
        do {
            let workflow = try WorkflowParser().parse(Data(source.utf8))
            report("v3 流程有效：\(workflow.steps.count) 个顶层步骤")
        } catch {
            report("校验失败：\(error.localizedDescription)")
        }
    }

    private func report(_ text: String, alert: Bool = false) {
        call("showStatus", arguments: [text, alert])
        guard alert else { return }
        let warning = NSAlert()
        warning.alertStyle = .warning
        warning.messageText = "流程编排器"
        warning.informativeText = text
        warning.beginSheetModal(for: window)
    }

    private func call(_ function: String, arguments: [Any]) {
        guard JSONSerialization.isValidJSONObject(arguments),
              let data = try? JSONSerialization.data(withJSONObject: arguments),
              let json = String(data: data, encoding: .utf8) else { return }
        webView.evaluateJavaScript("\(function).apply(null, \(json))")
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let warning = NSAlert()
        warning.alertStyle = .warning
        warning.messageText = "放弃未保存的更改？"
        warning.informativeText = message
        warning.addButton(withTitle: "放弃更改")
        warning.addButton(withTitle: "取消")
        warning.beginSheetModal(for: window) { response in
            completionHandler(response == .alertFirstButtonReturn)
        }
    }
}
