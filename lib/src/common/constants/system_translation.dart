/// Apple 系统翻译语言对的安装状态；名称即原生协议值，与 Swift `AppConstants` 中的状态值一致。
enum SystemTranslationStatus {
  /// 语言包已安装，可离线翻译。
  installed,

  /// 系统支持该语言对，但语言包尚未下载。
  supported,

  /// 系统不支持该语言对。
  unsupported,
}

/// Apple 系统翻译的模型策略；名称即原生协议值，macOS 26.4 以下由原生忽略。
enum SystemTranslationStrategy {
  /// Apple Intelligence 高保真模型，不可用时系统回退低延迟；用于单篇翻译。
  highFidelity,

  /// 低延迟模型；用于实时翻译的高频批量请求。
  lowLatency,
}
