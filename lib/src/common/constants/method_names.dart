/// 平台方法协议；与Swift对应值保持一致，调用方不重复定义。
abstract final class MethodNames {
  /// 媒体采集协议，与Swift AppConstants逐项对应。
  static const getCaptureState = 'getCaptureState';
  static const captureStateChanged = 'captureStateChanged';
  static const prepareCapture = 'prepareCapture';
  static const previewCaptureTarget = 'previewCaptureTarget';
  static const captureSources = 'captureSources';
  static const stopCapture = 'stopCapture';
  static const setCapturePaused = 'setCapturePaused';
  static const cancelCapture = 'cancelCapture';
  static const saveRecording = 'saveRecording';

  /// 播放当前完整视频。
  static const previewRecording = 'previewRecording';
  static const exportRecordingGIF = 'exportRecordingGIF';
  static const cancelGIFExport = 'cancelGIFExport';

  /// 历史写入完成及窗口重开时通知历史引擎刷新。
  static const historyChanged = 'historyChanged';

  /// 更新各工具独立的绘制偏好。
  static const saveDrawingPreferences = 'saveDrawingPreferences';

  /// 激活截图引擎的原生对角拉伸光标。
  static const setResizeCursor = 'setResizeCursor';
  static const screenshotTextInput = 'screenshotTextInput';
  static const screenshotToolbarChanged = 'screenshotToolbarChanged';
  static const screenshotToolbarAction = 'screenshotToolbarAction';

  /// 打开独立历史窗口的系统操作。
  static const openHistory = 'openHistory';

  /// appReady 的稳定协议值，变更须同步两端及持久化调用方。
  static const appReady = 'appReady';

  /// appearanceChanged 的稳定协议值，变更须同步两端及持久化调用方。
  static const appearanceChanged = 'appearanceChanged';

  /// applicationSupportPath 的稳定协议值，变更须同步两端及持久化调用方。
  static const applicationSupportPath = 'applicationSupportPath';

  /// applySettings 的稳定协议值，变更须同步两端及持久化调用方。
  static const applySettings = 'applySettings';

  /// captureRegion 的稳定协议值，变更须同步两端及持久化调用方。
  static const captureRegion = 'captureRegion';

  /// chooseExcludedApp 的稳定协议值，变更须同步两端及持久化调用方。
  static const chooseExcludedApp = 'chooseExcludedApp';

  /// chooseScreenshotDirectory 的稳定协议值，变更须同步两端及持久化调用方。
  static const chooseScreenshotDirectory = 'chooseScreenshotDirectory';

  /// closePermissionWizard 的稳定协议值，变更须同步两端及持久化调用方。
  static const closePermissionWizard = 'closePermissionWizard';

  /// closePin 的稳定协议值，变更须同步两端及持久化调用方。
  static const closePin = 'closePin';

  /// closeScreenshot 的稳定协议值，变更须同步两端及持久化调用方。
  static const closeScreenshot = 'closeScreenshot';

  /// confirmScreenshot 的稳定协议值，变更须同步两端及持久化调用方。
  static const confirmScreenshot = 'confirmScreenshot';

  /// copyScreenshot 的稳定协议值，变更须同步两端及持久化调用方。
  static const copyScreenshot = 'copyScreenshot';

  /// copyText 的稳定协议值，变更须同步两端及持久化调用方。
  static const copyText = 'copyText';

  /// credentialIds 的稳定协议值，变更须同步两端及持久化调用方。
  static const credentialIds = 'credentialIds';

  /// detectLanguage 的稳定协议值，变更须同步两端及持久化调用方。
  static const detectLanguage = 'detectLanguage';

  /// dragOverlay 的稳定协议值，变更须同步两端及持久化调用方。
  static const dragOverlay = 'dragOverlay';

  /// escapePressed 的稳定协议值，变更须同步两端及持久化调用方。
  static const escapePressed = 'escapePressed';

  /// finishPermissionWizard 的稳定协议值，变更须同步两端及持久化调用方。
  static const finishPermissionWizard = 'finishPermissionWizard';

  /// getAppearance 的稳定协议值，变更须同步两端及持久化调用方。
  static const getAppearance = 'getAppearance';

  /// getScreenshot 的稳定协议值，变更须同步两端及持久化调用方。
  static const getScreenshot = 'getScreenshot';

  /// getSettings 的稳定协议值，变更须同步两端及持久化调用方。
  static const getSettings = 'getSettings';

  /// hideOverlay 的稳定协议值，变更须同步两端及持久化调用方。
  static const hideOverlay = 'hideOverlay';

