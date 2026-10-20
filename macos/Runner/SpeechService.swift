import AVFoundation

/// 译文卡片朗读：用系统离线语音朗读一段文字，同一段再次请求即停止（#101）。
/// 只持有当前朗读的文字，不保存会话或翻译状态。
final class SpeechService {
    private let synthesizer = AVSpeechSynthesizer()
    /// 正在朗读的文字；用于判断再次点击同一栏时停止。
    private var spokenText: String?

    /// text 为待朗读文字，language 为服务语言码（如 zh-CN、en）；返回调用后是否处于朗读状态。
    /// 正在朗读同一段文字时停止并返回 false；否则停止当前朗读、开始朗读新文字并返回 true。
    func toggle(text: String, language: String) -> Bool {
        let repeating = synthesizer.isSpeaking && spokenText == text
        stop()
        guard !repeating else { return false }
        let utterance = AVSpeechUtterance(string: text)
        // voice 找不到对应语言时为 nil，由系统使用默认声音。
        utterance.voice = Self.voice(for: language)
        spokenText = text
        synthesizer.speak(utterance)
        return true
    }

    /// 无参数；立即停止当前朗读，没有朗读时无副作用，无返回值。
    func stop() {
        spokenText = nil
        synthesizer.stopSpeaking(at: .immediate)
    }

    /// code 为服务语言码；先补全为带地区的标签（en → en-US），找不到再按原码匹配，返回系统声音或 nil。
    static func voice(for code: String) -> AVSpeechSynthesisVoice? {
        let language = Locale.Language(identifier: code)
        // 只给语言码时系统会任取一个地区的声音（如 en-AU），用语言的默认地区补全更符合常用发音。
        if let base = language.languageCode?.identifier, let region = language.maximalIdentifier.split(separator: "-").last,
           let voice = AVSpeechSynthesisVoice(language: "\(base)-\(region)") {
            return voice
        }
        return AVSpeechSynthesisVoice(language: code)
    }
}
