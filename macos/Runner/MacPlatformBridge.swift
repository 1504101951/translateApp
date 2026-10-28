import Cocoa
import Carbon
import CoreServices
import Security
import LocalAuthentication
import NaturalLanguage
import ServiceManagement
import FlutterMacOS

/// Dart ↔ Swift 平台通道。不保存翻译状态，不实现 Provider。
final class MacPlatformBridge: NSObject, FlutterStreamHandler {
    static let methodChannelName = AppConstants.macosChannel
    static let eventChannelName = AppConstants.macosEventsChannel

    private var eventSink: FlutterEventSink?
    private let overlay: OverlayPanelController
    private let selectionMonitor: SelectionMonitor
    let screenshot = ScreenshotWindowController()
    private var screenshotActive = false
    private var mediaActive = false
    /// 一个采集控制器持有当前媒体会话，菜单与独立窗口共享资源状态。
    @MainActor lazy var live: LiveRegionCoordinator = LiveRegionCoordinator(bridge: self, controls: self.capture)
    @MainActor lazy var capture: CaptureWindowController = {
        let controller = CaptureWindowController(screenshot: screenshot)
        controller.onActiveChanged = { [weak self] active in
            guard let self else { return }
            self.mediaActive = active
            // 合并截图与连续采集占用，避免一个结束时提前恢复选区监听。
            self.updateCaptureActivity()
            StatusBarController.shared.setCaptureActive(active)
        }
        return controller
    }()
    /// MCP 请求入口；开关读取已提交的普通偏好，工具由 MCPToolRunner 执行。
    @MainActor lazy var mcp = MCPCaptureServer(
        isEnabled: {
            let preferences = AppPreferences.current
            return preferences[AppConstants.mcpEnabledKey] as? Bool == true
        },
        run: MCPToolRunner.run
    )
    /// 译文卡片朗读；只持有当前朗读的文字。
    private let speech = SpeechService()
    /// Apple 系统翻译；只持有进行中的会话供取消，翻译业务由 Dart 的 AppleTranslationProvider 负责。
    @MainActor lazy var systemTranslation = SystemTranslationService()
    private var methods: FlutterMethodChannel?
    var onReady: (() -> Void)? {
        didSet {
            // Dart 可能在回调赋值前就发来 appReady；补一次，避免向导被丢掉。
            if pendingAppReady, let onReady {
                pendingAppReady = false
                onReady()
            }
        }
    }
    private var pendingAppReady = false
    var closePermissionWizard: (() -> Void)?
    var shortcutRecorder: ((UInt32, UInt32) -> Void)?
    private var currentSessionId: String?
    private var sourceProcessIdentifier: pid_t?
    private var selectionReadTask: Task<Void, Never>?
    var hasSelection: Bool { currentSessionId != nil }
    private(set) var retainsResult = false

    /// overlay 为浮层，selectionMonitor 为系统输入监听；创建不含翻译业务状态的平台桥。
    init(overlay: OverlayPanelController, selectionMonitor: SelectionMonitor) {
        self.overlay = overlay
        self.selectionMonitor = selectionMonitor
        super.init()
        screenshot.onPrepareCapture = { [weak self] source, scrolling, region in
            guard let self else { return }
            if source["live"] as? Bool == true {
                // 实时翻译复用目标选择，但不进入录屏编码器。
                try await self.live.begin(source: source, region: region)
                return
            }
            // 截图工具栏的目标交给同一个媒体会话，截图控制器不持有录制资源。
            try self.capture.prepare(source: source, scrolling: scrolling, region: region)
        }
        screenshot.onPreviewLiveRegion = { [weak self] screen in
            self?.live.preview(on: screen)
        }
        screenshot.onCancelLivePreview = { [weak self] in
            self?.live.cancelPreview()
        }
        screenshot.onCaptureSources = { [weak self] preferred in
            guard let self else { throw CancellationError() }
            // 同一媒体资源层提供应用清单，截图控制器只隔离截图身份。
            return try await self.capture.sources(preferredApplicationID: preferred)
        }
        screenshot.onPrepareCaptureControls = { [weak self] in
            // prepareControls在用户选择录制目标期间预初始化并复用隐藏界面。
            self?.capture.prepareControls()
        }
        screenshot.onCapturingChanged = { [weak self] active in
            guard let self else { return }
            self.screenshotActive = active
            // 汇总两个采集入口；设置菜单仍可操作，自动翻译暂时挂起。
            self.updateCaptureActivity()
        }
    }