  /// historyPage 的稳定协议值，变更须同步两端及持久化调用方。
  static const historyPage = 'historyPage';

  /// historyRecording 的稳定协议值，变更须同步两端及持久化调用方。
  static const historyRecording = 'historyRecording';

  /// isCurrentScreenshot 的稳定协议值，变更须同步两端及持久化调用方。
  static const isCurrentScreenshot = 'isCurrentScreenshot';

  /// loadSettings 的稳定协议值，变更须同步两端及持久化调用方。
  static const loadSettings = 'loadSettings';

  /// openAccessibility 的稳定协议值，变更须同步两端及持久化调用方。
  static const openAccessibility = 'openAccessibility';

  /// openLoginItems 的稳定协议值，变更须同步两端及持久化调用方。
  static const openLoginItems = 'openLoginItems';

  /// permissionStatusChanged 的稳定协议值，变更须同步两端及持久化调用方。
  static const permissionStatusChanged = 'permissionStatusChanged';

  /// permissionWizardStatus 的稳定协议值，变更须同步两端及持久化调用方。
  static const permissionWizardStatus = 'permissionWizardStatus';

  /// pinScreenshot 的稳定协议值，变更须同步两端及持久化调用方。
  static const pinScreenshot = 'pinScreenshot';

  /// probeEmitSelection 的稳定协议值，变更须同步两端及持久化调用方。
  static const probeEmitSelection = 'probeEmitSelection';

  /// readCredentials 的稳定协议值，变更须同步两端及持久化调用方。
  static const readCredentials = 'readCredentials';

  /// readSelectionForTranslation 的稳定协议值，变更须同步两端及持久化调用方。
  static const readSelectionForTranslation = 'readSelectionForTranslation';

  /// recognizeBlocks 的稳定协议值，变更须同步两端及持久化调用方。
  static const recognizeBlocks = 'recognizeBlocks';

  /// recognizeText 的稳定协议值，变更须同步两端及持久化调用方。
  static const recognizeText = 'recognizeText';

  /// recordShortcut 的稳定协议值，变更须同步两端及持久化调用方。
  static const recordShortcut = 'recordShortcut';

  /// redoPressed 的稳定协议值，变更须同步两端及持久化调用方。
  static const redoPressed = 'redoPressed';

  /// refreshSettings 的稳定协议值，变更须同步两端及持久化调用方。
  static const refreshSettings = 'refreshSettings';

  /// requestAccessibility 的稳定协议值，变更须同步两端及持久化调用方。
  static const requestAccessibility = 'requestAccessibility';

  /// requestScreenAccess 的稳定协议值，变更须同步两端及持久化调用方。
  static const requestScreenAccess = 'requestScreenAccess';

  /// retainOverlay 的稳定协议值，变更须同步两端及持久化调用方。
  static const retainOverlay = 'retainOverlay';

  /// revealFile 的稳定协议值，变更须同步两端及持久化调用方。
  static const revealFile = 'revealFile';

  /// saveScreenshot 的稳定协议值，变更须同步两端及持久化调用方。
  static const saveScreenshot = 'saveScreenshot';

  /// saveSettings 的稳定协议值，变更须同步两端及持久化调用方。
  static const saveSettings = 'saveSettings';

  /// screenshotChanged 的稳定协议值，变更须同步两端及持久化调用方。
  static const screenshotChanged = 'screenshotChanged';

  /// setHistoryRecording 的稳定协议值，变更须同步两端及持久化调用方。
  static const setHistoryRecording = 'setHistoryRecording';

  /// setOverlaySize 的稳定协议值，变更须同步两端及持久化调用方。
  static const setOverlaySize = 'setOverlaySize';

  /// showOverlay 的稳定协议值，变更须同步两端及持久化调用方。
  static const showOverlay = 'showOverlay';

  /// systemStatus 的稳定协议值，变更须同步两端及持久化调用方。
  static const systemStatus = 'systemStatus';

  /// testService 的稳定协议值，变更须同步两端及持久化调用方。
  static const testService = 'testService';

  /// toggleAutomatic 的稳定协议值，变更须同步两端及持久化调用方。
  static const toggleAutomatic = 'toggleAutomatic';

  /// translatePlainText 的稳定协议值，变更须同步两端及持久化调用方。
  static const translatePlainText = 'translatePlainText';

  /// undoPressed 的稳定协议值，变更须同步两端及持久化调用方。
  static const undoPressed = 'undoPressed';
}
