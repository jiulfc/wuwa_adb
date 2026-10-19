import AppKit

final class DebugWindowController: NSObject {
    private let store: ControlInfoStore
    private let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 560),
                                  styleMask: [.titled, .closable, .resizable, .miniaturizable],
                                  backing: .buffered, defer: false)
    private let textView = NSTextView()
    private let pinButton = NSButton(checkboxWithTitle: "Always on Top", target: nil, action: nil)
    private var timer: Timer?

    init(store: ControlInfoStore) {
        self.store = store
        super.init()
        window.title = "Debug"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 420, height: 300)
        window.center()
        pinButton.target = self
        pinButton.action = #selector(togglePin)
        textView.isEditable = false
        textView.isSelectable = true
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textContainerInset = NSSize(width: 12, height: 12)
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.documentView = textView
        let content = window.contentView!
        for view in [pinButton, scroll] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            pinButton.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            pinButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            scroll.topAnchor.constraint(equalTo: pinButton.bottomAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        // Refresh at a bounded rate so tight workflow loops do not flood the UI.
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            guard let self, self.window.isVisible else { return }
            self.render()
        }
    }

    deinit { timer?.invalidate() }

    @objc private func togglePin() {
        window.level = pinButton.state == .on ? .floating : .normal
    }

    func show() {
        render()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func render() {
        let entry = store.current
        let coordinates = entry.map {
            String(format: "Absolute: (%d, %d)\nRelative: (%.4f, %.4f)", $0.absX, $0.absY, $0.relX, $0.relY)
        } ?? "Absolute: —\nRelative: —"
        let variables = store.variables.keys.sorted().flatMap {
            store.variables[$0]!.debugLines(name: $0)
        }.joined(separator: "\n")
        let text = """
        PLAYBACK
        Status: \(store.playbackStatus)
        Current script (selected): \(store.selectedScriptName ?? "—")
        Running script: \(store.runningScriptName ?? "—")
        Current step (latest activity): \(store.currentStep ?? "—")
        Repeat progress: \(store.scriptRepeatProgress ?? "—")

        VARIABLES / PROPS (current script: \(store.runningScriptName ?? "—"))
        \(variables.isEmpty ? "—" : variables)

        LATEST WORKFLOW RESULT / ERROR
        \(store.latestWorkflowMessage ?? "—")

        DEVICE / INPUT
        Device: \(store.deviceName.isEmpty ? "—" : store.deviceName)
        Resolution: \(store.deviceWidth) × \(store.deviceHeight)
        Recording: \(store.isRecording ? "Yes" : "No")
        Last operation: \(entry?.operation ?? "—")
        \(coordinates)
        """
        if textView.string != text { textView.string = text }
    }
}

extension JSONValue {
    func debugLines(name: String) -> [String] {
        switch self {
        case .object(let values) where !values.isEmpty:
            return values.keys.sorted().flatMap { values[$0]!.debugLines(name: "\(name).\($0)") }
        case .string(let value):
            return ["\(name): \(value)"]
        default:
            return ["\(name): \(debugText)"]
        }
    }

    var debugText: String {
        switch self {
        case .null: return "null"
        case .bool(let value): return value ? "true" : "false"
        case .number(let value):
            let text = String(value)
            return text.hasSuffix(".0") ? String(text.dropLast(2)) : text
        case .string(let value): return String(reflecting: value)
        case .array(let values): return "[" + values.map(\.debugText).joined(separator: ", ") + "]"
        case .object(let values):
            return "{" + values.keys.sorted().map { "\($0): \(values[$0]!.debugText)" }.joined(separator: ", ") + "}"
        }
    }
}
