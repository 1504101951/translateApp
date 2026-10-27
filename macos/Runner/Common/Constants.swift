import Foundation
import AppKit
import Carbon

/// 采集目标协议；rawValue与Dart CaptureTarget.name逐项对应。
enum CaptureTarget: String { case region, application, display }

/// 连续采集的公开阶段；原始值与Dart CapturePhase一致。
enum CapturePhase: String {
    case idle, preparing, recording, pausing, paused, finalizing, videoReady, scrolling, imageReady, converting, failed
}

/// 实时翻译会话阶段；rawValue 与 Dart LiveRegionPhase.name 逐项对应（#127）。
enum LiveRegionPhase: String { case idle, running, paused, ended, discarded }

/// 发给主引擎的实时翻译命令；rawValue 与 Dart LiveRegionAction.name 逐项对应（#127）。
enum LiveRegionAction: String { case start, pause, resume, end, discard, captureFailed }

/// 录制结果的导出类型；rawValue 是 converting 阶段 exporting 详情值与保存分类，与Dart RecordingExport.name逐项对应（#110）。
enum RecordingExport: String {
    case mp4, gif, apng, webm

    /// 无参数；返回保存文件的扩展名，APNG 的标准扩展名为 png。
    var fileExtension: String { self == .apng ? "png" : rawValue }
}

/// 长截图滚动方式偏好值；rawValue 与 Dart ScrollCaptureMode.name 逐项对应，缺省为手动（#112）。
enum ScrollCaptureMode: String {
    case manual, automatic
}

/// 原生侧通道名、方法名、错误码、偏好键与平台视图类型等协议值；字面量与 Dart common/constants 下同名值一致，改名须两端同步。
/// 只定义 Swift 端代码（含测试）实际使用的值。
enum AppConstants {
    /// 独立引擎入口就绪确认；五秒预算只覆盖入口执行，不等待首帧或业务加载。
    static let windowStartupChannel = "translateapp/window_startup"
    static let windowReadyMethod = "windowReady"
    /// #120 的有限等待策略；实测条件与样本见工单，若新增入口或启动负载变化需重新测量。
    static let windowStartupTimeout: TimeInterval = 5

