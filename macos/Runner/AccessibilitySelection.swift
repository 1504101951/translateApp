import ApplicationServices
import Foundation

/// 辅助功能权限查询。选区读取在 #2 接入，这里不实现翻译业务。
enum AccessibilitySelection {
    static func isTrusted(prompt: Bool) -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }
}
