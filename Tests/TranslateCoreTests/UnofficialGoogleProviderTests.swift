import Foundation
import Testing
import TranslateCore

struct UnofficialGoogleProviderTests {
    /// 目的：未配置时 Default Translation Provider 就是 Unofficial Google Provider。
    /// 边界：工厂不依赖任何用户设置。
    @Test func unconfiguredDefaultIsUnofficialGoogle() {
        #expect(DefaultTranslationProvider.unconfigured().id == "unofficial-google")
    }

    /// 目的：单句 Google JSON 至少产生一条 Translation Update 并完成。
    /// 边界：标准 `translate_a/single` 数组，含 null 槽位。
    @Test func singleSentenceFixtureBecomesOneUpdate() async {
        let body = Data(#"[[["你好","Hello",null,null,10]],null,"en"]"#.utf8)
        let http = StubHTTP(body: body)
        let provider = UnofficialGoogleProvider(http: http)
        let request = TranslationRequest(sourceText: "Hello", detectedLanguage: "en", targetLanguage: "zh-CN")

        let events = await collect(provider.translate(request))

        #expect(events == [.update("你好"), .completed])
        #expect(http.lastRequest?.httpMethod == "POST")
        let bodyString = String(data: http.lastRequest?.httpBody ?? Data(), encoding: .utf8) ?? ""
        #expect(bodyString.contains("sl=en"))
        #expect(bodyString.contains("tl=zh-CN"))
        #expect(bodyString.contains("q=Hello"))
    }

    /// 目的：多句响应按原文顺序拼成一条连续译文。
    /// 边界：第一层数组里有两句。
    @Test func multiSentenceFixtureConcatenatesInOrder() throws {
        let body = Data(
            #"[[["第一句。","First.",null,null,3],["第二句。","Second.",null,null,3]],null,"en"]"#.utf8
        )

        let text = try UnofficialGoogleProvider.parseTranslatedText(from: body)

        #expect(text == "第一句。第二句。")
    }

    /// 目的：HTTP 失败变成 Translation Failure，而不是抛出未捕获错误。
    /// 边界：429。
    @Test func httpErrorBecomesTranslationFailure() async {
        let http = StubHTTP(body: Data("rate limit".utf8), statusCode: 429)
        let provider = UnofficialGoogleProvider(http: http)
        let request = TranslationRequest(sourceText: "Hello", detectedLanguage: "en", targetLanguage: "zh-CN")

        let events = await collect(provider.translate(request))

        #expect(events.count == 1)
        guard case .failure(let message) = events[0] else {
            Issue.record("expected failure event")
            return
        }
        #expect(message.contains("429"))
    }

    /// 目的：无法解析的响应也要失败，避免把垃圾数据当成译文。
    /// 边界：HTML 错误页。
    @Test func unreadablePayloadBecomesFailure() async {
        let http = StubHTTP(body: Data("<html>nope</html>".utf8))
        let provider = UnofficialGoogleProvider(http: http)
        let request = TranslationRequest(sourceText: "Hello", detectedLanguage: nil, targetLanguage: "zh-CN")

        let events = await collect(provider.translate(request))

        guard case .failure = events.first else {
            Issue.record("expected failure event")
            return
        }
        #expect(events.contains(.completed) == false)
    }

    /// 目的：无法识别语言时把 sl=auto 交给消费端接口。
    /// 边界：detectedLanguage 为 nil。
    @Test func missingDetectedLanguageUsesAuto() async {
        let body = Data(#"[[["Hi","你好",null,null,1]],null,"zh-CN"]"#.utf8)
        let http = StubHTTP(body: body)
        let provider = UnofficialGoogleProvider(http: http)
        let request = TranslationRequest(sourceText: "你好", detectedLanguage: nil, targetLanguage: "en")

        _ = await collect(provider.translate(request))

        let bodyString = String(data: http.lastRequest?.httpBody ?? Data(), encoding: .utf8) ?? ""
        #expect(bodyString.contains("sl=auto"))
        #expect(bodyString.contains("tl=en"))
    }
}

private func collect(_ stream: AsyncStream<TranslationEvent>) async -> [TranslationEvent] {
    var events: [TranslationEvent] = []
    for await event in stream {
        events.append(event)
    }
    return events
}
