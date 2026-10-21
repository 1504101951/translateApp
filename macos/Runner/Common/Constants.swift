import Foundation
import AppKit

/// 连续采集的公开阶段；原始值与Dart CapturePhase一致。
/// 采集目标协议；rawValue与Dart CaptureTarget.name逐项对应。
enum CaptureTarget: String { case region, application, display }

enum CapturePhase: String {
    case idle, preparing, recording, pausing, paused, finalizing, videoReady, scrolling, imageReady, converting, failed
}

/// 原生侧通道名、方法名与偏好键；与 Dart `ChannelNames` / `MethodNames` 对齐。
enum AppConstants {
    /// 连续采集独立通道与多引擎入口，和Dart常量一致。
    static let captureChannel = "translateapp/capture"
    static let captureEntrypoint = "captureMain"
    /// 实时翻译结果窗。画面不进入录屏编码器。
    static let liveRegionChannel = "translateapp/live_region"
    static let liveRegionEntrypoint = "liveRegionMain"
    /// 已批准的初始供帧间隔，单位毫秒。须与 Dart LiveRegionSchedule.captureMinInterval 一致。
    static let liveCaptureMinIntervalMs = 200
    static let previewLiveRegionMethod = "previewLiveRegion"
    static let cancelLivePreviewMethod = "cancelLivePreview"
    static let liveRegionCommandMethod = "liveRegionCommand"
    static let liveRegionOcrMethod = "liveRegionOcr"
    static let liveRegionStateMethod = "liveRegionState"
    static let publishLiveRegionMethod = "publishLiveRegion"
    static let getLiveRegionStateMethod = "getLiveRegionState"
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
    /// 右侧四个32pt按钮、12pt间距和8pt内边距；与Dart工具栏尺寸一致。
    static let captureResultToolbarWidth: CGFloat = 48
    static let captureResultToolbarHeight: CGFloat = 180
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
    static let cancelGIFExportMethod = "cancelGIFExport"
    static let captureFailedError = "capture_failed"
    static let saveDrawingPreferencesMethod = "saveDrawingPreferences"
    static let screenshotDrawingKey = "screenshotDrawing"
    static let historyChangedMethod = "historyChanged"
    static let historyChangedNotification = Notification.Name("translateapp.historyChanged")