    /// 连续采集独立通道与多引擎入口，和Dart常量一致。
    static let captureChannel = "translateapp/capture"
    static let captureEntrypoint = "captureMain"
    /// 实时翻译 SCStream 的已批准供帧间隔，单位毫秒；只节流系统输出，不保证固定帧率。
    static let liveCaptureMinIntervalMs = 200
    static let previewLiveRegionMethod = "previewLiveRegion"
    static let cancelLivePreviewMethod = "cancelLivePreview"
    static let liveRegionCommandMethod = "liveRegionCommand"
    static let liveRegionOcrMethod = "liveRegionOcr"
    static let publishLiveRegionMethod = "publishLiveRegion"
    static let captureVideoPreview = "translateapp/capture_video_preview"
    /// Spec #67中的采集工具尺寸，单位为屏幕逻辑点。
    static let captureControlSize = NSSize(width: 320, height: 84)
    static let captureShadeOpacity: CGFloat = 0.6
    static let captureControlGap: CGFloat = 8
    /// Issue #87长截图过程提示：沿用#67文字反馈的最大宽、内边距与圆角，距选区8pt，显示1000ms。
    static let scrollHintMaxWidth: CGFloat = 240
    static let scrollHintPadding = NSSize(width: 12, height: 5)
    static let scrollHintRadius: CGFloat = 8
    static let scrollHintDurationMs = 1000
    /// Issue #87实时缩略图：外框宽160pt含4pt内边距，图像最大高240pt、圆角4pt，回退目标框2pt。
    static let scrollPreviewWidth: CGFloat = 160
    static let scrollPreviewInset: CGFloat = 4
    static let scrollPreviewMaxImageHeight: CGFloat = 240
    static let scrollPreviewImageRadius: CGFloat = 4
    static let scrollPreviewTargetLine: CGFloat = 2
    /// 右侧七个32pt按钮、12pt间距和8pt内边距（7×32+6×12+16）；与Dart工具栏尺寸一致。
    static let captureResultToolbarWidth: CGFloat = 48
    static let captureResultToolbarHeight: CGFloat = 312
    /// 录制最高帧率：ScreenCaptureKit 最小帧间隔为其倒数；WebM 编码以此作为码率分配的帧率提示（#110）。
    static let recordingFramesPerSecond: Int32 = 30
    /// WebM 编码页面的自定义 URL 协议名；编码页面与待编码帧都经此协议交给不挂窗口的 WKWebView（#110）。
    static let webMEncoderScheme = "translateapp-webm"
    /// 录制结果使用系统窗口控制；标题栏尺寸由AppKit按此样式实际计算。
    static let captureResultWindowStyle: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable]
    static let getCaptureStateMethod = "getCaptureState"
    static let captureStateChangedMethod = "captureStateChanged"
    static let prepareCaptureMethod = "prepareCapture"
    /// 截图准备阶段的显示器与应用窗口预览协议。
    static let previewCaptureTargetMethod = "previewCaptureTarget"
    static let captureSourcesMethod = "captureSources"
    static let stopCaptureMethod = "stopCapture"
    static let setCapturePausedMethod = "setCapturePaused"
    static let cancelCaptureMethod = "cancelCapture"
    static let saveRecordingMethod = "saveRecording"
    static let previewRecordingMethod = "previewRecording"
    static let exportRecordingGIFMethod = "exportRecordingGIF"
    /// exportRecordingAPNG 协议值；按 GIF 设置导出 APNG（#110），与Dart常量同步。
    static let exportRecordingAPNGMethod = "exportRecordingAPNG"
    /// exportRecordingWebM 协议值；按原分辨率与原帧时间导出 VP8 WebM（#110），与Dart常量同步。
    static let exportRecordingWebMMethod = "exportRecordingWebM"
    /// trimRecording 协议值；结果页播放器进入系统裁剪模式，确认后记录区间（#110），与Dart常量同步。
    static let trimRecordingMethod = "trimRecording"
    /// cancelRecordingExport 协议值；取消正在进行的 MP4/GIF/APNG/WebM 转换，与Dart常量同步。
    static let cancelRecordingExportMethod = "cancelRecordingExport"
    static let captureFailedError = "capture_failed"
    static let saveDrawingPreferencesMethod = "saveDrawingPreferences"
    /// saveRecordingOptions 协议值；截图引擎经主引擎设置队列保存录制延时与点击高亮（#129），与Dart常量同步。
    static let saveRecordingOptionsMethod = "saveRecordingOptions"
    static let screenshotDrawingKey = "screenshotDrawing"
    /// screenshotConfirmAction 偏好键；确认截图时的动作，随截图快照与工具栏变更通知交给截图引擎（#111），与Dart常量同步。
    static let screenshotConfirmActionKey = "screenshotConfirmAction"
    static let historyChangedMethod = "historyChanged"
    static let historyChangedNotification = Notification.Name("translateapp.historyChanged")

    /// 截图对角光标的受控协议轴，与Dart ResizeCursorAxes一致。
    static let setResizeCursorMethod = "setResizeCursor"
    static let setBrushCursorMethod = "setBrushCursor"
    static let resizeNorthWestSouthEast = "nwse"
    static let resizeNorthEastSouthWest = "nesw"
    static let screenshotTextInputMethod = "screenshotTextInput"
    static let screenshotToolbarHiddenKey = "screenshotToolbarHidden"
    static let screenshotToolbarOrderKey = "screenshotToolbarOrder"
    static let screenshotToolbarChildrenKey = "screenshotToolbarChildren"
    static let screenshotToolbarShortcutsKey = "screenshotToolbarShortcuts"
    /// 截图局部工具配置独立广播，不替换截图编辑草稿。
    static let screenshotToolbarChangedMethod = "screenshotToolbarChanged"
    static let screenshotToolbarActionMethod = "screenshotToolbarAction"
    /// 跨引擎外观模式与通知名称；与Dart AppearanceModes一致。
    static let appearanceSystem = "system"
    static let appearanceLight = "light"
    static let appearanceDark = "dark"
    static let appearanceChangedNotification = Notification.Name("TranslateAppAppearanceChanged")
    static let settingsChannel = "translateapp/settings"
    static let screenshotChannel = "translateapp/screenshot"
    static let screenshotEntrypoint = "screenshotMain"
    /// 附属窗口的 Flutter 引擎名，经 WindowEngine 创建时使用（#120、#124）。
    static let screenshotEngineName = "screenshot"
    static let settingsEngineName = "settings"
    static let permissionWizardEngineName = "permission-wizard"
    static let historyEngineName = "history"
    static let permissionWizardFinishedKey = "permissionWizardFinished"
    static let screenshotSaveDirectoryKey = "screenshotSaveDirectory"
    /// GIF导出偏好；最大宽度缺省表示原始宽度。
    static let gifFramesPerSecondKey = "gifFramesPerSecond"
    /// liveRecording 协议值；实时翻译开始时读取，决定是否同步录制。与Dart常量同步。
    static let liveRecordingKey = "liveRecording"
    /// screenshotIncludesCursor 协议值；区域截图冻结帧是否包含鼠标指针，Dart 设置写入、冻结时读取（#105）。与Dart常量同步。
    static let screenshotIncludesCursorKey = "screenshotIncludesCursor"
    /// recordingShowsClicks 协议值；区域与显示器录制是否由系统绘制鼠标点击高亮，Dart 设置写入、开始录制时读取（#110）。与Dart常量同步。
    static let recordingShowsClicksKey = "recordingShowsClicks"
    /// scrollCaptureMode 偏好键；长截图滚动方式 manual/automatic，开始长截图时读取（#112），与Dart常量同步。
    static let scrollCaptureModeKey = "scrollCaptureMode"
    /// 上次导出的截图选区（显示器 ID、显示器像素尺寸与选区像素矩形），只由原生读写（#105）。
    static let lastScreenshotRegionKey = "lastScreenshotRegion"
    /// recordingDelay 偏好键；开始录制前的倒计时秒数，随截图快照与工具栏变更通知交给截图引擎（#129），与Dart常量同步。
    static let recordingDelayKey = "recordingDelay"
    /// 录制延时的可选秒数，0 为不延时；prepareCapture 的 delay 只接受这些值（#129），与Dart常量同步。
    static let recordingDelays = [0, 3, 5, 10]
    static let gifMaximumWidthKey = "gifMaximumWidth"
    /// Escape 键的硬件键码（kVK_Escape）。
    static let escapeKeyCode: UInt16 = 53
    /// 全局快捷键必须包含其中至少一个修饰键（Carbon 修饰键位）。
    static let shortcutRequiredModifiers = UInt32(cmdKey | optionKey | controlKey)
    /// 全局快捷键允许出现的全部修饰键（Carbon 修饰键位）。
    static let shortcutAllowedModifiers = shortcutRequiredModifiers | UInt32(shiftKey)
    /// Return 键的硬件键码（kVK_Return）。
    static let returnKeyCode: UInt16 = 36
    /// 小键盘 Enter 键的硬件键码（kVK_ANSI_KeypadEnter）。
    static let keypadEnterKeyCode: UInt16 = 76
    static let confirmScreenshotMethod = "confirmScreenshot"
    /// 方向键硬件键码（kVK_LeftArrow…kVK_UpArrow）到截图像素单位方向的映射（#106）。
    static let arrowKeyDirections: [UInt16: (dx: Int, dy: Int)] = [123: (-1, 0), 124: (1, 0), 125: (0, 1), 126: (0, -1)]
    /// nudgeScreenshotCrop 协议值；原生按键路由把方向键交给截图引擎微调选区，参数 id、dx、dy、shift、option（#106），与Dart常量同步。
    static let nudgeScreenshotCropMethod = "nudgeScreenshotCrop"
    static let appReadyMethod = "appReady"
    static let appearanceChangedMethod = "appearanceChanged"
    static let applicationSupportPathMethod = "applicationSupportPath"
    static let applySettingsMethod = "applySettings"
    static let automaticKey = "automatic"
    static let badAppError = "bad_app"
    static let badArgsError = "bad_args"
    static let badSettingsError = "bad_settings"
    static let chooseExcludedAppMethod = "chooseExcludedApp"
    static let chooseScreenshotDirectoryMethod = "chooseScreenshotDirectory"
    static let closePermissionWizardMethod = "closePermissionWizard"
    static let closeScreenshotMethod = "closeScreenshot"
    static let copyScreenshotMethod = "copyScreenshot"
    static let copyTextMethod = "copyText"
    static let copyFailedError = "copy_failed"
    static let credentialIdsMethod = "credentialIds"
    static let detectLanguageMethod = "detectLanguage"
    static let dragOverlayMethod = "dragOverlay"
    static let escapePressedMethod = "escapePressed"
    static let excludedAppsKey = "excludedApps"
    static let finishPermissionWizardMethod = "finishPermissionWizard"
    static let getAppearanceMethod = "getAppearance"
    static let getScreenshotMethod = "getScreenshot"
    static let glassAppearanceKey = "glassAppearance"
    static let glassOpacityKey = "glassOpacity"
    static let hideOverlayMethod = "hideOverlay"
    static let historyEntrypoint = "historyMain"
    static let isCurrentScreenshotMethod = "isCurrentScreenshot"
    static let keychainFailedError = "keychain_failed"
    /// 凭据在钥匙串中的服务名；凭据列举、读取与写入共用，改动会使已存凭据读不到（#122）。
    static let credentialsKeychainService = "com.coolyang.translateApp.credentials"
    static let launchAtLoginKey = "launchAtLogin"
    static let loadSettingsMethod = "loadSettings"
    static let ocrEmptyError = "ocr_empty"
    static let ocrFailedError = "ocr_failed"
    static let openAccessibilityMethod = "openAccessibility"
    static let openLoginItemsMethod = "openLoginItems"
    /// openLink 协议值；截图识别结果中的链接交给默认浏览器（#108），与Dart常量同步。
    static let openLinkMethod = "openLink"
    /// 识别结果中允许打开的链接协议；其他协议只可复制（#108），与Dart常量同步。
    static let openableLinkSchemes: Set<String> = ["http", "https"]
    static let permissionStatusChangedMethod = "permissionStatusChanged"
    static let permissionWizardEntrypoint = "permissionWizardMain"
    static let permissionWizardStatusMethod = "permissionWizardStatus"
    static let pinScreenshotMethod = "pinScreenshot"
    static let preferencesKey = "preferences"
    static let readCredentialsMethod = "readCredentials"
    static let readSelectionForTranslationMethod = "readSelectionForTranslation"
    static let recognizeBlocksMethod = "recognizeBlocks"
    static let recognizeTextMethod = "recognizeText"
    static let recordShortcutMethod = "recordShortcut"
    static let redoPressedMethod = "redoPressed"
    static let refreshSettingsMethod = "refreshSettings"
    static let requestScreenAccessMethod = "requestScreenAccess"
    static let retainOverlayMethod = "retainOverlay"
    /// replaceSelection 协议值；输入翻译完成后把译文粘贴回来源应用，与Dart常量同步。
    static let replaceSelectionMethod = "replaceSelection"
    /// 输入翻译粘贴后等待来源应用读取剪贴板的时长，之后才还原原剪贴板（#99）。
    static let pasteRestoreDelay = Duration.milliseconds(500)
    static let revealFileMethod = "revealFile"
    static let rollbackFailedError = "rollback_failed"
    static let saveScreenshotMethod = "saveScreenshot"
    static let saveFailedError = "save_failed"
    static let screenshotChangedMethod = "screenshotChanged"
    static let screenshotShortcutKeyCodeKey = "screenshotShortcutKeyCode"
    static let screenshotShortcutLabelKey = "screenshotShortcutLabel"
    static let screenshotShortcutModifiersKey = "screenshotShortcutModifiers"
    static let selectionCapturedEvent = "selectionCaptured"
    static let selectionInvalidatedEvent = "selectionInvalidated"
    static let setOverlaySizeMethod = "setOverlaySize"
    static let settingsEntrypoint = "settingsMain"
    static let settingsFailedError = "settings_failed"
    static let shortcutKeyCodeKey = "shortcutKeyCode"
    static let shortcutLabelKey = "shortcutLabel"
    static let shortcutModifiersKey = "shortcutModifiers"
    /// inputShortcutKeyCode 协议值；输入翻译快捷键键码，与Dart常量同步。
    static let inputShortcutKeyCodeKey = "inputShortcutKeyCode"
    /// inputShortcutLabel 协议值；输入翻译快捷键显示名，与Dart常量同步。
    static let inputShortcutLabelKey = "inputShortcutLabel"
    /// inputShortcutModifiers 协议值；输入翻译快捷键修饰键，与Dart常量同步。
    static let inputShortcutModifiersKey = "inputShortcutModifiers"
    static let shortcutInvalidError = "shortcut_invalid"
    static let showOverlayMethod = "showOverlay"
    static let staleCaptureError = "stale_capture"
    static let systemStatusMethod = "systemStatus"
    /// rememberScreenshotRegion 协议值；截图导出成功后 Dart 发送选区像素矩形，供「截取上次区域」复用（#105）。与Dart常量同步。
    static let rememberScreenshotRegionMethod = "rememberScreenshotRegion"
    /// recordScreenshotHistory 协议值；截图导出成功后转发主引擎记录，与Dart常量同步。
    static let recordScreenshotHistoryMethod = "recordScreenshotHistory"
    /// stitchScreenshots 协议值；按顺序拼接截图历史图片（#109），与Dart常量同步。
    static let stitchScreenshotsMethod = "stitchScreenshots"
    /// splitScreenshot 协议值；按高度等分一张截图历史图片（#109），与Dart常量同步。
    static let splitScreenshotMethod = "splitScreenshot"
    /// compareScreenshots 协议值；逐像素比较两张截图历史图片（#109），与Dart常量同步。
    static let compareScreenshotsMethod = "compareScreenshots"
    /// compose_failed 协议值；拼接、拆分或比较失败（#109），与Dart常量同步。
    static let composeFailedError = "compose_failed"
    /// openFile 协议值；用系统默认应用打开文件，与Dart常量同步。
    static let openFileMethod = "openFile"
    /// copyImageFile 协议值；把 PNG 文件复制到剪贴板，与Dart常量同步。
    static let copyImageFileMethod = "copyImageFile"
    /// lookupDefinition 协议值；查询 macOS 词典释义，与Dart常量同步。
    static let lookupDefinitionMethod = "lookupDefinition"
    /// vocabularyList 协议值；历史窗口读取生词本，转发主引擎，与Dart常量同步。
    static let vocabularyListMethod = "vocabularyList"
    /// saveTextFile 协议值；经系统保存面板保存文本文件，与Dart常量同步。
    static let saveTextFileMethod = "saveTextFile"
    /// toggleSpeech 协议值；朗读或停止朗读卡片一栏文字，与Dart常量同步。
    static let toggleSpeechMethod = "toggleSpeech"
    /// stopSpeech 协议值；停止当前朗读，与Dart常量同步。
    static let stopSpeechMethod = "stopSpeech"
    /// systemTranslate 协议值；Apple 系统翻译一组段落，与Dart常量同步。
    static let systemTranslateMethod = "systemTranslate"
    /// cancelSystemTranslation 协议值；按 requestId 取消系统翻译，与Dart常量同步。
    static let cancelSystemTranslationMethod = "cancelSystemTranslation"
    /// systemTranslationStatus 协议值；查询语言对安装状态，与Dart常量同步。
    static let systemTranslationStatusMethod = "systemTranslationStatus"
    /// 系统翻译语言对状态：语言包已安装；与Dart SystemTranslationStatus同步。
    static let systemTranslationInstalled = "installed"
    /// 系统翻译语言对状态：支持但语言包未下载；与Dart SystemTranslationStatus同步。
    static let systemTranslationSupported = "supported"
    /// 系统翻译语言对状态：不支持；与Dart SystemTranslationStatus同步。
    static let systemTranslationUnsupported = "unsupported"
    /// 系统翻译高保真策略；与Dart SystemTranslationStrategy同步，其余值按低延迟处理。
    static let systemTranslationHighFidelity = "highFidelity"
    static let toggleAutomaticMethod = "toggleAutomatic"
    static let translatePlainTextMethod = "translatePlainText"
    /// translate_failed 协议值；与Dart常量同步。
    static let translateFailedError = "translate_failed"
    /// translation_not_installed 协议值；系统翻译语言包未下载，与Dart常量同步。
    static let translationNotInstalledError = "translation_not_installed"
    /// translation_unsupported 协议值；系统翻译不支持该语言对，与Dart常量同步。
    static let translationUnsupportedError = "translation_unsupported"
    static let appearanceChannel = "translateapp/appearance"
    static let macosChannel = "translateapp/macos"
    static let macosEventsChannel = "translateapp/macos/events"
    static let nativeGlassViewType = "translateapp/native-glass"
    static let undoPressedMethod = "undoPressed"

    /// App 在用户 Application Support 下的数据目录名；历史库与 MCP socket 共用。
    static let applicationSupportFolderName = "TranslateApp"
    /// 本应用 NSError 的统一域名。
    static let errorDomain = "TranslateApp"
    /// 钥匙串读写失败的 NSError 域名。
    static let keychainErrorDomain = "TranslateApp.Keychain"
    /// 缺少屏幕录制权限时显示给用户的统一提示。
    static let screenRecordingRequiredMessage = "需要屏幕录制权限，请在系统设置中允许 TranslateApp 后重试。"
    /// 长图结果窗的最小内容尺寸，单位点。
    static let longScreenshotResultMinimumSize = NSSize(width: 320, height: 240)
    /// 无参数；返回用户 Application Support 下的 App 数据目录（不保证已创建），历史库与 MCP socket 共用。
    static var applicationSupportURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(applicationSupportFolderName, isDirectory: true)
    }
    /// MCP 接口（#96、#68「MCP 接口边界」）：stdio helper 与 App 共用的名称、图片预算和英文协议文案。
    /// helper 可执行文件名，位于 App 包 Contents/MacOS。
    static let mcpHelperName = "translateapp-mcp"
    /// MCP serverInfo.name 与客户端配置中的服务名。
    static let mcpServerName = "translateapp"
    /// helper 连接 App 的 Unix domain socket 文件名，位于 Application Support 数据目录。
    static let mcpSocketFileName = "mcp.sock"
    /// 返回图片长边上限，单位像素（#96 决策 3）。
    static let mcpImageMaxEdge = 1568
    /// Claude 视觉 token 的切块边长，单位像素；token 数为 ⌈宽/28⌉×⌈高/28⌉（#96 决策 3）。
    static let mcpTokenPatch = 28
    /// 连接不到 App 时返回给 agent 的错误。
    static let mcpNotRunningMessage = "TranslateApp is not running."
    /// 设置中 MCP 开关关闭时返回给 agent 的错误。
    static let mcpDisabledMessage = "MCP is disabled in TranslateApp settings."
    /// 屏幕录制授权被拒绝时返回给 agent 的错误。
    static let mcpPermissionMessage = "TranslateApp lacks Screen Recording permission. Allow it in System Settings > Privacy & Security > Screen Recording, then retry."
    /// 运行中的 App 与 helper 版本不一致、请求或结果结构无法解析时返回给 agent 的错误。
    static let mcpVersionMismatchMessage = "TranslateApp and its MCP helper are different versions. Restart TranslateApp, then retry."
    /// OCR 没有识别到文字时返回给 agent 的文本。
    static let mcpNoTextMessage = "No text recognized."
    /// 截图类工具的矩形超出参考清晰度图片时的错误；reference 为清晰度名，display 为显示器序号，width/height 为该图尺寸。
    static func mcpRectangleOutOfRangeMessage(reference: String, display: Int, width: Int, height: Int) -> String {
        "Rectangle exceeds the \(reference) image of display \(display) (\(width)×\(height))."
    }
    /// capture_window 找不到窗口时的错误；windowID 为请求的窗口编号。
    static func mcpWindowNotFoundMessage(windowID: UInt32) -> String {
        "window_id \(windowID) not found; call list_windows again."
    }
    /// 截图失败时的错误；reason 为失败原因描述。
    static func mcpCaptureFailedMessage(_ reason: String) -> String { "Capture failed: \(reason)" }
    /// 显示器序号越界时的错误；index 为请求序号，count 为当前显示器数量。
    static func mcpDisplayOutOfRangeMessage(index: Int, count: Int) -> String {
        "display_index \(index) is out of range; \(count) displays available."
    }
    /// 工具调用包含未声明参数时的错误；name 为参数名。
    static func mcpUnknownArgumentMessage(_ name: String) -> String { "Unknown argument: \(name)" }
    /// 工具调用缺少必填参数时的错误；key 为参数名。
    static func mcpMissingArgumentMessage(_ key: String) -> String { "Missing required argument: \(key)" }
    /// 响应无法序列化为 JSON 时的 JSON-RPC 内部错误文案。
    static let mcpInternalErrorMessage = "Internal error: response is not JSON-serializable."
    /// helper 无法连接 App 时的错误；reason 为失败原因描述。
    static func mcpConnectFailedMessage(_ reason: String) -> String { "Cannot connect to TranslateApp: \(reason)" }
    /// App 未返回结果就关闭连接时的错误。
    static let mcpConnectionClosedMessage = "TranslateApp closed the connection without a result."
    /// helper 与 App 通信中断时的错误；reason 为失败原因描述。
    static func mcpCommunicationFailedMessage(_ reason: String) -> String { "Communication with TranslateApp failed: \(reason)" }
    /// 请求不是合法 JSON 时的 JSON-RPC 错误文案。
    static let mcpParseErrorMessage = "Parse error"
    /// 请求的 JSON-RPC 方法不存在时的错误；method 为方法名。
    static func mcpMethodNotFoundMessage(_ method: String) -> String { "Method not found: \(method)" }
    /// 调用的工具不存在时的错误；name 为工具名。
    static func mcpUnknownToolMessage(_ name: String) -> String { "Unknown tool: \(name)" }
    /// 截图数据无法解码为像素时的错误。
    static let mcpPixelReadFailedMessage = "Unable to read screenshot pixels."
    /// 截图无法缩放到目标尺寸时的错误。
    static let mcpScaleFailedMessage = "Unable to scale screenshot."
    /// 设置中「允许 agent 截图」开关的偏好键；与 Dart PreferenceKeys.mcpEnabled 一致。
    static let mcpEnabledKey = "mcpEnabled"
    /// 设置页读取 helper 完整路径的方法；与 Dart MethodNames.mcpHelperPath 一致。
    static let mcpHelperPathMethod = "mcpHelperPath"
    /// 截图类工具执行期间的菜单栏图标与最短保持时间（#96 待确认的界面数值）。
    static let mcpCaptureSymbol = "camera.viewfinder"
    static let mcpCaptureIndicatorMinimum = Duration.milliseconds(1000)
}

