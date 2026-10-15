import AppKit

/// 设备列表窗口：居中展示已连接设备（网格卡片），右上角刷新按钮，选择设备后镜像。
final class DeviceListWindowController: NSObject, NSCollectionViewDataSource, NSCollectionViewDelegate {
    private static let cardID = NSUserInterfaceItemIdentifier("DeviceCard")

    private let window: NSWindow
    private let collectionView = NSCollectionView()
    private let scrollView = NSScrollView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let refreshButton = NSButton()

    private var devices: [Device] = []
    private var onSelect: ((Device) -> Void)?

    override init() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 440),
                          styleMask: [.titled, .closable, .miniaturizable],
                          backing: .buffered, defer: false)
        super.init()
        window.isReleasedWhenClosed = false
        configure()
    }

    private func configure() {
        window.title = "Adb Quick"

        let titleLabel = NSTextField(labelWithString: "已连接的设备")
        titleLabel.font = .boldSystemFont(ofSize: 15)

        refreshButton.title = "刷新"
        refreshButton.bezelStyle = .rounded
        refreshButton.target = self
        refreshButton.action = #selector(refresh)

        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.stringValue = "正在刷新…"

        // 网格布局（2 列卡片）
        let layout = NSCollectionViewFlowLayout()
        layout.itemSize = NSSize(width: 328, height: 52)
        layout.minimumInteritemSpacing = 8
        layout.minimumLineSpacing = 8
        layout.sectionInset = NSEdgeInsets(top: 12, left: 16, bottom: 12, right: 16)

        collectionView.collectionViewLayout = layout
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.isSelectable = true
        collectionView.backgroundColors = [.clear]
        collectionView.register(DeviceCardItem.self, forItemWithIdentifier: Self.cardID)

        scrollView.documentView = collectionView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true   // 内容少时不显示滚动条
        scrollView.drawsBackground = false
        collectionView.autoresizingMask = [.width]

        let content = window.contentView!
        let subviews: [NSView] = [titleLabel, refreshButton, scrollView, statusLabel]
        for v in subviews {
            v.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(v)
        }
        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            titleLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),

            refreshButton.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            refreshButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),

            scrollView.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 12),
            scrollView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: statusLabel.topAnchor, constant: -10),

            statusLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -16),
            statusLabel.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
        ])
    }

    func setOnSelect(_ handler: @escaping (Device) -> Void) {
        onSelect = handler
    }

    func show() {
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        collectionView.deselectAll(nil)
        refresh()
    }

    func close() {
        window.orderOut(nil)
    }

    /// 展示连接中的状态提示。
    func showConnecting(_ text: String) {
        statusLabel.stringValue = text
    }

    @objc private func refresh() {
        statusLabel.stringValue = "正在刷新…"
        let adb = AdbClient(adbPath: AppSettings.adbPath)
        DispatchQueue.global().async { [weak self] in
            do {
                var devices = try adb.devices()
                for i in devices.indices {
                    let info = adb.deviceInfo(serial: devices[i].serial)
                    devices[i].deviceName = info.name
                    devices[i].androidVersion = info.version
                    devices[i].resolution = info.resolution
                }
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.devices = devices
                    self.collectionView.reloadData()
                    self.statusLabel.stringValue = devices.isEmpty
                        ? "未检测到设备，请连接后点击刷新"
                        : "共 \(devices.count) 台设备"
                }
            } catch {
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.devices = []
                    self.collectionView.reloadData()
                    self.statusLabel.stringValue = "获取设备失败：\(error.localizedDescription)"
                }
            }
        }
    }

    // MARK: - NSCollectionViewDataSource

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        devices.count
    }

    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let item = collectionView.makeItem(withIdentifier: Self.cardID, for: indexPath)
        if let card = item as? DeviceCardItem {
            card.configure(device: devices[indexPath.item])
        }
        return item
    }

    // MARK: - NSCollectionViewDelegate

    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
        guard let indexPath = indexPaths.first, indexPath.item < devices.count else { return }
        let device = devices[indexPath.item]
        collectionView.deselectAll(nil)
        onSelect?(device)
    }
}

/// 设备卡片（网格单元）。
final class DeviceCardItem: NSCollectionViewItem {
    private let nameLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")

    override func loadView() {
        view = DeviceCardView(frame: .zero)

        nameLabel.font = .systemFont(ofSize: 14, weight: .medium)
        nameLabel.lineBreakMode = .byTruncatingTail
        subtitleLabel.font = .systemFont(ofSize: 11)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.lineBreakMode = .byTruncatingTail

        view.addSubview(nameLabel)
        view.addSubview(subtitleLabel)
        for v in [nameLabel, subtitleLabel] {
            v.translatesAutoresizingMaskIntoConstraints = false
        }
        NSLayoutConstraint.activate([
            nameLabel.topAnchor.constraint(equalTo: view.topAnchor, constant: 8),
            nameLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            nameLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),

            subtitleLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 3),
            subtitleLabel.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            subtitleLabel.trailingAnchor.constraint(equalTo: nameLabel.trailingAnchor),
        ])
    }

    func configure(device: Device) {
        nameLabel.stringValue = device.displayName
        subtitleLabel.stringValue = device.subtitle
    }
}

/// 圆角卡片背景视图。
final class DeviceCardView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8)
        NSColor.controlBackgroundColor.setFill()
        path.fill()
        NSColor.separatorColor.setStroke()
        path.lineWidth = 1
        path.stroke()
    }
}
