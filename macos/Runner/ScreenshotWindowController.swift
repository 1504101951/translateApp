import Cocoa
import CoreGraphics
import FlutterMacOS

/// 系统截图模块承接权限与冻结帧；Dart 编辑层负责框选变暗、标注与导出。
final class ScreenshotWindowController: NSObject, NSWindowDelegate {
    /// 图片导出的真实剪贴板；测试使用独立命名板，避免覆盖用户剪贴板。
    private let pasteboard: NSPasteboard

    /// pasteboard 为截图导出的系统目标；创建独立的截图生命周期控制器。
    init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
        super.init()
    }
    private var engine: FlutterEngine?
    private var window: NSWindow?
    private var channel: FlutterMethodChannel?
    private var textInputActive = false
    /// 标记本编辑会话曾设置原生光标，关闭时清除，避免污染其他窗口。
    private var hasNativeResizeCursor = false
    private var capturing = false
    /// 保存冻结帧任务；退出时取消并拒绝权限请求或截图的迟到结果。
    private var captureTask: Task<Void, Never>?
    /// 发起冻结截图前的前台应用身份；编辑器获得焦点不改变应用来源排序。
    private var sourceApplicationID: String?
    private var captureSources: [[String: Any]] = []
    private var targetPreviews: [NSWindow] = []
    private var previewSource: (kind: String, applicationID: String?)?

    /// 无参数；撤下准备阶段的跨显示器预览，不改变冻结帧或编辑文档。
    private func clearTargetPreviews() {
        targetPreviews.forEach { $0.close() }
        targetPreviews.removeAll()
    }

    /// kind为目标、applicationID为已列出的应用身份；按来源快照显示其他屏幕的实际画布，无返回值。
    private func previewTarget(kind: String, applicationID: String?) {
        // 每次目标变更先释放旧预览，截图来源屏由Flutter绘制。
        clearTargetPreviews()
        previewSource = (kind, applicationID)
        guard kind == CaptureTarget.application.rawValue else { return }
        let source = captureSources.first { $0["applicationID"] as? String == applicationID }
        let rects = (source?["windows"] as? [[String: CGFloat]])?.map {
            CGRect(x: $0["x"]!, y: $0["y"]!, width: $0["width"]!, height: $0["height"]!)
        }
        for screen in NSScreen.screens {
            let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as! NSNumber).uint32Value
            guard id != selectedDisplayID else { continue }
            let panel = NSWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            panel.isReleasedWhenClosed = false
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.ignoresMouseEvents = true
            panel.level = .statusBar
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            let shade = CaptureShadeView(frame: NSRect(origin: .zero, size: screen.frame.size))
            shade.selection = shade.bounds
            let display = CGDisplayBounds(id)
            // SCK窗口使用全局顶部原点，AppKit视图使用本屏底部原点。
            shade.contentRects = rects?.compactMap { rect in
                let clipped = rect.intersection(display)
                guard !clipped.isNull else { return nil }
                return CGRect(x: clipped.minX - display.minX, y: display.maxY - clipped.maxY,
                              width: clipped.width, height: clipped.height)
            }
            panel.contentView = shade
            targetPreviews.append(panel)
            panel.orderFrontRegardless()
        }
    }

    private var selectedDisplayID: CGDirectDisplayID = 0
    private var selectedScale: CGFloat = 1
    private var png: Data?
    private var captureId: String?
    private var capturedAt: Int64 = 0
    private var pixels = NSSize.zero
    private var displayFrame = NSRect(x: 0, y: 0, width: 1280, height: 800)
    /// 前台窗口在冻结帧上的像素裁剪；没有前台窗口则为 nil。
    private var windowCrop: NSRect?
    private var message: String?
    /// 冻结帧垫在 Flutter 下面，避免首帧透明闪一下。
    private let freezeView = NSImageView()
    private var displaysFrozenScreen = true
    /// 本地路由处理 AppKit 事件；会话事件拦截负责非激活窗口并消费已处理的按键。
    private var localKeys: Any?
    private var globalKeyTap: CFMachPort?
    private var globalKeySource: CFRunLoopSource?
    /// 贴图与编辑窗分离；关闭编辑不销毁已贴出的图。
    let pins = PinOverlayController()
    var onCapturingChanged: ((Bool) -> Void)?
    /// source为已选择来源，scrolling指定长截图，region为校验后的选区；协调器启动真实采集。
    var onPrepareCapture: (@MainActor ([String: Any], Bool, MediaCaptureService.Region?) throws -> Void)?
    /// 用户已展开有效录制目标；提前准备隐藏控制界面，不启动采集或改变截图草稿。
    var onPrepareCaptureControls: (@MainActor () -> Void)?
    /// 应用ID为截图前台应用；返回去重、有序且携带PNG图标的可录制应用。
    var onCaptureSources: (@MainActor (String?) async throws -> [[String: Any]])?

    /// 无参数；返回已完成的冻结帧身份，换帧期间和媒体结果图片均不能发起屏幕采集。
    var liveCaptureID: String? { !capturing && displaysFrozenScreen && png != nil ? captureId : nil }

    /// 无参数；在用户选定录制目标后收起冻结编辑层，释放该截图会话，无返回值。
    func closeForCapture() { window?.close() }

    /// 无参数；准备采集时隐藏冻结画面并释放跨屏预览，保留编辑草稿供启动失败恢复。
    func hideForCapture() {
        clearTargetPreviews()
        window?.orderOut(nil)
    }

    /// 无参数；采集准备失败或取消时重新显示同一编辑会话，不重新读取屏幕。
    func restoreAfterCapturePreparation() {
        guard liveCaptureID != nil else { return }
        // 恢复同一目标的其他显示器预览，Flutter本屏裁剪与工具选择保持原样。
        if let source = previewSource { previewTarget(kind: source.kind, applicationID: source.applicationID) }
        window?.makeKeyAndOrderFront(nil)
    }

    /// displayID指定显示器，空值使用指针所在屏；创建冻结编辑会话，无返回值。
    func capture(displayID: CGDirectDisplayID? = nil) {
        guard !capturing, window?.attachedSheet == nil else { return }
        displaysFrozenScreen = true
        capturing = true
        // 替换冻结帧时撤下上一张截图的跨屏预览。
        clearTargetPreviews()
        captureSources.removeAll()
        previewSource = nil
        sourceApplicationID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        onCapturingChanged?(true)
        if window?.isVisible == true {
            window?.orderOut(nil)
        }
        captureTask = Task { @MainActor in
            defer {
                self.capturing = false
                self.captureTask = nil
                self.onCapturingChanged?(false)
            }
            let granted = await ScreenCaptureService.requestAccess()
            guard !Task.isCancelled else { return }
            guard granted else {
                self.png = nil
                self.captureId = nil
                self.windowCrop = nil
                self.message = "截图需要屏幕录制权限。请在设置中允许 TranslateApp。"
                ScreenCaptureService.openScreenRecordingSettings()
                self.show(compact: true)
                return
            }
            do {
                let frame = try await ScreenCaptureService.captureActiveDisplay(displayID: displayID)
                // 系统截图可能不响应任务取消；写入画面与创建窗口前再次验证。
                try Task.checkCancellation()
                self.selectedDisplayID = frame.displayID
                self.selectedScale = frame.scale
                self.png = frame.png
                self.captureId = UUID().uuidString
                self.capturedAt = Int64(Date().timeIntervalSince1970 * 1000)
                self.pixels = NSSize(width: frame.pixelWidth, height: frame.pixelHeight)
                self.displayFrame = frame.displayFrame
                self.windowCrop = frame.windowCrop
                self.message = nil
                self.show(compact: false)
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                self.png = nil
                self.captureId = nil
                self.windowCrop = nil
                self.message = error.localizedDescription
                self.show(compact: true)
            }
        }
    }

    /// 无参数；取消冻结帧任务并结束媒体选区回调，迟到帧不能再展示窗口。
    func cancelCapture() {
        clearTargetPreviews()
        captureTask?.cancel()
    }

    /// 无参数；关闭编辑窗并关闭引擎，保留已创建的贴图。
    func shutdown() {
        cancelCapture()
        if hasNativeResizeCursor { NSCursor.arrow.set(); hasNativeResizeCursor = false }
        removeScreenshotKeys()
        window?.delegate = nil
        window?.close()
        window = nil
        channel?.setMethodCallHandler(nil)
        engine?.shutDownEngine()
        engine = nil
        channel = nil
        textInputActive = false
        png = nil
        captureId = nil
        pins.closeAll()
    }

    /// id 为翻译启动时的捕获身份；返回截图是否仍存在且未被替换。
    func isCurrentCapture(_ id: String) -> Bool {
        captureId == id
    }

    /// 无参数；返回当前截图和保存目录，PNG 以 typed data 下发。
    private func snapshot() -> [String: Any] {
        var value: [String: Any] = [
            // 展示快照时帧已填充，冻结任务随后结束；原生动作仍通过liveCaptureID拒绝换帧期请求。
            "canCaptureMedia": displaysFrozenScreen && png != nil,

            "directory": UserDefaults.standard.string(forKey: AppConstants.screenshotSaveDirectoryKey) ?? "",
            "screenAccess": ScreenCaptureService.isAuthorized(),
            "capturedAt": capturedAt,
            "width": pixels.width,
            "height": pixels.height,
            "captureDisplayX": CGDisplayBounds(selectedDisplayID).minX,
            "captureDisplayY": CGDisplayBounds(selectedDisplayID).minY,
            "displayX": displayFrame.origin.x,
            "displayY": displayFrame.origin.y,
            "displayWidth": displayFrame.width,
            "displayHeight": displayFrame.height,
        ]
        if let screen = NSScreen.screens.first(where: {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == selectedDisplayID
        }), displaysFrozenScreen {
            // 可用区域按冻结显示器的局部顶部原点发送；不改变整屏画布和源图坐标。
            value["toolbarSafeX"] = screen.visibleFrame.minX - displayFrame.minX
            value["toolbarSafeY"] = displayFrame.maxY - screen.visibleFrame.maxY
            value["toolbarSafeWidth"] = screen.visibleFrame.width
            value["toolbarSafeHeight"] = screen.visibleFrame.height
        }
        if !displaysFrozenScreen { value["imageScale"] = selectedScale }
        if let png, let captureId {
            value["id"] = captureId
            value["bytes"] = FlutterStandardTypedData(bytes: png)
        }
        if let windowCrop {
            value["cropX"] = windowCrop.origin.x
            value["cropY"] = windowCrop.origin.y
            value["cropWidth"] = windowCrop.width
            value["cropHeight"] = windowCrop.height
        }
        if let message { value["error"] = message }
        // 新会话携带当前工具偏好；已打开会话使用独立配置通知，不能重置草稿。
        value.merge(toolbarPreferences()) { _, current in current }
        return value
    }

    /// 无参数；返回已保存的工具栏配置子集，缺省值由Dart领域对象提供。
    private func toolbarPreferences() -> [String: Any] {
        let preferences = UserDefaults.standard.dictionary(forKey: AppConstants.preferencesKey) ?? [:]
        return preferences.filter { [AppConstants.screenshotToolbarOrderKey, AppConstants.screenshotToolbarShortcutsKey, AppConstants.screenshotToolbarHiddenKey, AppConstants.screenshotDrawingKey].contains($0.key) }
    }

    /// 无参数；只广播工具偏好，保留图像与标注，关闭窗口时无订阅者。
    func toolbarPreferencesChanged() {
        channel?.invokeMethod(AppConstants.screenshotToolbarChangedMethod, arguments: toolbarPreferences())
    }

    /// png/id/尺寸为合成捕获；showEditor 为真时启动真实 Flutter 编辑窗，供系统链路测试。
    func seedCaptureForTesting(png: Data, id: String, width: CGFloat = 1, height: CGFloat = 1, showEditor: Bool = false) {
        self.displaysFrozenScreen = true
        self.png = png
        self.captureId = id
        self.pixels = NSSize(width: width, height: height)
        self.capturedAt = Int64(Date().timeIntervalSince1970 * 1000)
        self.message = nil
        if showEditor { show(compact: false) }
    }

    /// call 为截图操作，result 返回数据/路径或错误；导出优先使用 Dart 合成后的 bytes。
    func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let args = call.arguments as? [String: Any] ?? [:]
        switch call.method {
        case AppConstants.previewCaptureTargetMethod:
            guard let id = args["id"] as? String, id == liveCaptureID,
                  let kind = args["kind"] as? String,
                  CaptureTarget(rawValue: kind) != nil else {
                result(FlutterError(code: AppConstants.badArgsError, message: "录制预览已失效。", details: nil))
                return
            }
            // 仅使用本次冻结帧列出的来源信息，客户端不能注入窗口坐标。
            previewTarget(kind: kind, applicationID: args["applicationID"] as? String)
            // UI初始化完成才返回预览成功；迟到预览不能为已经替换的截图准备界面。
            Task { @MainActor in
                guard id == self.liveCaptureID else {
                    result(FlutterError(code: AppConstants.badArgsError, message: "录制预览已失效。", details: nil))
                    return
                }
                self.onPrepareCaptureControls?()
                result(nil)
            }
        case AppConstants.captureSourcesMethod:
            guard let id = args["id"] as? String, id == liveCaptureID,
                  let sources = onCaptureSources else {
                result(FlutterError(code: AppConstants.badArgsError, message: "请在当前屏幕截图中选择录制应用。", details: nil))
                return
            }
            Task { @MainActor in
                do {
                    // 来源查询只返回数据，异步结果不能更新已经替换的截图。
                    let values = try await sources(sourceApplicationID)
                    guard id == self.liveCaptureID else { throw CancellationError() }
                    self.captureSources = values
                    result(values)
                } catch {
                    result(FlutterError(code: AppConstants.captureFailedError, message: error.localizedDescription, details: nil))
                }
            }
        case AppConstants.prepareCaptureMethod:
            guard !capturing, let id = args["id"] as? String, id == liveCaptureID,
                  let kind = args["kind"] as? String, [CaptureTarget.region.rawValue, CaptureTarget.display.rawValue, CaptureTarget.application.rawValue].contains(kind),
                  let scrolling = args["scrolling"] as? Bool, !scrolling || kind == CaptureTarget.region.rawValue,
                  let prepare = onPrepareCapture else {
                result(FlutterError(code: AppConstants.badArgsError, message: "请在当前屏幕截图中选择采集工具。", details: nil))
                return
            }
            Task { @MainActor in
                guard id == self.liveCaptureID else {
                    result(FlutterError(code: AppConstants.badArgsError, message: "截图已变化，请重新选择采集工具。", details: nil))
                    return
                }
                do {
                    var source = args
                    // 所有目标保留冻结显示器身份，供控制条固定在同一显示器。
                    source["sourceID"] = selectedDisplayID
                    // 选区只在开始时提交，显示器由冻结帧身份决定，不接受其他显示器坐标。
                    try prepare(source, scrolling, kind == CaptureTarget.region.rawValue ? captureRegion(args) : nil)
                    result(nil)
                } catch {
                    result(FlutterError(code: AppConstants.captureFailedError, message: error.localizedDescription, details: nil))
                }
            }
        case AppConstants.setResizeCursorMethod:
            // 使用公开AppKit对角光标；Flutter当前macOS引擎会把这两个方向映射为箭头。
            let position: NSCursor.FrameResizePosition
            switch args["direction"] as? String {
            case AppConstants.resizeNorthWestSouthEast: position = .topLeft
            case AppConstants.resizeNorthEastSouthWest: position = .topRight
            default:
                result(FlutterError(code: AppConstants.badArgsError, message: "无效的拉伸光标方向。", details: nil))
                return
            }
            // 窗口关闭后的迟到请求不能重新设置桌面光标。
            guard window?.isVisible == true else { result(nil); return }
            NSCursor.frameResize(position: position, directions: .all).set()
            hasNativeResizeCursor = true
            result(nil)
        case AppConstants.saveDrawingPreferencesMethod:
            // routeWindowRequest把绘图偏好交给唯一设置提交入口。
            MacPlatformBridge.Shared.instance?.routeWindowRequest(call, result: result)
        case AppConstants.getScreenshotMethod:
            result(snapshot())
        case AppConstants.recognizeBlocksMethod:
            guard let id = args["id"] as? String, id == captureId else {
                result(FlutterError(code: AppConstants.staleCaptureError, message: "截图已关闭或被替换，请重新截图。", details: nil))
                return
            }
            let payload: Data
            if let typed = args["bytes"] as? FlutterStandardTypedData {
                payload = typed.data
            } else if let png {
                payload = png
            } else {
                result(FlutterError(code: AppConstants.staleCaptureError, message: "截图已关闭或被替换，请重新截图。", details: nil))
                return
            }
            do {
                result(try ScreenCaptureService.recognizeBlocks(png: payload))
            } catch {
                result(FlutterError(code: AppConstants.ocrFailedError, message: error.localizedDescription, details: nil))
            }
        case AppConstants.recognizeTextMethod:
            guard let id = args["id"] as? String, id == captureId else {
                result(FlutterError(code: AppConstants.staleCaptureError, message: "截图已关闭或被替换，请重新截图。", details: nil))
                return
            }
            let payload: Data
            if let typed = args["bytes"] as? FlutterStandardTypedData {
                payload = typed.data
            } else if let png {
                payload = png
            } else {
                result(FlutterError(code: AppConstants.staleCaptureError, message: "截图已关闭或被替换，请重新截图。", details: nil))
                return
            }
            do {
                result(try ScreenCaptureService.recognizeText(png: payload))
            } catch {
                result(FlutterError(code: AppConstants.ocrFailedError, message: error.localizedDescription, details: nil))
            }
        case AppConstants.copyTextMethod:
            guard let text = args["text"] as? String, !text.isEmpty else {
                result(FlutterError(code: AppConstants.ocrEmptyError, message: "没有可复制的文字。", details: nil))
                return
            }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            result(nil)
        case AppConstants.translatePlainTextMethod:
            guard let id = args["id"] as? String, id == captureId else {
                result(FlutterError(code: AppConstants.staleCaptureError, message: "截图已关闭或被替换。", details: nil)); return
            }
            guard let text = args["text"] as? String, !text.isEmpty else {
                result(FlutterError(code: AppConstants.ocrEmptyError, message: "没有可翻译的文字。", details: nil))
                return
            }
            MacPlatformBridge.Shared.instance?.requestApplication(
                AppConstants.translatePlainTextMethod,
                // 保留捕获身份，主 Dart 引擎在翻译完成后再次核对再写历史。
                arguments: ["text": text, "id": id],
                result: result
            )
        case AppConstants.captureRegionMethod:
            capture(); result(nil)
        case AppConstants.closeScreenshotMethod:
            window?.close(); result(nil)
        case AppConstants.requestScreenAccessMethod:
            Task { @MainActor in
                let granted = await ScreenCaptureService.requestAccess()
                if !granted {
                    ScreenCaptureService.openScreenRecordingSettings()
                }
                result(self.snapshot())
            }
        case AppConstants.copyScreenshotMethod, AppConstants.saveScreenshotMethod, AppConstants.pinScreenshotMethod:
            guard let id = args["id"] as? String, id == captureId else {
                result(FlutterError(code: AppConstants.staleCaptureError, message: "截图已关闭或被替换，请重新截图。", details: nil))
                return
            }
            guard let typed = args["bytes"] as? FlutterStandardTypedData else {
                result(FlutterError(code: AppConstants.staleCaptureError, message: "截图已关闭或被替换，请重新截图。", details: nil))
                return
            }
            let payload = typed.data
            switch call.method {
            case AppConstants.copyScreenshotMethod:
                let item = NSPasteboardItem()
                item.setData(payload, forType: .png)
                pasteboard.clearContents()
                guard pasteboard.writeObjects([item]) else {
                    result(FlutterError(code: AppConstants.copyFailedError, message: "无法复制截图，请重试。", details: nil))
                    return
                }
                result(nil)
            case AppConstants.saveScreenshotMethod:
                let name = args["name"] as? String ?? "screenshot.png"
                do {
                    // datedDirectory统一默认路径；save独占创建，重名只增加序号。
                    let directory = try ScreenshotStorage.datedDirectory(
                        basePath: UserDefaults.standard.string(forKey: AppConstants.screenshotSaveDirectoryKey),
                        extension: "png")
                    let url = try ScreenshotStorage.save(payload, directory: directory, name: name)
                    result(url.path)
                } catch {
                    result(FlutterError(code: AppConstants.saveFailedError, message: error.localizedDescription, details: nil))
                }
            case AppConstants.pinScreenshotMethod:
                guard let x = args["x"] as? NSNumber, let y = args["y"] as? NSNumber else {
                    result(FlutterError(code: AppConstants.badArgsError, message: "贴图缺少选区坐标。", details: nil))
                    return
                }
                window?.orderOut(nil)
                let pinId = pins.pin(
                    png: payload,
                    origin: NSPoint(x: x.doubleValue, y: y.doubleValue)
                )
                result(pinId)
            default:
                result(FlutterMethodNotImplemented)
            }
        case AppConstants.screenshotTextInputMethod:
            guard let active = args["active"] as? Bool else {
                result(FlutterError(code: AppConstants.badArgsError, message: "缺少文字编辑状态。", details: nil))
                return
            }
            // 引擎异步通知必须属于当前捕获，上一张截图不能锁住新截图快捷键。
            if let id = args["id"] as? String, id == captureId {
                textInputActive = active
            }
            result(nil)
        case AppConstants.revealFileMethod:
            guard let path = args["path"] as? String else {
                result(FlutterError(code: AppConstants.badArgsError, message: "缺少文件路径。", details: nil))
                return
            }
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
            result(nil)
        case AppConstants.closePinMethod:
            if let pinId = args["id"] as? String {
                pins.close(pinId: pinId)
            }
            result(nil)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    /// compact为无权限/失败小窗；按冻结选区配置窗口，返回窗口是否已显示。
    @discardableResult
    private func show(compact: Bool) -> Bool {
        let overlay = compact || displaysFrozenScreen
        if engine == nil {
            let engine = FlutterEngine(name: "screenshot", project: nil, allowHeadlessExecution: false)
            self.engine = engine
            let channel = FlutterMethodChannel(name: AppConstants.screenshotChannel, binaryMessenger: engine.binaryMessenger)
            self.channel = channel
            channel.setMethodCallHandler { [weak self] call, result in self?.handle(call, result: result) }
            let flutter = FlutterViewController(engine: engine, nibName: nil, bundle: nil)
            guard engine.run(withEntrypoint: AppConstants.screenshotEntrypoint) else {
                channel.setMethodCallHandler(nil)
                engine.shutDownEngine()
                self.engine = nil
                self.channel = nil
                let alert = NSAlert()
                alert.messageText = "截图预览启动失败"
                alert.informativeText = "请退出并重新打开 TranslateApp。"
                alert.runModal()
                return false
            }
            RegisterGeneratedPlugins(registry: flutter)
            // 平台视图工厂按引擎注册，编辑窗只服务冻结选区。
            NativeGlassFactory.register(with: flutter)
            flutter.view.wantsLayer = true
            flutter.view.layer?.isOpaque = false
            flutter.view.layer?.backgroundColor = CGColor.clear
            window = makeWindow(content: flutter, overlay: overlay)
            freezeView.imageScaling = .scaleAxesIndependently
            freezeView.wantsLayer = true
        }
        if let old = window, old.styleMask.contains(.nonactivatingPanel) != overlay {
            // 非激活标记由初始化决定；转移同一引擎的视图，不在切换时清理图片或重建引擎。
            let content = old.contentViewController!
            old.contentViewController = nil
            old.delegate = nil
            old.close()
            window = makeWindow(content: content, overlay: overlay)
        }
        let frame = compact
            ? NSRect(x: displayFrame.midX - 220, y: displayFrame.midY - 90, width: 440, height: 180)
            : overlay ? displayFrame : Self.imageResultFrame(pixels: pixels, scale: selectedScale, visible: displayFrame)
        window?.setFrame(frame, display: true)
        installFreezeImage(compact: compact)
        window?.displayIfNeeded()
        channel?.invokeMethod(AppConstants.screenshotChangedMethod, arguments: snapshot())
        if overlay {
            // 冻结选择不激活应用，避免设置窗跟随弹出。
            if NSApp.isHidden { NSApp.unhideWithoutActivation() }
            window?.orderFrontRegardless()
            window?.makeKey()
        } else {
            NSApp.activate()
            window?.makeKeyAndOrderFront(nil)
        }
        installScreenshotKeys()
        return window?.isVisible == true
    }

    /// content为共享编辑视图，overlay决定覆盖选区或普通结果；返回具备正确焦点与关闭契约的窗口。
    private func makeWindow(content: NSViewController, overlay: Bool) -> ScreenshotPanel {
        let style: NSWindow.StyleMask = overlay
            ? [.borderless, .fullSizeContentView, .nonactivatingPanel] : AppConstants.captureResultWindowStyle
        let panel = ScreenshotPanel(contentRect: displayFrame, styleMask: style, backing: .buffered, defer: false)
        panel.onEscape = { [weak self] in
            // Dart判断文字输入时取消草稿，其余状态立即关闭当前图片。
            self?.channel?.invokeMethod(AppConstants.escapePressedMethod, arguments: nil)
        }
        panel.onUndo = { [weak self] in self?.channel?.invokeMethod(AppConstants.undoPressedMethod, arguments: nil) }
        panel.onRedo = { [weak self] in self?.channel?.invokeMethod(AppConstants.redoPressedMethod, arguments: nil) }
        panel.title = overlay ? "" : "截图"
        panel.isFloatingPanel = overlay
        panel.level = overlay ? .statusBar : .normal
        panel.collectionBehavior = overlay ? [.canJoinAllSpaces, .fullScreenAuxiliary] : [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.animationBehavior = .none
        panel.hidesOnDeactivate = false
        panel.isOpaque = !overlay
        panel.backgroundColor = overlay ? .clear : .windowBackgroundColor
        panel.hasShadow = !overlay
        if !overlay { panel.contentMinSize = NSSize(width: 320, height: 240) }
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.contentViewController = content
        return panel
    }

    /// pixels/scale为来源原图与倍率，visible为来源屏可用区；返回保留逻辑宽、允许纵向滚动的结果窗口框。
    static func imageResultFrame(pixels: NSSize, scale: CGFloat, visible: NSRect) -> NSRect {
        let style = AppConstants.captureResultWindowStyle
        let available = NSWindow.contentRect(forFrameRect: visible, styleMask: style)
        let size = NSSize(width: min(available.width, max(320, pixels.width / scale + 72)),
                          height: min(available.height, max(240, pixels.height / scale + 16)))
        let frame = NSWindow.frameRect(forContentRect: NSRect(origin: .zero, size: size), styleMask: style)
        return NSRect(x: visible.midX - frame.width / 2, y: visible.midY - frame.height / 2,
                      width: frame.width, height: frame.height)
    }

    /// compact 为失败小窗；成功时把冻结 PNG 垫在 Flutter 下面，避免透明首帧。
    private func installFreezeImage(compact: Bool) {
        guard let host = window?.contentView else { return }
        freezeView.frame = host.bounds
        freezeView.autoresizingMask = [.width, .height]
        if freezeView.superview !== host {
            host.addSubview(freezeView, positioned: .below, relativeTo: nil)
        }
        if compact || png == nil || !displaysFrozenScreen {
            freezeView.image = nil
            freezeView.isHidden = true
            return
        }
        freezeView.isHidden = false
        let image = NSImage(data: png!)
        if let image, let rep = image.representations.first {
            image.size = NSSize(width: displayFrame.width, height: displayFrame.height)
            _ = rep
        }
        freezeView.image = image
    }

    /// args携带源图像素坐标x/y/width/height；返回绑定冻结显示器的有效区域，越界或小尺寸抛错。
    private func captureRegion(_ args: [String: Any]) throws -> MediaCaptureService.Region {
        guard let x = args["x"] as? Double, let y = args["y"] as? Double,
              let width = args["width"] as? Double, let height = args["height"] as? Double,
              [x, y, width, height].allSatisfy({ $0.isFinite }), x >= 0, y >= 0,
              width >= 32, height >= 64, x + width <= pixels.width, y + height <= pixels.height else {
            throw GIFExporter.ExportError(message: "请在单个显示器内选择至少32×64像素的区域。")
        }
        return MediaCaptureService.Region(displayID: selectedDisplayID,
            rect: CGRect(x: x, y: y, width: width, height: height), scale: selectedScale,
            edges: .init(top: 0, bottom: 0, automatic: true))
    }

    /// event 为按键；返回是否由当前截图处理，调用方据此消费事件。
    func routeScreenshotKey(_ event: NSEvent) -> Bool {
        guard window?.isVisible == true, window?.attachedSheet == nil,
              displaysFrozenScreen || window?.isKeyWindow == true else { return false }
        // 文字输入期间普通键和编辑命令交给Flutter/NSTextInputClient，不能先消费再丢弃。
        // Escape仍由Dart决定仅取消当前文字草稿，其他状态不受影响。
        if textInputActive && event.keyCode != AppConstants.escapeKeyCode { return false }
        if [AppConstants.returnKeyCode, AppConstants.keypadEnterKeyCode].contains(event.keyCode),
           event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty,
           let id = captureId {
            // 输入法候选确认属于 NSTextInputClient，不能提前提交整段截图标注。
            if let input = window?.firstResponder as? NSTextInputClient, input.hasMarkedText() {
                return false
            }
            // 非激活截图面板不保证 Flutter 收到原始 Enter；本地和全局入口统一转发。
            if !event.isARepeat {
                channel?.invokeMethod(AppConstants.confirmScreenshotMethod, arguments: ["id": id])
            }
            return true
        }
        if event.keyCode == AppConstants.escapeKeyCode {
            (window as? ScreenshotPanel)?.onEscape?()
            return true
        }
        if event.modifierFlags.contains(.command),
           event.charactersIgnoringModifiers?.lowercased() == "z" {
            if event.modifierFlags.contains(.shift) {
                (window as? ScreenshotPanel)?.onRedo?()
            } else {
                (window as? ScreenshotPanel)?.onUndo?()
            }
            return true
        }
        // 非激活面板不保证收到Flutter键盘事件；直接派发语义动作，禁止重放字符。
        guard let id = captureId,
              let character = event.characters(byApplyingModifiers: [])?.lowercased(),
              character.unicodeScalars.count == 1,
              let key = character.unicodeScalars.first,
              let shortcuts = toolbarPreferences()[AppConstants.screenshotToolbarShortcutsKey] as? [String: [String: Int]] else {
            return false
        }
        let flags = event.modifierFlags
        let modifiers = (flags.contains(.control) ? 1 : 0)
            | (flags.contains(.option) ? 2 : 0)
            | (flags.contains(.shift) ? 4 : 0)
            | (flags.contains(.command) ? 8 : 0)
        guard let action = shortcuts.first(where: {
            $0.value["keyId"] == Int(key.value) && $0.value["modifiers"] == modifiers
        })?.key else { return false }
        if !event.isARepeat {
            channel?.invokeMethod(AppConstants.screenshotToolbarActionMethod, arguments: ["id": id, "action": action])
        }
        return true
    }

    /// event 为跨应用按键；返回待继续派发的事件，截图已处理时返回 nil 消费该键。
    func filterScreenshotEvent(_ event: CGEvent) -> CGEvent? {
        guard let key = NSEvent(cgEvent: event) else { return event }
        // 系统事件必须在交给来源应用前消费，不能用只能旁听的 global monitor 确认截图。
        return routeScreenshotKey(key) ? nil : event
    }

    /// 无参数；安装本地路由及可消费的会话级事件拦截，不让截图快捷键传给来源应用。
    private func installScreenshotKeys() {
        removeScreenshotKeys()
        localKeys = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if self?.routeScreenshotKey(event) == true { return nil }
            return event
        }
        // 普通结果窗口只接收自身按键；切到其他应用后不截获全局Return/Escape或工具快捷键。
        guard displaysFrozenScreen else { return }
        let mask = CGEventMask(1) << CGEventType.keyDown.rawValue
        let pointer = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, pointer in
                guard let pointer else { return Unmanaged.passUnretained(event) }
                let controller = Unmanaged<ScreenshotWindowController>.fromOpaque(pointer).takeUnretainedValue()
                if type == .tapDisabledByTimeout {
                    if let tap = controller.globalKeyTap { CGEvent.tapEnable(tap: tap, enable: true) }
                    return Unmanaged.passUnretained(event)
                }
                guard type == .keyDown else { return Unmanaged.passUnretained(event) }
                guard let forwarded = controller.filterScreenshotEvent(event) else { return nil }
                return Unmanaged.passUnretained(forwarded)
            }, userInfo: pointer
        ) else {
            message = "无法启用截图跨应用按键，请检查辅助功能权限后重新截图。"
            channel?.invokeMethod(AppConstants.screenshotChangedMethod, arguments: snapshot())
            return
        }
        globalKeyTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)!
        globalKeySource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    /// 无参数；关掉截图层时卸掉按键监听。
    private func removeScreenshotKeys() {
        if let localKeys { NSEvent.removeMonitor(localKeys) }
        if let globalKeyTap {
            CGEvent.tapEnable(tap: globalKeyTap, enable: false)
            CFMachPortInvalidate(globalKeyTap)
        }
        if let globalKeySource { CFRunLoopRemoveSource(CFRunLoopGetMain(), globalKeySource, .commonModes) }
        localKeys = nil
        globalKeyTap = nil
        globalKeySource = nil
    }

}

