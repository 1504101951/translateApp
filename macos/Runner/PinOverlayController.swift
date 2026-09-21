import AppKit

/// 独立置顶贴图；不抢来源 App 焦点，生命周期与截图编辑会话、选区译文分离。
final class PinOverlayController {
    private var pins: [String: PinPanel] = [:]

    /// png 为最终合成图，origin 为选区左下角的 AppKit 屏幕坐标。返回贴图 id。
    @discardableResult
    func pin(png: Data, origin: NSPoint) -> String {
        let id = UUID().uuidString
        let panel = PinPanel(png: png, pinId: id) { [weak self] closedId in
            self?.pins.removeValue(forKey: closedId)
        }
        panel.setFrameOrigin(origin)
        pins[id] = panel
        if NSApp.isHidden { NSApp.unhideWithoutActivation() }
        panel.orderFrontRegardless()
        return id
    }

    /// pinId 为目标贴图；只关闭该贴图，不清理剪贴板或已保存文件。
    func close(pinId: String) {
        pins[pinId]?.close()
        pins.removeValue(forKey: pinId)
    }

    /// 无参数；关闭全部贴图，供应用退出时释放窗口。
    func closeAll() {
        // 先取出快照再清空，避免 close 回调在遍历时修改字典。
        let panels = Array(pins.values)
        pins.removeAll()
        for panel in panels {
            panel.closeSilently()
        }
    }

    /// 无参数；返回当前贴图数量，供测试断言生命周期。
    var count: Int { pins.count }

    /// pinId 是否仍显示；用于断言关闭与选区会话互不影响。
    func isVisible(pinId: String) -> Bool {
        pins[pinId]?.isVisible == true
    }

    /// 无参数；返回首个贴图窗口（测试用），不存在则为 nil。
    var firstPanel: PinPanel? { pins.values.first }
}

/// 图片层接管拖动：NSImageView 是控件，isMovableByWindowBackground 对其无效。
final class DraggablePinImageView: NSImageView {
    var onDoubleClick: (() -> Void)?
    /// 测试计数：每次进入单击拖动路径 +1，证明 mouseDown→performDrag 已接线。
    private(set) var dragBeginCountForTesting = 0

    /// 无参数；图片层不抢按键，Esc 才能落到贴图窗口。
    override var acceptsFirstResponder: Bool { false }

    /// event 为首次点击；非活动来源下也直接交给图片，避免首次点击仅激活窗口。
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// event 为左键按下；单击拖动窗口，双击关闭。
    override func mouseDown(with event: NSEvent) {
        if event.clickCount >= 2 {
            onDoubleClick?()
            return
        }
        dragBeginCountForTesting += 1
        // performDrag自行消费松开事件；拖前明确选中此贴图，让Esc可靠作用于它。
        window?.makeKey()
        window?.performDrag(with: event)
    }


}

/// 无边框非激活贴图窗；可拖动、滚轮缩放，并提供明确关闭入口。
final class PinPanel: NSPanel {
    private let rootView = NSView()
    private let imageView = DraggablePinImageView()
    private let closeHandler: (String) -> Void
    let pinId: String
    private var baseSize: NSSize = .zero
    private var scale: CGFloat = 1

    /// png 为贴图像素；pinId 标识此窗；onClose 在关闭时回传 id。
    init(png: Data, pinId: String, onClose: @escaping (String) -> Void) {
        self.pinId = pinId
        self.closeHandler = onClose
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 150),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = false
        // 图片层自行 performDrag；保留该标志仅作无控件空隙的兜底。
        isMovableByWindowBackground = true

        guard let image = NSImage(data: png), let rep = image.representations.first else {
            preconditionFailure("贴图 PNG 无效")
        }
        // Dart 重编码没有 DPI；用当前屏缩放把像素换成点。
        let backing = max(NSScreen.main?.backingScaleFactor ?? 1, 1)
        image.size = NSSize(
            width: CGFloat(rep.pixelsWide) / backing,
            height: CGFloat(rep.pixelsHigh) / backing
        )
        baseSize = image.size
        imageView.image = image
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.wantsLayer = true
        imageView.layer?.cornerRadius = 4
        imageView.layer?.masksToBounds = true
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.onDoubleClick = { [weak self] in self?.closeFromUserAction() }