    /// 无参数；同步正在采集的资源占用到翻译监听与浮层可见性，无返回值。
    private func updateCaptureActivity() {
        let active = screenshotActive || mediaActive
        selectionMonitor.isCapturingScreenshot = active
        overlay.setCaptureHidden(active)
    }

    /// messenger 为主引擎通道，overlay 为浮层，selectionMonitor 为输入监听；返回已注册的平台桥。
    @discardableResult
    static func register(with messenger: FlutterBinaryMessenger, overlay: OverlayPanelController, selectionMonitor: SelectionMonitor) -> MacPlatformBridge {
        let instance = MacPlatformBridge(overlay: overlay, selectionMonitor: selectionMonitor)
        let methods = FlutterMethodChannel(name: methodChannelName, binaryMessenger: messenger)
        instance.methods = methods
        methods.setMethodCallHandler { call, result in
            instance.handle(call, result: result)
        }
        let events = FlutterEventChannel(name: eventChannelName, binaryMessenger: messenger)
        events.setStreamHandler(instance)
        Shared.instance = instance
        return instance
    }

    /// 已注册平台桥的进程共享入口；原生窗口与菜单转发请求，不持有另一份业务状态。
    enum Shared {
        static var instance: MacPlatformBridge?
    }

    /// call 为带 sessionId 的窗口命令；通过 result 返回成功或参数错误，无直接返回值。
    func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let args = call.arguments as? [String: Any] ?? [:]
        switch call.method {
        case AppConstants.showOverlayMethod:
            guard let sessionId = args["sessionId"] as? String,
                  let x = args["x"] as? Double,
                  let y = args["y"] as? Double
            else {
                result(FlutterError(code: AppConstants.badArgsError, message: "showOverlay 需要 sessionId/x/y", details: nil))
                return
            }
            guard currentSessionId == sessionId else { result(nil); return }
            guard let width = args["width"] as? Double, let height = args["height"] as? Double,
                  x.isFinite, y.isFinite, width.isFinite, height.isFinite, width > 0, height > 0 else {
                result(FlutterError(code: AppConstants.badArgsError, message: "Overlay 坐标和尺寸必须有效", details: nil))
                return
            }
            // 显示前再次核对会话，失效后迟到的 Dart 指令不能重新弹窗。
            overlay.show(
                at: NSPoint(x: x, y: y),
                size: NSSize(width: width, height: height),
                sessionId: sessionId
            )
            result(nil)
        case AppConstants.retainOverlayMethod:
            guard let sessionId = args["sessionId"] as? String else {
                result(FlutterError(code: AppConstants.badArgsError, message: "retainOverlay 需要 sessionId", details: nil)); return
            }
            // 展开由显式翻译触发，之后被动选区和前台变化只影响新的采集。
            if currentSessionId == sessionId { retainsResult = true }
            result(nil)
        case AppConstants.hideOverlayMethod:
            guard let sessionId = args["sessionId"] as? String else {
                result(FlutterError(code: AppConstants.badArgsError, message: "hideOverlay 需要 sessionId", details: nil))
                return
            }
            guard currentSessionId == sessionId else { result(nil); return }
            selectionReadTask?.cancel()
            selectionReadTask = nil
            currentSessionId = nil
            sourceProcessIdentifier = nil
            retainsResult = false
            overlay.hide(sessionId: sessionId)
            result(nil)
        case AppConstants.setOverlaySizeMethod:
            guard let sessionId = args["sessionId"] as? String,
                  let width = args["width"] as? Double,
                  let height = args["height"] as? Double
            else {
                result(FlutterError(code: AppConstants.badArgsError, message: "setOverlaySize 需要 sessionId/width/height", details: nil))
                return
            }
            guard currentSessionId == sessionId else { result(nil); return }
            guard width.isFinite, height.isFinite, width > 0, height > 0 else {
                result(FlutterError(code: AppConstants.badArgsError, message: "Overlay 尺寸必须为正数", details: nil))
                return
            }
            overlay.resize(sessionId: sessionId, size: NSSize(width: width, height: height))
            result(nil)
        case AppConstants.dragOverlayMethod:
            guard let sessionId = args["sessionId"] as? String else {
                result(FlutterError(code: AppConstants.badArgsError, message: "dragOverlay 需要 sessionId", details: nil))
                return
            }
            // Flutter 区分拖动与点击，AppKit 负责实际移动且不激活应用。
            overlay.drag(sessionId: sessionId)
            result(nil)
        case AppConstants.readSelectionForTranslationMethod:
            guard let sessionId = args["sessionId"] as? String else {
                result(FlutterError(code: AppConstants.badArgsError, message: "读取选区需要 sessionId", details: nil)); return
            }
            guard currentSessionId == sessionId, let pid = sourceProcessIdentifier else { result(nil); return }
            selectionReadTask?.cancel()
            // 明确点击翻译后才允许复制读取段落，自动检测阶段不注入按键。
            selectionReadTask = Task { @MainActor [weak self] in
                let selection = await AccessibilitySelection.readFrontmostSelection(sourcePID: pid, allowCopy: true)
                guard let self, !Task.isCancelled, self.currentSessionId == sessionId else { result(nil); return }
                result(selection.text)
            }
        case AppConstants.replaceSelectionMethod:
            guard let sessionId = args["sessionId"] as? String, let text = args["text"] as? String else {
                result(FlutterError(code: AppConstants.badArgsError, message: "替换选区需要 sessionId/text", details: nil)); return
            }
            // 只替换仍属于本会话、仍在前台且未开启安全输入的来源应用；其余情况保留卡片供手动复制。
            guard currentSessionId == sessionId, let pid = sourceProcessIdentifier,
                  NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
                  !IsSecureEventInputEnabled() else { result(false); return }
            Task { @MainActor in
                // pasteReplacingSelection 经剪贴板粘贴，并在来源应用读取后还原原剪贴板。
                result(await AccessibilitySelection.pasteReplacingSelection(text, pasteboard: .general, paste: AccessibilitySelection.postPasteKey))
            }
        case AppConstants.isCurrentScreenshotMethod:
            guard let id = args["id"] as? String else {
                result(FlutterError(code: AppConstants.badArgsError, message: "核对截图需要 id", details: nil)); return
            }
            // 翻译结果落库前核对原生生命周期，关闭的截图不得产生历史。
            // 只查询捕获身份，不向主引擎传输第二份截图数据。
            result(screenshot.isCurrentCapture(id))
        case AppConstants.loadSettingsMethod:
            var settings = AppPreferences.current
            settings["systemLanguage"] = Locale.preferredLanguages.first ?? "en"
            settings[AppConstants.launchAtLoginKey] = [.enabled, .requiresApproval].contains(SMAppService.mainApp.status)
            // 设置页面展示解析后的根目录；空偏好使用系统Pictures下的截图目录。
            settings[AppConstants.screenshotSaveDirectoryKey] =
                ScreenshotStorage.rootDirectory(
                    UserDefaults.standard.string(forKey: AppConstants.screenshotSaveDirectoryKey)
                    ?? (settings[AppConstants.screenshotSaveDirectoryKey] as? String)).path
            result(settings)
        case AppConstants.chooseScreenshotDirectoryMethod:
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.canCreateDirectories = true
            panel.allowsMultipleSelection = false
            panel.prompt = "使用此目录"
            panel.begin { response in
                guard response == .OK, let url = panel.url else {
                    result(nil)
                    return
                }
                result(url.path)
            }
        case AppConstants.applySettingsMethod:
            guard let settings = args["settings"] as? [String: Any],
                  let credentials = args["credentials"] as? [String: Any] else {
                result(FlutterError(code: AppConstants.badSettingsError, message: "设置数据不完整。", details: nil)); return
            }
            applySettings(settings, credentials: credentials, result: result)
        case AppConstants.readCredentialsMethod:
            guard let id = args["id"] as? String else {
                result(FlutterError(code: AppConstants.badArgsError, message: "缺少服务标识。", details: nil)); return
            }
            do { result(try Self.readCredentials(id: id) ?? [:]) }
            catch { result(FlutterError(code: AppConstants.keychainFailedError, message: error.localizedDescription, details: nil)) }
        case AppConstants.credentialIdsMethod:
            let ids = args["ids"] as? [String] ?? []
            var saved: [String] = []
            let context = LAContext()
            context.interactionNotAllowed = true
            for id in ids {
                let query: [String: Any] = [
                    kSecClass as String: kSecClassGenericPassword,
                    kSecAttrService as String: AppConstants.credentialsKeychainService,
                    kSecAttrAccount as String: id,
                    kSecReturnAttributes as String: true,
                    // 常规设置只查询存在状态；授权留给用户主动读取或修改凭据时处理。
                    kSecUseAuthenticationContext as String: context,
                ]
                let status = SecItemCopyMatching(query as CFDictionary, nil)
                guard status == errSecSuccess || status == errSecItemNotFound || status == errSecInteractionNotAllowed else {
                    result(FlutterError(code: AppConstants.keychainFailedError, message: "无法读取凭据状态，请检查钥匙串访问权限。", details: nil)); return
                }
                if status == errSecSuccess || status == errSecInteractionNotAllowed { saved.append(id) }
            }
            result(saved)
        case AppConstants.detectLanguageMethod:
            guard let text = args["text"] as? String else {
                result(FlutterError(code: AppConstants.badArgsError, message: "缺少待识别文本", details: nil)); return
            }
            let recognizer = NLLanguageRecognizer()
            recognizer.processString(text)
            let hypothesis = recognizer.languageHypotheses(withMaximum: 1).first
            result(hypothesis.flatMap { $0.value >= 0.5 ? $0.key.rawValue : nil })
        case AppConstants.openFileMethod, AppConstants.revealFileMethod, AppConstants.copyImageFileMethod:
            guard let path = args["path"] as? String else {
                result(FlutterError(code: AppConstants.badArgsError, message: "缺少文件路径。", details: nil)); return
            }
            let url = URL(fileURLWithPath: path)
            switch call.method {
            case AppConstants.openFileMethod:
                // 系统默认应用打开，不激活或修改文件。
                result(NSWorkspace.shared.open(url))
            case AppConstants.revealFileMethod:
                NSWorkspace.shared.activateFileViewerSelecting([url])
                result(nil)
            default:
                // 复制 PNG 原始数据；文件不可读时返回错误，不改动剪贴板。
                guard let png = try? Data(contentsOf: url) else {
                    result(FlutterError(code: AppConstants.copyFailedError, message: "图片文件不可读。", details: nil)); return
                }
                let item = NSPasteboardItem()
                item.setData(png, forType: .png)
                NSPasteboard.general.clearContents()
                result(NSPasteboard.general.writeObjects([item]))
            }
        case AppConstants.stitchScreenshotsMethod:
            guard let paths = args["paths"] as? [String], let vertical = args["vertical"] as? Bool else {
                result(FlutterError(code: AppConstants.badArgsError, message: "stitchScreenshots 需要 paths/vertical", details: nil)); return
            }
            composeInBackground(result) {
                FlutterStandardTypedData(bytes: try ScreenshotComposer.stitch(paths: paths, vertical: vertical))
            }
        case AppConstants.splitScreenshotMethod:
            guard let path = args["path"] as? String, let parts = args["parts"] as? Int else {
                result(FlutterError(code: AppConstants.badArgsError, message: "splitScreenshot 需要 path/parts", details: nil)); return
            }
            composeInBackground(result) {
                try ScreenshotComposer.split(path: path, parts: parts).map(FlutterStandardTypedData.init(bytes:))
            }
        case AppConstants.compareScreenshotsMethod:
            guard let first = args["first"] as? String, let second = args["second"] as? String else {
                result(FlutterError(code: AppConstants.badArgsError, message: "compareScreenshots 需要 first/second", details: nil)); return
            }
            composeInBackground(result) {
                let comparison = try ScreenshotComposer.compare(first: first, second: second)
                return [
                    "mask": FlutterStandardTypedData(bytes: comparison.mask),
                    "different": comparison.different,
                    "total": comparison.total,
                ] as [String: Any]
            }
        case AppConstants.lookupDefinitionMethod:
            guard let text = args["text"] as? String else {
                result(FlutterError(code: AppConstants.badArgsError, message: "lookupDefinition 需要 text", details: nil)); return
            }
            // 词典服务使用「词典」App 已启用的词典离线查询；查不到返回 nil。
            let range = CFRange(location: 0, length: (text as NSString).length)
            result(DCSCopyTextDefinition(nil, text as CFString, range)?.takeRetainedValue() as String?)
        case AppConstants.saveTextFileMethod:
            guard let text = args["text"] as? String, let suggestedName = args["suggestedName"] as? String else {
                result(FlutterError(code: AppConstants.badArgsError, message: "saveTextFile 需要 text/suggestedName", details: nil)); return
            }
            // 用户在保存面板选择位置，取消返回 nil；写入失败返回错误，不静默丢弃导出内容。
            let panel = NSSavePanel()
            panel.nameFieldStringValue = suggestedName
            panel.allowedContentTypes = [.commaSeparatedText]
            NSApp.activate(ignoringOtherApps: true)
            panel.begin { response in
                guard response == .OK, let url = panel.url else { result(nil); return }
                do {
                    try text.write(to: url, atomically: true, encoding: .utf8)
                    result(url.path)
                } catch {
                    result(FlutterError(code: AppConstants.saveFailedError, message: error.localizedDescription, details: nil))
                }
            }
        case AppConstants.toggleSpeechMethod:
            guard let text = args["text"] as? String, let language = args["language"] as? String else {
                result(FlutterError(code: AppConstants.badArgsError, message: "toggleSpeech 需要 text/language", details: nil)); return
            }
            // toggle 在同一段正在朗读时停止，否则改读新文字；返回调用后是否在朗读。
            result(speech.toggle(text: text, language: language))
        case AppConstants.stopSpeechMethod:
            speech.stop()
            result(nil)
        case AppConstants.systemTranslateMethod:
            guard let requestId = args["requestId"] as? String,
                  let texts = args["texts"] as? [String],
                  let source = args["source"] as? String,
                  let target = args["target"] as? String,
                  let strategy = args["strategy"] as? String
            else {
                result(FlutterError(code: AppConstants.badArgsError, message: "systemTranslate 需要 requestId/texts/source/target/strategy", details: nil)); return
            }
            Task { @MainActor in
                // translate 返回按下标排列的译文；错误映射为跨端错误码，由 Dart 生成界面文案。
                do {
                    result(try await self.systemTranslation.translate(
                        requestId: requestId, texts: texts, source: source, target: target, strategy: strategy
                    ))
                } catch {
                    result(FlutterError(code: SystemTranslationService.errorCode(for: error), message: error.localizedDescription, details: nil))
                }
            }
        case AppConstants.cancelSystemTranslationMethod:
            guard let requestId = args["requestId"] as? String else {
                result(FlutterError(code: AppConstants.badArgsError, message: "cancelSystemTranslation 需要 requestId", details: nil)); return
            }
            Task { @MainActor in
                // cancel 停止对应会话；进行中的翻译随后以失败返回，Dart 已丢弃该结果。
                self.systemTranslation.cancel(requestId: requestId)
                result(nil)
            }
        case AppConstants.systemTranslationStatusMethod:
            guard let pairs = args["pairs"] as? [[String]], pairs.allSatisfy({ $0.count == 2 }) else {
                result(FlutterError(code: AppConstants.badArgsError, message: "systemTranslationStatus 需要 [源语言, 目标语言] 列表", details: nil)); return
            }
            Task { @MainActor in
                // status 只查询系统语言包状态，不触发下载；回复留在主线程。
                result(await SystemTranslationService.status(pairs: pairs))
            }
        case AppConstants.systemStatusMethod:
            result([
                "accessibility": AccessibilitySelection.isTrusted(prompt: false),
                "loginNeedsApproval": SMAppService.mainApp.status == .requiresApproval,
                "screenAccess": ScreenCaptureService.isAuthorized(),
            ])
        case AppConstants.permissionWizardStatusMethod:
            result([
                "accessibility": AccessibilitySelection.isTrusted(prompt: false),
                "screenAccess": ScreenCaptureService.isAuthorized(),
                "finishedOrSkipped": UserDefaults.standard.bool(forKey: AppConstants.permissionWizardFinishedKey),
            ])
        case AppConstants.finishPermissionWizardMethod:
            UserDefaults.standard.set(true, forKey: AppConstants.permissionWizardFinishedKey)
            result(nil)
        case AppConstants.closePermissionWizardMethod:
            closePermissionWizard?()
            result(nil)
        case AppConstants.applicationSupportPathMethod:
            // 目录路径由 AppConstants 计算，这里负责首次访问时创建。
            let dir = AppConstants.applicationSupportURL
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            result(dir.path)
        case AppConstants.mcpHelperPathMethod:
            // helper 与 App 主程序同在 Contents/MacOS，路径随 App 实际安装位置变化。
            let executable = Bundle.main.executableURL!.deletingLastPathComponent()
            result(executable.appendingPathComponent(AppConstants.mcpHelperName).path)
        case AppConstants.historyChangedMethod:
            NotificationCenter.default.post(name: AppConstants.historyChangedNotification, object: nil)
            result(nil)
        case AppConstants.publishLiveRegionMethod:
            // 快照字段由 LiveRegionCoordinator.publish 逐项校验，缺失即终止（#132）。
            let state = call.arguments as! [String: Any]
            Task { @MainActor in
                self.live.publish(state)
                result(nil)
            }
        case AppConstants.requestScreenAccessMethod:
            Task { @MainActor in
                let granted = await ScreenCaptureService.requestAccess(promoteToRegularApp: true)
                if !granted {
                    ScreenCaptureService.openScreenRecordingSettings()
                }
                result([
                    "screenAccess": granted,
                    "accessibility": AccessibilitySelection.isTrusted(prompt: false),
                    "loginNeedsApproval": SMAppService.mainApp.status == .requiresApproval,
                ])
            }
        case AppConstants.openAccessibilityMethod:
            // 已授权则只复用，不再弹系统提示。
            if AccessibilitySelection.isTrusted(prompt: false) {
                result(nil)
                return
            }
            _ = AccessibilitySelection.isTrusted(prompt: true)
            AccessibilitySelection.openSettings()
            result(nil)
        case AppConstants.openLoginItemsMethod:
            SMAppService.openSystemSettingsLoginItems()
            result(nil)
        case AppConstants.chooseExcludedAppMethod:
            let picker = NSOpenPanel()
            picker.allowedContentTypes = [.applicationBundle]
            picker.directoryURL = URL(fileURLWithPath: "/Applications")
            picker.allowsMultipleSelection = false
            picker.prompt = "排除此应用"
            picker.begin { response in
                guard response == .OK, let url = picker.url else { result(nil); return }
                guard let id = Bundle(url: url)?.bundleIdentifier else {
                    result(FlutterError(code: AppConstants.badAppError, message: "该应用没有 Bundle ID。", details: nil)); return
                }
                result(["id": id, "name": (FileManager.default.displayName(atPath: url.path) as NSString).deletingPathExtension])
            }
        case AppConstants.appReadyMethod:
            if let onReady {
                onReady()
            } else {
                pendingAppReady = true
            }
            result(nil)
        case AppConstants.appStartFailedMethod:
            result(nil)
            // 菜单栏应用默认不在前台；先激活，提示才不会被其他应用窗口挡住（#126）。
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "TranslateApp 无法启动"
            // message 由 Dart 启动入口必定提供。
            alert.informativeText = "主程序初始化失败：\(args["message"] as! String)"
            alert.addButton(withTitle: "退出")
            alert.runModal()
            NSApp.terminate(nil)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    /// settings 为 Dart 校验过的完整偏好；先完成系统副作用再落盘，结果通过 result 返回。
    private func applySettings(_ settings: [String: Any], credentials: [String: Any], result: @escaping FlutterResult) {
        // 三种全局快捷键按用途读取组合；任一缺失都视为参数不完整。
        var shortcuts: [GlobalHotKey: SelectionMonitor.HotKeyBinding] = [:]
        for purpose in GlobalHotKey.allCases {
            if let keyCode = settings[purpose.keyCodeKey] as? UInt32, let modifiers = settings[purpose.modifiersKey] as? UInt32 {
                shortcuts[purpose] = SelectionMonitor.HotKeyBinding(keyCode: keyCode, modifiers: modifiers)
            }
        }
        guard let automatic = settings[AppConstants.automaticKey] as? Bool,
              shortcuts.count == GlobalHotKey.allCases.count,
              let excluded = settings[AppConstants.excludedAppsKey] as? [String: String],
              let login = settings[AppConstants.launchAtLoginKey] as? Bool,
              credentials.values.allSatisfy({ $0 is NSNull || $0 is [String: String] }) else {
            result(FlutterError(code: AppConstants.badSettingsError, message: "系统设置参数不完整。", details: nil)); return
        }
        let previousLogin = [.enabled, .requiresApproval].contains(SMAppService.mainApp.status)
        var previousCredentials: [String: [String: String]] = [:]
        var written: [String] = []
        var loginChanged = false
        do {
            // 先读取全部回滚数据；任何授权/读取失败都不会覆盖已有凭据。
            for id in credentials.keys { previousCredentials[id] = try Self.readCredentials(id: id) }
            for (id, value) in credentials {
                try Self.storeCredentials(id: id, value: value as? [String: String])
                written.append(id)
            }
            if login != previousLogin {
                if login { try SMAppService.mainApp.register() }
                else { try SMAppService.mainApp.unregister() }
                loginChanged = true
            }
            try selectionMonitor.configure(automatic: automatic, excludedApps: Set(excluded.keys), shortcuts: shortcuts)
            // 截图导出仍读独立键；保存设置时与 preferences 字典同步，避免双源互相覆盖。
            if let directory = settings[AppConstants.screenshotSaveDirectoryKey] as? String, !directory.isEmpty {
                UserDefaults.standard.set(directory, forKey: AppConstants.screenshotSaveDirectoryKey)
            } else {
                UserDefaults.standard.removeObject(forKey: AppConstants.screenshotSaveDirectoryKey)
            }
            // 凭据与系统副作用成功后才保存不含密钥的偏好。
            UserDefaults.standard.set(settings, forKey: AppConstants.preferencesKey)
            // 只有配置事务提交后广播外观，所有已打开引擎共享同一已保存快照。
            NotificationCenter.default.post(name: AppConstants.appearanceChangedNotification, object: nil)
            screenshot.toolbarPreferencesChanged()
            // 菜单由主执行器管理，偏好事务完成后在其执行器上刷新可见状态。
            DispatchQueue.main.async { StatusBarController.shared.updateAutomatic(automatic) }
            result(nil)
        } catch {
            let originalError = error
            do {
                for id in written.reversed() {
                    // 不存在与空字典分开表示，失败时恢复原始钥匙串状态。
                    try Self.storeCredentials(id: id, value: previousCredentials[id])
                }
                if loginChanged {
                    if previousLogin { try SMAppService.mainApp.register() }
                    else { try SMAppService.mainApp.unregister() }
                }
            } catch {
                result(FlutterError(code: AppConstants.rollbackFailedError, message: "设置未保存，无法恢复部分系统设置或凭据，请检查钥匙串与登录项。", details: nil)); return
            }
            result(FlutterError(code: AppConstants.settingsFailedError, message: originalError.localizedDescription, details: nil))
        }
    }

    /// id 为服务账户；从当前用户钥匙串读取 JSON 凭据，未保存返回 nil。
    static func readCredentials(id: String) throws -> [String: String]? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: AppConstants.credentialsKeychainService,
            kSecAttrAccount as String: id,
            kSecReturnData as String: true,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data,
              let credentials = (try? JSONSerialization.jsonObject(with: data)) as? [String: String] else {
            throw NSError(domain: AppConstants.keychainErrorDomain, code: Int(status), userInfo: [
                NSLocalizedDescriptionKey: "无法读取翻译服务凭据，请检查钥匙串访问权限。",
            ])
        }
        return credentials
    }

