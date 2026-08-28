import Testing
import TranslateCore

struct LanguageResolverTests {
    /// 目的：主要语言不是英语时，次要语言默认为英语。
    /// 边界：zh-Hans-CN 需归一成 zh-CN。
    @Test func nonEnglishPrimaryDefaultsSecondaryToEnglish() {
        let resolver = LanguageResolver(primaryCode: "zh-Hans-CN")
        #expect(resolver.primaryCode == "zh-CN")
        #expect(resolver.secondaryCode == "en")
    }

    /// 目的：主要语言是英语时，次要语言默认简体中文。
    /// 边界：en-US 与 en 视为同一语言。
    @Test func englishPrimaryDefaultsSecondaryToSimplifiedChinese() {
        let resolver = LanguageResolver(primaryCode: "en-US")
        #expect(resolver.primaryCode == "en")
        #expect(resolver.secondaryCode == "zh-CN")
    }

    /// 目的：非主要语言文本翻译到主要语言。
    /// 边界：足够长的英文，主要语言为简体中文。
    @Test func nonPrimaryTextTranslatesToPrimary() {
        let resolver = LanguageResolver(primaryCode: "zh-CN")
        let direction = resolver.direction(
            for: "This is a sufficiently long English sentence for language detection."
        )
        #expect(direction.detectedLanguage == "en")
        #expect(direction.targetLanguage == "zh-CN")
    }

    /// 目的：主要语言文本翻译到次要语言。
    /// 边界：足够长的简体中文，主要语言为简体中文。
    @Test func primaryTextTranslatesToSecondary() {
        let resolver = LanguageResolver(primaryCode: "zh-CN")
        let direction = resolver.direction(
            for: "这是一段足够长的中文句子，用来让系统在本地识别来源语言。"
        )
        #expect(direction.detectedLanguage == "zh-CN")
        #expect(direction.targetLanguage == "en")
    }

    /// 目的：无法识别时翻译到主要语言，避免卡住零配置闭环。
    /// 边界：空格与数字，Natural Language 通常给不出可靠语言。
    @Test func undetectableTextUsesPrimaryAsTarget() {
        let resolver = LanguageResolver(primaryCode: "ja")
        let direction = resolver.direction(for: "12345")
        #expect(direction.targetLanguage == "ja")
    }
}
