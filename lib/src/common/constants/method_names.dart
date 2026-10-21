/// 平台方法协议；与Swift对应值保持一致，调用方不重复定义。
abstract final class MethodNames {
  /// 媒体采集协议，与Swift AppConstants逐项对应。
  static const getCaptureState = 'getCaptureState';
  static const previewLiveRegion = 'previewLiveRegion';
  static const cancelLivePreview = 'cancelLivePreview';
  static const liveRegionCommand = 'liveRegionCommand';
  static const liveRegionOcr = 'liveRegionOcr';
  static const liveRegionState = 'liveRegionState';
  static const publishLiveRegion = 'publishLiveRegion';
  static const getLiveRegionState = 'getLiveRegionState';
  static const captureStateChanged = 'captureStateChanged';
  static const prepareCapture = 'prepareCapture';
  static const previewCaptureTarget = 'previewCaptureTarget';
  static const captureSources = 'captureSources';
  static const stopCapture = 'stopCapture';
  static const setCapturePaused = 'setCapturePaused';
  static const cancelCapture = 'cancelCapture';
  static const saveRecording = 'saveRecording';

  /// 从裁剪起点播放到终点；未裁剪时播放完整视频。
  static const previewRecording = 'previewRecording';
  static const exportRecordingGIF = 'exportRecordingGIF';

  /// 按 GIF 设置导出 APNG（#110）。
  static const exportRecordingAPNG = 'exportRecordingAPNG';

  /// 结果页播放器进入系统裁剪模式；用户点「裁剪」或「取消」后返回（#110）。
  static const trimRecording = 'trimRecording';

  /// 取消正在进行的 MP4/GIF/APNG 转换。
  static const cancelRecordingExport = 'cancelRecordingExport';

  /// 历史写入完成及窗口重开时通知历史引擎刷新。
  static const historyChanged = 'historyChanged';

  /// 更新各工具独立的绘制偏好。
  static const saveDrawingPreferences = 'saveDrawingPreferences';

  /// 激活截图引擎的原生对角拉伸光标。
  static const setResizeCursor = 'setResizeCursor';
  static const setBrushCursor = 'setBrushCursor';
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

  /// 设置页读取 MCP helper 完整路径；与原生 AppConstants.mcpHelperPathMethod 一致。
  static const mcpHelperPath = 'mcpHelperPath';

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

  /// openLink 的稳定协议值；截图识别结果中的链接交给默认浏览器（#108），变更须同步两端。
  static const openLink = 'openLink';

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

  /// 输入翻译完成后把译文粘贴回来源应用；参数含 sessionId 与 text，返回是否已替换。
  static const replaceSelection = 'replaceSelection';

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

  /// 截图窗口在导出成功后记住选区，供「截取上次区域」复用；参数 id 与选区像素 x、y、width、height（#105）。
  static const rememberScreenshotRegion = 'rememberScreenshotRegion';

  /// 截图窗口读取上传目标描述「主机/存储桶」；参数 id，未配置返回 null（#111）。
  static const uploadTarget = 'uploadTarget';

  /// 截图窗口请求主引擎上传导出图；参数 id、bytes，返回分享链接（#111）。
  static const uploadScreenshot = 'uploadScreenshot';

  /// 截图窗口在导出成功后请求主引擎记录截图历史；参数 id、bytes、capturedAt（#29）。
  static const recordScreenshotHistory = 'recordScreenshotHistory';

  /// 历史窗口读取截图历史；返回按截图时间倒序的条目列表。
  static const screenshotHistoryList = 'screenshotHistoryList';

  /// 历史窗口删除一条截图历史及其图片；参数 id。
  static const deleteScreenshotHistory = 'deleteScreenshotHistory';

  /// 历史窗口清空截图历史及其图片。
  static const clearScreenshotHistory = 'clearScreenshotHistory';

  /// 读取「记录截图历史」开关。
  static const screenshotHistoryRecording = 'screenshotHistoryRecording';

  /// 设置「记录截图历史」开关；参数 enabled。
  static const setScreenshotHistoryRecording = 'setScreenshotHistoryRecording';

  /// 历史窗口把拼接或拆分结果加入截图历史；参数 images（PNG 字节列表，按列表从上到下的顺序）（#109）。
  static const addScreenshotHistory = 'addScreenshotHistory';

  /// 按顺序拼接截图历史图片；参数 paths、vertical，返回 PNG 字节（#109）。
  static const stitchScreenshots = 'stitchScreenshots';

  /// 按高度等分一张截图历史图片；参数 path、parts，返回自上而下的 PNG 字节列表（#109）。
  static const splitScreenshot = 'splitScreenshot';

  /// 逐像素比较两张截图历史图片；参数 first、second，返回 {mask, different, total}（#109）。
  static const compareScreenshots = 'compareScreenshots';

  /// 用系统默认应用打开文件；参数 path。
  static const openFile = 'openFile';

  /// 把 PNG 文件复制到剪贴板；参数 path。
  static const copyImageFile = 'copyImageFile';

  /// 查询 macOS 词典释义；参数 text 为单词或短语，返回释义全文或 null（#102）。
  static const lookupDefinition = 'lookupDefinition';

  /// 历史窗口读取生词本；返回按加入时间倒序的条目列表。
  static const vocabularyList = 'vocabularyList';

  /// 历史窗口删除一条生词；参数 word。
  static const deleteVocabulary = 'deleteVocabulary';

  /// 历史窗口取得生词本 CSV 全文（UTF-8、无表头，列为单词、译文、释义）。
  static const vocabularyCsv = 'vocabularyCsv';

  /// 经系统保存面板保存文本文件；参数 text 与 suggestedName，返回保存路径，取消为 null。
  static const saveTextFile = 'saveTextFile';

  /// 朗读或停止朗读卡片一栏文字；参数含 text 与 language，返回调用后是否在朗读。
  static const toggleSpeech = 'toggleSpeech';

  /// 停止当前朗读；关闭卡片、开始新翻译或切换模式时调用。
  static const stopSpeech = 'stopSpeech';

  /// Apple 系统翻译一组段落；参数含 requestId、texts、source、target、strategy。
  static const systemTranslate = 'systemTranslate';

  /// 按 requestId 取消进行中的 Apple 系统翻译。
  static const cancelSystemTranslation = 'cancelSystemTranslation';

  /// 查询 Apple 系统翻译语言对的安装状态；参数 pairs 为 [源语言, 目标语言] 列表。
  static const systemTranslationStatus = 'systemTranslationStatus';

  /// testService 的稳定协议值，变更须同步两端及持久化调用方。
  static const testService = 'testService';

  /// toggleAutomatic 的稳定协议值，变更须同步两端及持久化调用方。
  static const toggleAutomatic = 'toggleAutomatic';

  /// translatePlainText 的稳定协议值，变更须同步两端及持久化调用方。
  static const translatePlainText = 'translatePlainText';

  /// undoPressed 的稳定协议值，变更须同步两端及持久化调用方。
  static const undoPressed = 'undoPressed';
}