/// 跨端选区手势；rawValue与Dart SelectionGestureTypes保持一致。
enum SelectionGesture: String {
    case drag
    case doubleClick
    case tripleClick
    case selectAll
    case keyboard
    case hotkey
    case inputHotkey

    /// 无参数；返回是否为用户按下全局快捷键发起的明确请求，明确请求允许一次性复制读取并替换保留的结果。
    var isExplicit: Bool { self == .hotkey || self == .inputHotkey }

    /// keyCode 为硬件键码，modifiers 为修饰键；返回创建文本选区的手势或 nil。
    static func keyboardGesture(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> SelectionGesture? {
        let flags = modifiers.intersection([.command, .shift, .option, .control])
        if keyCode == 0, flags == .command { return .selectAll }
        // Shift 配合方向/Home/End/Page 键覆盖按字、按词、按行及全文扩选。
        let navigationKeys: Set<UInt16> = [115, 116, 119, 121, 123, 124, 125, 126]
        if flags.contains(.shift), navigationKeys.contains(keyCode) { return .keyboard }
        return nil
    }
}

/// 全局热键用途；三者在同一注册事务中校验，偏好键给出各自的键码、修饰键与显示名。
enum GlobalHotKey: CaseIterable {
    case translate
    case input
    case screenshot

    /// 无参数；返回该用途键码在偏好字典中的键。
    var keyCodeKey: String {
        switch self {
        case .translate: AppConstants.shortcutKeyCodeKey
        case .input: AppConstants.inputShortcutKeyCodeKey
        case .screenshot: AppConstants.screenshotShortcutKeyCodeKey
        }
    }

