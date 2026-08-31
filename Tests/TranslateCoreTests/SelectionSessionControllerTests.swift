import Testing
import TranslateCore

@MainActor
struct SelectionSessionControllerTests {
    /// 目的：鼠标手势加上可读文本后进入 Trigger State，且此时不得请求提供方。
    /// 边界：非空原文；激活前观察请求列表必须仍为空。
    @Test func selectionGestureShowsTriggerWithoutCallingProvider() {
        let provider = RecordingProvider()
        let controller = SelectionSessionController(
            provider: provider,
            languageResolver: LanguageResolver(primaryCode: "zh-CN")
        )

        controller.beginSession(from: .drag, text: "Hello")

        #expect(controller.snapshot.phase == .trigger)
        #expect(controller.snapshot.sourceText == "Hello")
        #expect(provider.requests.isEmpty)
    }

    /// 目的：双击、三击与拖拽使用同一入口，都能开始 Selection Session。
    /// 边界：三种 Selection Gesture 都带同一段非空文本。
    @Test func doubleClickAndTripleClickAlsoBeginSession() {
        let controller = SelectionSessionController(
            provider: RecordingProvider(),
            languageResolver: LanguageResolver(primaryCode: "zh-CN")
        )

        controller.beginSession(from: .doubleClick, text: "word")
        #expect(controller.snapshot.phase == .trigger)

        controller.beginSession(from: .tripleClick, text: "paragraph")
        #expect(controller.snapshot.phase == .trigger)
        #expect(controller.snapshot.sourceText == "paragraph")

        controller.beginSession(from: .selectAll, text: "all of it")
        #expect(controller.snapshot.phase == .trigger)
        #expect(controller.snapshot.sourceText == "all of it")
    }

    /// 目的：不可读取或纯空白选区不展示 Translation Overlay。
    /// 边界：nil、空字符串、仅空白。
    @Test func unreadOrBlankSelectionStaysIdle() {
        let controller = SelectionSessionController(
            provider: RecordingProvider(),
            languageResolver: LanguageResolver(primaryCode: "zh-CN")
        )

        controller.beginSession(from: .drag, text: nil)
        #expect(controller.snapshot.phase == .idle)

        controller.beginSession(from: .drag, text: "")
        #expect(controller.snapshot.phase == .idle)

        controller.beginSession(from: .drag, text: " \n\t ")
        #expect(controller.snapshot.phase == .idle)
    }

    /// 目的：激活后消费 Translation Update，并在完成后展示完整译文。
    /// 边界：两条增量更新按追加组装，而不是覆盖。
    @Test func activatingTriggerShowsProgressAndAssembledTranslation() async {
        let provider = RecordingProvider(events: [.update("你"), .update("好"), .completed])
        let controller = SelectionSessionController(
            provider: provider,
            languageResolver: LanguageResolver(primaryCode: "zh-CN")
        )
        controller.beginSession(from: .drag, text: "Hello")

        await controller.activate()

        #expect(controller.snapshot.phase == .completed)
        #expect(controller.snapshot.translatedText == "你好")
        #expect(provider.requests.map(\.sourceText) == ["Hello"])
    }

    /// 目的：恰好 50,000 个字符仍可翻译。
    /// 边界：Selection Limit 含上限。
    @Test func selectionAtLimitStillTranslates() async {
        let provider = RecordingProvider()
        let controller = SelectionSessionController(
            provider: provider,
            languageResolver: LanguageResolver(primaryCode: "zh-CN")
        )
        let text = String(repeating: "a", count: SelectionSessionController.selectionLimit)
        controller.beginSession(from: .drag, text: text)

        await controller.activate()

        #expect(controller.snapshot.phase == .completed)
        #expect(provider.requests.count == 1)
    }

    /// 目的：超过 50,000 个字符时只在本地提示，不把文本发给提供方。
    /// 边界：50,001 个字符；Trigger State 仍可出现，失败发生在激活时。
    @Test func oversizedSelectionStaysLocalOnActivate() async {
        let provider = RecordingProvider()
        let controller = SelectionSessionController(
            provider: provider,
            languageResolver: LanguageResolver(primaryCode: "zh-CN")
        )
        let text = String(repeating: "a", count: SelectionSessionController.selectionLimit + 1)
        controller.beginSession(from: .drag, text: text)
        #expect(controller.snapshot.phase == .trigger)

        await controller.activate()

        #expect(controller.snapshot.phase == .sizeLimited)
        #expect(controller.snapshot.message != nil)
        #expect(provider.requests.isEmpty)
    }

    /// 目的：提供方失败展示 Translation Failure，保留已收到的部分译文。
    /// 边界：先有一条 update，再 failure。
    @Test func providerFailureShowsMessageWithoutSwitchingProvider() async {
        let provider = RecordingProvider(events: [.update("部"), .failure("限流")])
        let controller = SelectionSessionController(
            provider: provider,
            languageResolver: LanguageResolver(primaryCode: "zh-CN")
        )
        controller.beginSession(from: .drag, text: "Hello")

        await controller.activate()

        #expect(controller.snapshot.phase == .failed)
        #expect(controller.snapshot.translatedText == "部")
        #expect(controller.snapshot.message == "限流")
    }

    /// 目的：新 Selection Session 替换旧会话，迟到的译文不得写进新浮层。
    /// 边界：第一段翻译在门闩处阻塞，第二段手势已经进入 Trigger。
    @Test func newSelectionSessionDropsStaleTranslation() async {
        let provider = DelayedProvider(delay: .seconds(5))
        let controller = SelectionSessionController(
            provider: provider,
            languageResolver: LanguageResolver(primaryCode: "zh-CN")
        )
        controller.beginSession(from: .drag, text: "first")
        let first = Task { await controller.activate() }
        for _ in 0..<50 where provider.requests.isEmpty {
            try? await Task.sleep(for: .milliseconds(10))
        }

        controller.beginSession(from: .doubleClick, text: "second")
        await first.value

        #expect(controller.snapshot.phase == .trigger)
        #expect(controller.snapshot.sourceText == "second")
        #expect(controller.snapshot.translatedText.isEmpty)
    }
}