    /// id 为服务账户，value 为凭据字典或 nil（删除）；只操作当前用户钥匙串，无返回值。
    static func storeCredentials(id: String, value: [String: String]?) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: AppConstants.credentialsKeychainService,
            kSecAttrAccount as String: id,
        ]
        var status: OSStatus
        if let value {
            let attributes = [kSecValueData as String: try JSONSerialization.data(withJSONObject: value)]
            status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
            if status == errSecItemNotFound {
                status = SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil)
            }
        } else {
            status = SecItemDelete(query as CFDictionary)
            if status == errSecItemNotFound { return }
        }
        guard status == errSecSuccess else {
            throw NSError(domain: AppConstants.keychainErrorDomain, code: Int(status), userInfo: [
                NSLocalizedDescriptionKey: "无法保存或删除翻译服务凭据，请检查钥匙串访问权限。",
            ])
        }
    }

    /// result 为通道回调，work 为逐像素处理大图的工作；在后台执行，回到主线程返回结果或 compose_failed 错误（#109）。
    private func composeInBackground(_ result: @escaping FlutterResult, _ work: @escaping () throws -> Any) {
        DispatchQueue.global(qos: .userInitiated).async {
            let value: Any
            do {
                value = try work()
            } catch {
                value = FlutterError(code: AppConstants.composeFailedError, message: error.localizedDescription, details: nil)
            }
            DispatchQueue.main.async { result(value) }
        }
    }

    /// call为附属窗口请求；先交给本进程的系统能力（handle），handle 未实现的方法转主Dart引擎，通过result返回结果（#120）。
    /// 跨引擎业务方法表只在主引擎的 lib/main.dart 维护一份；系统能力与业务方法不能同名，否则会在本地处理。
    func routeWindowRequest(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        handle(call) { [weak self] value in
            // FlutterMethodNotImplemented 是哨兵对象，按身份比较。
            guard let self, (value as? NSObject) === FlutterMethodNotImplemented else {
                result(value)
                return
            }
            // requestApplication只跨越引擎边界；业务状态由主引擎所属模块管理。
            self.requestApplication(call.method, arguments: call.arguments, result: result)
        }
    }

    /// method/arguments为菜单或窗口的业务请求；转到主Dart引擎，由result返回所属模块的结果。
    func requestApplication(_ method: String, arguments: Any? = nil, result: @escaping FlutterResult) {
        methods!.invokeMethod(method, arguments: arguments, result: result)
    }

    /// point 为屏幕坐标；返回它是否位于当前可见浮层内。
    func overlayContains(_ point: NSPoint) -> Bool {
        overlay.contains(point)
    }

    /// text 为选中文字，gesture 为手势，x/y 为屏幕锚点，sourcePID 为来源进程、sourceAppName为采集时冻结的应用名；发送新会话，无返回值。
    func emitSelectionCaptured(text: String, gesture: String, x: CGFloat, y: CGFloat, sourcePID: pid_t, sourceAppName: String?) {
        guard !retainsResult || SelectionGesture(rawValue: gesture)?.isExplicit == true else { return }
        // 只有显式热键可以替换保留的结果；被动手势不打断阅读或正在进行的翻译。
        retainsResult = false
        // 结束被替换的会话，迟到命令仍由新旧 sessionId 隔离。
        invalidateSelection()
        let sessionId = UUID().uuidString
        currentSessionId = sessionId
        sourceProcessIdentifier = sourcePID
        emit([
            "type": AppConstants.selectionCapturedEvent,
            "sessionId": sessionId,
            "text": text,
            "gesture": gesture,
            // 此刻的来源进程才对应原文；不保存 PID、窗口或选区坐标到历史。
            "sourceAppName": (sourceAppName as Any?) ?? NSNull(),
            "x": x,
            "y": y,
        ])
    }

    /// processIdentifier 为新前台进程；离开来源时只结束未展开的按钮，无返回值。
    func sourceApplicationChanged(to processIdentifier: pid_t?) {
        guard sourceProcessIdentifier != processIdentifier else { return }
        // 显示非激活面板不会改变前台 PID，因此不会误关自身浮层。
        invalidateSelection()
    }

    /// eventType 为失效或 Escape 类型；被动失效只关闭按钮，Escape 关闭所有状态，无返回值。
    func invalidateSelection(eventType: String = AppConstants.selectionInvalidatedEvent) {
        guard !retainsResult || eventType == AppConstants.escapePressedMethod else { return }
        selectionReadTask?.cancel()
        selectionReadTask = nil
        guard let sessionId = currentSessionId else { return }
        currentSessionId = nil
        sourceProcessIdentifier = nil
        retainsResult = false
        overlay.hide(sessionId: sessionId)
        emit([
            "type": eventType,
            "sessionId": sessionId,
        ])
    }

    /// payload 为带类型和会话 ID 的事件字典；发送至 Dart，无返回值。
    func emit(_ payload: [String: Any]) {
        eventSink?(payload)
    }

    /// arguments 为未使用的订阅参数，events 为 Dart 事件接收端；保存订阅并返回 nil。
    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        eventSink = events
        return nil
    }

    /// arguments 为未使用的取消参数；移除事件接收端并返回 nil。
    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        eventSink = nil
        return nil
    }
}