/// 截图编辑层需要成为 key 才能收 Esc 与文字输入；非激活译文浮层不能复用。
final class ScreenshotPanel: NSPanel {
    var onEscape: (() -> Void)?
    var onUndo: (() -> Void)?
    var onRedo: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    /// event 为按键；Esc 结束本次截图；⌘Z / ⇧⌘Z 走标注历史。
    override func keyDown(with event: NSEvent) {
        if event.keyCode == AppConstants.escapeKeyCode {
            onEscape?()
            return
        }
        if event.modifierFlags.contains(.command),
           event.charactersIgnoringModifiers?.lowercased() == "z" {
            if event.modifierFlags.contains(.shift) {
                onRedo?()
            } else {
                onUndo?()
            }
            return
        }
        super.keyDown(with: event)
    }
}

extension ScreenshotWindowController {
    /// notification 为编辑窗关闭通知；释放原始图像并通知 Dart 清空，不撤销已导出文件或贴图。
    func windowWillClose(_ notification: Notification) {
        previewSource = nil
        clearTargetPreviews()
        captureSources.removeAll()
        if hasNativeResizeCursor { NSCursor.arrow.set(); hasNativeResizeCursor = false }
        removeScreenshotKeys()
        textInputActive = false
        png = nil
        captureId = nil
        message = nil
        windowCrop = nil
        freezeView.image = nil
        channel?.invokeMethod(AppConstants.screenshotChangedMethod, arguments: snapshot())
    }
}