    /// 截图对角光标的受控协议轴，与Dart NativeResizeCursor一致。
    static let setResizeCursorMethod = "setResizeCursor"
    static let setBrushCursorMethod = "setBrushCursor"
    static let resizeNorthWestSouthEast = "nwse"
    static let resizeNorthEastSouthWest = "nesw"
    /// 跨引擎外观模式与通知名称；与Dart AppearanceModes一致。
    /// 截图局部工具配置独立广播，不替换截图编辑草稿。
    static let screenshotTextInputMethod = "screenshotTextInput"
    static let screenshotToolbarHiddenKey = "screenshotToolbarHidden"
    static let screenshotToolbarOrderKey = "screenshotToolbarOrder"
    static let screenshotToolbarChildrenKey = "screenshotToolbarChildren"
    static let screenshotToolbarShortcutsKey = "screenshotToolbarShortcuts"
    static let screenshotToolbarChangedMethod = "screenshotToolbarChanged"
    static let screenshotToolbarActionMethod = "screenshotToolbarAction"
    static let appearanceSystem = "system"
    static let appearanceLight = "light"
    static let appearanceDark = "dark"
    static let appearanceChangedNotification = Notification.Name("TranslateAppAppearanceChanged")
    /// 打开历史窗口；平台方法名与Dart一致。
    static let openHistoryMethod = "openHistory"
    /// settingsChannel 的平台约定；调用方共享同一协议或硬件定义。
    static let settingsChannel = "translateapp/settings"
    /// screenshotChannel 的平台约定；调用方共享同一协议或硬件定义。
    static let screenshotChannel = "translateapp/screenshot"
    /// screenshotEntrypoint 的平台约定；调用方共享同一协议或硬件定义。
    static let screenshotEntrypoint = "screenshotMain"
    /// permissionWizardFinishedKey 的平台约定；调用方共享同一协议或硬件定义。
    static let permissionWizardFinishedKey = "permissionWizardFinished"
    /// screenshotSaveDirectoryKey 的平台约定；调用方共享同一协议或硬件定义。
    static let screenshotSaveDirectoryKey = "screenshotSaveDirectory"
    /// GIF导出偏好；最大宽度缺省表示原始宽度。
    static let gifFramesPerSecondKey = "gifFramesPerSecond"
    /// liveRecording 协议值；实时翻译开始时读取，决定是否同步录制。与Dart常量同步。
    static let liveRecordingKey = "liveRecording"
    static let gifMaximumWidthKey = "gifMaximumWidth"
    /// escapeKeyCode 的平台约定；调用方共享同一协议或硬件定义。
    static let escapeKeyCode: UInt16 = 53
    /// returnKeyCode 的平台约定；调用方共享同一协议或硬件定义。
    static let returnKeyCode: UInt16 = 36
    /// keypadEnterKeyCode 的平台约定；调用方共享同一协议或硬件定义。
    static let keypadEnterKeyCode: UInt16 = 76
    /// confirmScreenshotMethod 的平台约定；调用方共享同一协议或硬件定义。
    static let confirmScreenshotMethod = "confirmScreenshot"
    /// appReady 协议值；与Dart常量及持久化调用方同步。
    static let appReadyMethod = "appReady"
    /// appearanceChanged 协议值；与Dart常量及持久化调用方同步。
    static let appearanceChangedMethod = "appearanceChanged"
    /// applicationSupportPath 协议值；与Dart常量及持久化调用方同步。
    static let applicationSupportPathMethod = "applicationSupportPath"
    /// applySettings 协议值；与Dart常量及持久化调用方同步。
    static let applySettingsMethod = "applySettings"
    /// automatic 协议值；与Dart常量及持久化调用方同步。
    static let automaticKey = "automatic"
    /// bad_app 协议值；与Dart常量及持久化调用方同步。
    static let badAppError = "bad_app"
    /// bad_args 协议值；与Dart常量及持久化调用方同步。
    static let badArgsError = "bad_args"
    /// bad_settings 协议值；与Dart常量及持久化调用方同步。
    static let badSettingsError = "bad_settings"
    /// captureRegion 协议值；与Dart常量及持久化调用方同步。
    static let captureRegionMethod = "captureRegion"
    /// chooseExcludedApp 协议值；与Dart常量及持久化调用方同步。
    static let chooseExcludedAppMethod = "chooseExcludedApp"
    /// chooseScreenshotDirectory 协议值；与Dart常量及持久化调用方同步。
    static let chooseScreenshotDirectoryMethod = "chooseScreenshotDirectory"
    /// closePermissionWizard 协议值；与Dart常量及持久化调用方同步。
    static let closePermissionWizardMethod = "closePermissionWizard"
    /// closePin 协议值；与Dart常量及持久化调用方同步。
    static let closePinMethod = "closePin"
    /// closeScreenshot 协议值；与Dart常量及持久化调用方同步。
    static let closeScreenshotMethod = "closeScreenshot"
    /// copyScreenshot 协议值；与Dart常量及持久化调用方同步。
    static let copyScreenshotMethod = "copyScreenshot"
    /// copyText 协议值；与Dart常量及持久化调用方同步。
    static let copyTextMethod = "copyText"
    /// copy_failed 协议值；与Dart常量及持久化调用方同步。
    static let copyFailedError = "copy_failed"
    /// credentialIds 协议值；与Dart常量及持久化调用方同步。
    static let credentialIdsMethod = "credentialIds"
    /// detectLanguage 协议值；与Dart常量及持久化调用方同步。
    static let detectLanguageMethod = "detectLanguage"
    /// dragOverlay 协议值；与Dart常量及持久化调用方同步。
    static let dragOverlayMethod = "dragOverlay"
    /// escapePressed 协议值；与Dart常量及持久化调用方同步。
    static let escapePressedMethod = "escapePressed"
    /// excludedApps 协议值；与Dart常量及持久化调用方同步。
    static let excludedAppsKey = "excludedApps"
    /// finishPermissionWizard 协议值；与Dart常量及持久化调用方同步。
    static let finishPermissionWizardMethod = "finishPermissionWizard"
    /// getAppearance 协议值；与Dart常量及持久化调用方同步。
    static let getAppearanceMethod = "getAppearance"
    /// getScreenshot 协议值；与Dart常量及持久化调用方同步。
    static let getScreenshotMethod = "getScreenshot"
    /// getSettings 协议值；与Dart常量及持久化调用方同步。
    static let getSettingsMethod = "getSettings"
    /// glassAppearance 协议值；与Dart常量及持久化调用方同步。
    static let glassAppearanceKey = "glassAppearance"
    /// glassOpacity 协议值；与Dart常量及持久化调用方同步。
    static let glassOpacityKey = "glassOpacity"
    /// hideOverlay 协议值；与Dart常量及持久化调用方同步。
    static let hideOverlayMethod = "hideOverlay"
    /// historyMain 协议值；与Dart常量及持久化调用方同步。
    static let historyEntrypoint = "historyMain"
    /// historyPage 协议值；与Dart常量及持久化调用方同步。
    static let historyPageMethod = "historyPage"
    /// historyRecording 协议值；与Dart常量及持久化调用方同步。
    static let historyRecordingMethod = "historyRecording"
    /// isCurrentScreenshot 协议值；与Dart常量及持久化调用方同步。
    static let isCurrentScreenshotMethod = "isCurrentScreenshot"
    /// keychain_failed 协议值；与Dart常量及持久化调用方同步。
    static let keychainFailedError = "keychain_failed"
    /// launchAtLogin 协议值；与Dart常量及持久化调用方同步。
    static let launchAtLoginKey = "launchAtLogin"
    /// loadSettings 协议值；与Dart常量及持久化调用方同步。
    static let loadSettingsMethod = "loadSettings"
    /// ocr_empty 协议值；与Dart常量及持久化调用方同步。
    static let ocrEmptyError = "ocr_empty"
    /// ocr_failed 协议值；与Dart常量及持久化调用方同步。
    static let ocrFailedError = "ocr_failed"
    /// openAccessibility 协议值；与Dart常量及持久化调用方同步。
    static let openAccessibilityMethod = "openAccessibility"
    /// openLoginItems 协议值；与Dart常量及持久化调用方同步。
    static let openLoginItemsMethod = "openLoginItems"
    /// permissionStatusChanged 协议值；与Dart常量及持久化调用方同步。
    static let permissionStatusChangedMethod = "permissionStatusChanged"
    /// permissionWizardMain 协议值；与Dart常量及持久化调用方同步。
    static let permissionWizardEntrypoint = "permissionWizardMain"
    /// permissionWizardStatus 协议值；与Dart常量及持久化调用方同步。
    static let permissionWizardStatusMethod = "permissionWizardStatus"
    /// pinScreenshot 协议值；与Dart常量及持久化调用方同步。
    static let pinScreenshotMethod = "pinScreenshot"
    /// preferences 协议值；与Dart常量及持久化调用方同步。
    static let preferencesKey = "preferences"
    /// probeEmitSelection 协议值；与Dart常量及持久化调用方同步。
    static let probeEmitSelectionMethod = "probeEmitSelection"
    /// readCredentials 协议值；与Dart常量及持久化调用方同步。
    static let readCredentialsMethod = "readCredentials"
    /// readSelectionForTranslation 协议值；与Dart常量及持久化调用方同步。
    static let readSelectionForTranslationMethod = "readSelectionForTranslation"
    /// recognizeBlocks 协议值；与Dart常量及持久化调用方同步。
    static let recognizeBlocksMethod = "recognizeBlocks"
    /// recognizeText 协议值；与Dart常量及持久化调用方同步。
    static let recognizeTextMethod = "recognizeText"
    /// recordShortcut 协议值；与Dart常量及持久化调用方同步。
    static let recordShortcutMethod = "recordShortcut"
    /// redoPressed 协议值；与Dart常量及持久化调用方同步。
    static let redoPressedMethod = "redoPressed"
    /// refreshSettings 协议值；与Dart常量及持久化调用方同步。
    static let refreshSettingsMethod = "refreshSettings"
    /// requestAccessibility 协议值；与Dart常量及持久化调用方同步。
    static let requestAccessibilityMethod = "requestAccessibility"
    /// requestScreenAccess 协议值；与Dart常量及持久化调用方同步。
    static let requestScreenAccessMethod = "requestScreenAccess"
    /// retainOverlay 协议值；与Dart常量及持久化调用方同步。
    static let retainOverlayMethod = "retainOverlay"
    /// replaceSelection 协议值；输入翻译完成后把译文粘贴回来源应用，与Dart常量同步。
    static let replaceSelectionMethod = "replaceSelection"
    /// 输入翻译粘贴后等待来源应用读取剪贴板的时长，之后才还原原剪贴板（#99）。
    static let pasteRestoreDelay = Duration.milliseconds(500)
    /// revealFile 协议值；与Dart常量及持久化调用方同步。
    static let revealFileMethod = "revealFile"
    /// rollback_failed 协议值；与Dart常量及持久化调用方同步。
    static let rollbackFailedError = "rollback_failed"
    /// saveScreenshot 协议值；与Dart常量及持久化调用方同步。
    static let saveScreenshotMethod = "saveScreenshot"
    /// saveSettings 协议值；与Dart常量及持久化调用方同步。
    static let saveSettingsMethod = "saveSettings"
    /// save_failed 协议值；与Dart常量及持久化调用方同步。
    static let saveFailedError = "save_failed"
    /// screenshotChanged 协议值；与Dart常量及持久化调用方同步。
    static let screenshotChangedMethod = "screenshotChanged"
    /// screenshotShortcutKeyCode 协议值；与Dart常量及持久化调用方同步。
    static let screenshotShortcutKeyCodeKey = "screenshotShortcutKeyCode"
    /// screenshotShortcutLabel 协议值；与Dart常量及持久化调用方同步。
    static let screenshotShortcutLabelKey = "screenshotShortcutLabel"
    /// screenshotShortcutModifiers 协议值；与Dart常量及持久化调用方同步。
    static let screenshotShortcutModifiersKey = "screenshotShortcutModifiers"
    /// selectionCaptured 协议值；与Dart常量及持久化调用方同步。
    static let selectionCapturedEvent = "selectionCaptured"
    /// selectionInvalidated 协议值；与Dart常量及持久化调用方同步。
    static let selectionInvalidatedEvent = "selectionInvalidated"
    /// setHistoryRecording 协议值；与Dart常量及持久化调用方同步。
    static let setHistoryRecordingMethod = "setHistoryRecording"
    /// setOverlaySize 协议值；与Dart常量及持久化调用方同步。
    static let setOverlaySizeMethod = "setOverlaySize"
    /// settingsMain 协议值；与Dart常量及持久化调用方同步。
    static let settingsEntrypoint = "settingsMain"
    /// settings_failed 协议值；与Dart常量及持久化调用方同步。
    static let settingsFailedError = "settings_failed"
    /// shortcutKeyCode 协议值；与Dart常量及持久化调用方同步。
    static let shortcutKeyCodeKey = "shortcutKeyCode"
    /// shortcutLabel 协议值；与Dart常量及持久化调用方同步。
    static let shortcutLabelKey = "shortcutLabel"
    /// shortcutModifiers 协议值；与Dart常量及持久化调用方同步。
    static let shortcutModifiersKey = "shortcutModifiers"
    /// inputShortcutKeyCode 协议值；输入翻译快捷键键码，与Dart常量同步。
    static let inputShortcutKeyCodeKey = "inputShortcutKeyCode"
    /// inputShortcutLabel 协议值；输入翻译快捷键显示名，与Dart常量同步。
    static let inputShortcutLabelKey = "inputShortcutLabel"
    /// inputShortcutModifiers 协议值；输入翻译快捷键修饰键，与Dart常量同步。
    static let inputShortcutModifiersKey = "inputShortcutModifiers"
    /// shortcut_invalid 协议值；与Dart常量及持久化调用方同步。
    static let shortcutInvalidError = "shortcut_invalid"
    /// showOverlay 协议值；与Dart常量及持久化调用方同步。
    static let showOverlayMethod = "showOverlay"
    /// stale_capture 协议值；与Dart常量及持久化调用方同步。
    static let staleCaptureError = "stale_capture"
    /// systemStatus 协议值；与Dart常量及持久化调用方同步。
    static let systemStatusMethod = "systemStatus"
    /// recordScreenshotHistory 协议值；截图导出成功后转发主引擎记录，与Dart常量同步。
    static let recordScreenshotHistoryMethod = "recordScreenshotHistory"
    /// screenshotHistoryList 协议值；历史窗口读取截图历史，转发主引擎，与Dart常量同步。
    static let screenshotHistoryListMethod = "screenshotHistoryList"
    /// deleteScreenshotHistory 协议值；历史窗口删除截图历史，转发主引擎，与Dart常量同步。
    static let deleteScreenshotHistoryMethod = "deleteScreenshotHistory"
    /// clearScreenshotHistory 协议值；历史窗口清空截图历史，转发主引擎，与Dart常量同步。
    static let clearScreenshotHistoryMethod = "clearScreenshotHistory"
    /// screenshotHistoryRecording 协议值；读取截图历史开关，转发主引擎，与Dart常量同步。
    static let screenshotHistoryRecordingMethod = "screenshotHistoryRecording"
    /// setScreenshotHistoryRecording 协议值；设置截图历史开关，转发主引擎，与Dart常量同步。
    static let setScreenshotHistoryRecordingMethod = "setScreenshotHistoryRecording"
    /// openFile 协议值；用系统默认应用打开文件，与Dart常量同步。
    static let openFileMethod = "openFile"
    /// copyImageFile 协议值；把 PNG 文件复制到剪贴板，与Dart常量同步。
    static let copyImageFileMethod = "copyImageFile"
    /// lookupDefinition 协议值；查询 macOS 词典释义，与Dart常量同步。
    static let lookupDefinitionMethod = "lookupDefinition"
    /// vocabularyList 协议值；历史窗口读取生词本，转发主引擎，与Dart常量同步。
    static let vocabularyListMethod = "vocabularyList"
    /// deleteVocabulary 协议值；历史窗口删除生词，转发主引擎，与Dart常量同步。
    static let deleteVocabularyMethod = "deleteVocabulary"
    /// vocabularyCsv 协议值；历史窗口取得生词本 CSV，转发主引擎，与Dart常量同步。
    static let vocabularyCsvMethod = "vocabularyCsv"
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
    /// testService 协议值；与Dart常量及持久化调用方同步。
    static let testServiceMethod = "testService"
    /// toggleAutomatic 协议值；与Dart常量及持久化调用方同步。
    static let toggleAutomaticMethod = "toggleAutomatic"
    /// translatePlainText 协议值；与Dart常量及持久化调用方同步。
    static let translatePlainTextMethod = "translatePlainText"
    /// translate_failed 协议值；与Dart常量同步。
    static let translateFailedError = "translate_failed"
    /// translation_not_installed 协议值；系统翻译语言包未下载，与Dart常量同步。
    static let translationNotInstalledError = "translation_not_installed"
    /// translation_unsupported 协议值；系统翻译不支持该语言对，与Dart常量同步。
    static let translationUnsupportedError = "translation_unsupported"
    /// translateapp/appearance 协议值；与Dart常量及持久化调用方同步。
    static let appearanceChannel = "translateapp/appearance"
    /// translateapp/macos 协议值；与Dart常量及持久化调用方同步。
    static let macosChannel = "translateapp/macos"
    /// translateapp/macos/events 协议值；与Dart常量及持久化调用方同步。
    static let macosEventsChannel = "translateapp/macos/events"
    /// translateapp/native-glass 协议值；与Dart常量及持久化调用方同步。
    static let nativeGlassViewType = "translateapp/native-glass"
    /// undoPressed 协议值；与Dart常量及持久化调用方同步。
    static let undoPressedMethod = "undoPressed"

    /// App 在用户 Application Support 下的数据目录名；历史库与 MCP socket 共用。
    static let applicationSupportFolderName = "TranslateApp"
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
