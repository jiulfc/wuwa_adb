import AppKit
import UniformTypeIdentifiers
import WebKit

/// Local web orchestrator for v3 workflows; native code owns file I/O and DSL validation.
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
        window.title = "Workflow Orchestrator — Untitled"
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
            window.title = "Workflow Orchestrator — Untitled"
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
        let bundled = Bundle.main.url(forResource: "orchestration_1", withExtension: "html")
        let executableDirectory = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
        let source = executableDirectory.appendingPathComponent("assets/orchestration_1.html")
        guard let url = bundled ?? (FileManager.default.fileExists(atPath: source.path) ? source : nil) else {
            report("Workflow orchestrator web resource was not found.", alert: true)
            return
        }
        loaded = true
        webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
    }

    private func openFlow() {
        let panel = NSOpenPanel()
        panel.title = "Open v3 Workflow"
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
                self.window.title = "Workflow Orchestrator — \(url.lastPathComponent)"
                self.call("loadDocument", arguments: [source])
                self.report("Opened \(url.lastPathComponent)")
            } catch {
                self.report("Unable to open workflow: \(error.localizedDescription)", alert: true)
            }
        }
    }

    private func saveFlow(_ source: String, chooseLocation: Bool) {
        let data = Data(source.utf8)
        do {
            _ = try WorkflowParser().parse(data)
        } catch {
            report("Validation before save failed: \(error.localizedDescription)", alert: true)
            return
        }

        if let fileURL, !chooseLocation {
            write(data, to: fileURL)
            return
        }

        let panel = NSSavePanel()
        panel.title = "Save v3 Workflow"
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
            window.title = "Workflow Orchestrator — \(url.lastPathComponent)"
            call("markSaved", arguments: [])
            report("Saved \(url.lastPathComponent)")
        } catch {
            report("Save failed: \(error.localizedDescription)", alert: true)
        }
    }

    private func validate(_ source: String) {
        do {
            let workflow = try WorkflowParser().parse(Data(source.utf8))
            report("Valid v3 workflow: \(workflow.steps.count) top-level step(s)")
        } catch {
            report("Validation failed: \(error.localizedDescription)")
        }
    }

    private func report(_ text: String, alert: Bool = false) {
        call("showStatus", arguments: [text, alert])
        guard alert else { return }
        let warning = NSAlert()
        warning.alertStyle = .warning
        warning.messageText = "Workflow Orchestrator"
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
        warning.messageText = "Discard unsaved changes?"
        warning.informativeText = message
        warning.addButton(withTitle: "Discard Changes")
        warning.addButton(withTitle: "Cancel")
        warning.beginSheetModal(for: window) { response in
            completionHandler(response == .alertFirstButtonReturn)
        }
    }
}