    /// 无参数；返回该用途修饰键在偏好字典中的键。
    var modifiersKey: String {
        switch self {
        case .translate: AppConstants.shortcutModifiersKey
        case .input: AppConstants.inputShortcutModifiersKey
        case .screenshot: AppConstants.screenshotShortcutModifiersKey
        }
    }

    /// 无参数；返回该用途显示名在偏好字典中的键。
    var labelKey: String {
        switch self {
        case .translate: AppConstants.shortcutLabelKey
        case .input: AppConstants.inputShortcutLabelKey
        case .screenshot: AppConstants.screenshotShortcutLabelKey
        }
    }
}

/// MCP 工具；rawValue 为协议工具名（#96），均无需用户操作。
enum MCPTool: String, CaseIterable {
    case listDisplays = "list_displays"
    case listWindows = "list_windows"
    case captureScreen = "capture_screen"
    case captureRect = "capture_rect"
    case captureWindow = "capture_window"
}

/// MCP 截图工具的 output 参数；rawValue 为协议取值，缺省为 image。
enum MCPOutput: String, Codable, CaseIterable {
    case image, text, both
}

/// MCP 截图工具的清晰度；rawValue 为协议取值，tokenBudget 为该清晰度的视觉 token 上限（#96 决策 3）。
enum MCPDetail: String, Codable, CaseIterable {
    case low, standard

    var tokenBudget: Int {
        switch self {
        case .low: 512
        case .standard: 1568
        }
    }
}
