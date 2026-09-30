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
    static let captureVideoPreview = "translateapp/capture_video_preview"
    /// Spec #67中的采集工具尺寸，单位为屏幕逻辑点。
    static let captureControlSize = NSSize(width: 320, height: 84)
    static let captureShadeOpacity: CGFloat = 0.6
    static let captureControlGap: CGFloat = 8
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
    static let resizeNorthWestSouthEast = "nwse"
    static let resizeNorthEastSouthWest = "nesw"
    /// 跨引擎外观模式与通知名称；与Dart AppearanceModes一致。
    /// 截图局部工具配置独立广播，不替换截图编辑草稿。
    static let screenshotTextInputMethod = "screenshotTextInput"
    static let screenshotToolbarHiddenKey = "screenshotToolbarHidden"
    static let screenshotToolbarOrderKey = "screenshotToolbarOrder"
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
    /// defaultServiceId 协议值；与Dart常量及持久化调用方同步。
    static let defaultServiceIdKey = "defaultServiceId"
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
    /// invalid_settings 协议值；与Dart常量及持久化调用方同步。
    static let invalidSettingsError = "invalid_settings"
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
    /// primaryLanguage 协议值；与Dart常量及持久化调用方同步。
    static let primaryLanguageKey = "primaryLanguage"
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
    /// secondaryLanguage 协议值；与Dart常量及持久化调用方同步。
    static let secondaryLanguageKey = "secondaryLanguage"
    /// selectionCaptured 协议值；与Dart常量及持久化调用方同步。
    static let selectionCapturedEvent = "selectionCaptured"
    /// selectionInvalidated 协议值；与Dart常量及持久化调用方同步。
    static let selectionInvalidatedEvent = "selectionInvalidated"
    /// services 协议值；与Dart常量及持久化调用方同步。
    static let servicesKey = "services"
    /// setHistoryRecording 协议值；与Dart常量及持久化调用方同步。
    static let setHistoryRecordingMethod = "setHistoryRecording"
    /// setOverlaySize 协议值；与Dart常量及持久化调用方同步。
    static let setOverlaySizeMethod = "setOverlaySize"
    /// settingsMain 协议值；与Dart常量及持久化调用方同步。
    static let settingsEntrypoint = "settingsMain"
    /// settings_conflict 协议值；与Dart常量及持久化调用方同步。
    static let settingsConflictError = "settings_conflict"
    /// settings_failed 协议值；与Dart常量及持久化调用方同步。
    static let settingsFailedError = "settings_failed"
    /// shortcutKeyCode 协议值；与Dart常量及持久化调用方同步。
    static let shortcutKeyCodeKey = "shortcutKeyCode"
    /// shortcutLabel 协议值；与Dart常量及持久化调用方同步。
    static let shortcutLabelKey = "shortcutLabel"
    /// shortcutModifiers 协议值；与Dart常量及持久化调用方同步。
    static let shortcutModifiersKey = "shortcutModifiers"
    /// shortcut_invalid 协议值；与Dart常量及持久化调用方同步。
    static let shortcutInvalidError = "shortcut_invalid"
    /// showOverlay 协议值；与Dart常量及持久化调用方同步。
    static let showOverlayMethod = "showOverlay"
    /// stale_capture 协议值；与Dart常量及持久化调用方同步。
    static let staleCaptureError = "stale_capture"
    /// systemStatus 协议值；与Dart常量及持久化调用方同步。
    static let systemStatusMethod = "systemStatus"
    /// testService 协议值；与Dart常量及持久化调用方同步。
    static let testServiceMethod = "testService"
    /// test_failed 协议值；与Dart常量及持久化调用方同步。
    static let testFailedError = "test_failed"
    /// toggleAutomatic 协议值；与Dart常量及持久化调用方同步。
    static let toggleAutomaticMethod = "toggleAutomatic"
    /// translatePlainText 协议值；与Dart常量及持久化调用方同步。
    static let translatePlainTextMethod = "translatePlainText"
    /// translate_failed 协议值；与Dart常量及持久化调用方同步。
    static let translateFailedError = "translate_failed"
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
}

/// 跨端选区手势；rawValue与Dart SelectionGestureTypes保持一致。
enum SelectionGesture: String {
    case drag
    case doubleClick
    case tripleClick
    case selectAll
    case keyboard
    case hotkey

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