        // 图片不叠加关闭控件，避免遮住内容；Escape与双击共用关闭路径。
        rootView.wantsLayer = true
        rootView.addSubview(imageView)
        contentView = rootView
        NSLayoutConstraint.activate([
            imageView.topAnchor.constraint(equalTo: rootView.topAnchor),
            imageView.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            imageView.bottomAnchor.constraint(equalTo: rootView.bottomAnchor),
        ])
        setContentSize(clampedSize(for: baseSize))

        let magnify = NSMagnificationGestureRecognizer(target: self, action: #selector(onMagnify(_:)))
        imageView.addGestureRecognizer(magnify)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// event 为按键；选中贴图后 Esc 只关这一张。
    override func keyDown(with event: NSEvent) {
        if event.keyCode == AppConstants.escapeKeyCode {
            closeFromUserAction()
            return
        }
        super.keyDown(with: event)
    }

    /// sender 为菜单/系统取消动作；Esc 的标准响应路径，与 keyDown 同源关闭。
    override func cancelOperation(_ sender: Any?) {
        closeFromUserAction()
    }

    /// 无参数；关闭并通知控制器移除，不改剪贴板/文件。
    override func close() {
        closeHandler(pinId)
        super.close()
    }

    /// 无参数；控制器批量关闭时使用，避免回调再次改字典。
    func closeSilently() {
        orderOut(nil)
        super.close()
    }

    /// 无参数；用户按Escape或双击图片时关闭此贴图。
    @objc func closeFromUserAction() {
        close()
    }

    /// 无参数；返回可拖动图片层，供测试发送 mouseDown。
    var imageViewForTesting: DraggablePinImageView { imageView }

    /// 无参数；返回贴图 NSImage 像素尺寸，供断言 pinScreenshot 消费的是合成 bytes。
    var pinnedImagePixelSizeForTesting: NSSize {
        guard let image = imageView.image else { return .zero }
        // representations 优先取位图像素；否则回退逻辑 size。
        if let rep = image.representations.first {
            return NSSize(width: rep.pixelsWide, height: rep.pixelsHigh)
        }
        return image.size
    }

    /// event 为捏合手势；按比例缩放贴图，限制在屏幕可见范围内。
    @objc private func onMagnify(_ event: NSMagnificationGestureRecognizer) {
        guard event.state == .changed || event.state == .ended else { return }
        scale = min(5, max(0.2, scale * (1 + event.magnification)))
        event.magnification = 0
        let size = clampedSize(for: NSSize(width: baseSize.width * scale, height: baseSize.height * scale))
        var frame = self.frame
        frame.size = size
        if let screen = screen ?? NSScreen.main {
            let visible = screen.visibleFrame.insetBy(dx: 8, dy: 8)
            frame.origin.x = min(max(frame.minX, visible.minX), visible.maxX - size.width)
            frame.origin.y = min(max(frame.minY, visible.minY), visible.maxY - size.height)
        }
        setFrame(frame, display: true)
    }

    /// event 为滚轮；Command+滚轮缩放，便于触控板用户。
    override func scrollWheel(with event: NSEvent) {
        guard event.modifierFlags.contains(.command) else {
            super.scrollWheel(with: event)
            return
        }
        let delta = event.scrollingDeltaY
        scale = min(5, max(0.2, scale * (delta > 0 ? 1.05 : 0.95)))
        let size = clampedSize(for: NSSize(width: baseSize.width * scale, height: baseSize.height * scale))
        var frame = self.frame
        frame.size = size
        setFrame(frame, display: true)
    }

    /// size 为期望内容尺寸；限制最大不超过主屏可见区域。
    private func clampedSize(for size: NSSize) -> NSSize {
        let screen = NSScreen.main?.visibleFrame.insetBy(dx: 16, dy: 16)
            ?? NSRect(x: 0, y: 0, width: 800, height: 600)
        let maxW = max(80, screen.width)
        let maxH = max(80, screen.height)
        let ratio = min(1, min(maxW / max(size.width, 1), maxH / max(size.height, 1)))
        return NSSize(width: max(40, size.width * ratio), height: max(40, size.height * ratio))
    }
}
