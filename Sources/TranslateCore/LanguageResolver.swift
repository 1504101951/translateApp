import Foundation
import NaturalLanguage

/// 一次 Selection Session 在第三方请求前确定的 Detected Language 与 Translation Direction。
public struct LanguageDirection: Equatable, Sendable {
    public var detectedLanguage: String?
    public var targetLanguage: String

    public init(detectedLanguage: String?, targetLanguage: String) {
        self.detectedLanguage = detectedLanguage
        self.targetLanguage = targetLanguage
    }
}

/// 用设备本地语言识别和默认主要/次要语言决定翻译方向。
///
/// #4 才提供可编辑持久化设置；此处只提供零配置闭环所需的默认规则。
public struct LanguageResolver: Sendable {
    public var primaryCode: String
    public var secondaryCode: String

    /// - Parameters:
    ///   - primaryCode: 主要语言，通常取 macOS 首选语言。
    ///   - secondaryCode: 次要语言；nil 时按默认规则推导。
    public init(primaryCode: String, secondaryCode: String? = nil) {
        let primary = LanguageCode.normalize(primaryCode)
        self.primaryCode = primary
        self.secondaryCode = secondaryCode.map(LanguageCode.normalize)
            ?? LanguageCode.defaultSecondary(for: primary)
    }

    /// 用当前用户的第一个 macOS 首选语言构造默认解析器。
    public static func systemDefault() -> LanguageResolver {
        LanguageResolver(primaryCode: Locale.preferredLanguages.first ?? "en")
    }

    /// 在发送第三方请求前判定 Detected Language 与目标语言。
    /// - Parameter text: 当前选区原文。
    /// - Returns: 无法识别时 `detectedLanguage` 为 nil，目标为主要语言。
    public func direction(for text: String) -> LanguageDirection {
        let detected = detect(text)
        let target: String
        if let detected, LanguageCode.sameLanguage(detected, primaryCode) {
            target = secondaryCode
        } else {
            target = primaryCode
        }
        return LanguageDirection(detectedLanguage: detected, targetLanguage: target)
    }

    private func detect(_ text: String) -> String? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        guard let language = recognizer.dominantLanguage else { return nil }
        return LanguageCode.from(nl: language)
    }
}

enum LanguageCode {
    static func normalize(_ raw: String) -> String {
        let parts = raw.replacingOccurrences(of: "_", with: "-")
            .split(separator: "-")
            .map { String($0) }
        guard let first = parts.first?.lowercased() else { return raw }
        if first == "zh" {
            let rest = parts.dropFirst().joined(separator: "-").lowercased()
            if rest.contains("hant") || rest == "tw" || rest == "hk" {
                return "zh-TW"
            }
            return "zh-CN"
        }
        return first
    }

    static func defaultSecondary(for primary: String) -> String {
        sameLanguage(primary, "en") ? "zh-CN" : "en"
    }

    static func sameLanguage(_ a: String, _ b: String) -> Bool {
        normalize(a) == normalize(b)
    }

    static func from(nl: NLLanguage) -> String {
        switch nl {
        case .simplifiedChinese: return "zh-CN"
        case .traditionalChinese: return "zh-TW"
        default: return normalize(nl.rawValue)
        }
    }
}
