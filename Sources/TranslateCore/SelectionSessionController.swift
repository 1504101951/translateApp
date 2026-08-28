import Foundation
import Observation

/// 一次选区从手势到触发、激活、展示译文的编排。
///
/// 应用层只把 Selection Gesture 和可读文本交给这里；键盘选区没有对应入口。
@MainActor
@Observable
public final class SelectionSessionController {
    public static let selectionLimit = 50_000

    public private(set) var snapshot = TranslationSnapshot.idle

    private let provider: any TranslationProvider
    private let languageResolver: LanguageResolver
    private var sessionID = UUID()
    private var translationTask: Task<Void, Never>?

    /// - Parameters:
    ///   - provider: Default Translation Provider。未配置时应传入 Unofficial Google Provider。
    ///   - languageResolver: 本地语言方向。默认跟随系统首选语言。
    public init(
        provider: any TranslationProvider,
        languageResolver: LanguageResolver = .systemDefault()
    ) {
        self.provider = provider
        self.languageResolver = languageResolver
    }

    /// 在 Selection Gesture 完成后开始或替换 Selection Session。
    /// - Parameters:
    ///   - gesture: 拖拽、双击或三击。存在只为标明入口不是键盘。
    ///   - text: Accessibility 读到的选区；nil、空或纯空白不进入 Trigger State。
    public func beginSession(from gesture: SelectionGesture, text: String?) {
        _ = gesture
        sessionID = UUID()
        translationTask?.cancel()
        translationTask = nil

        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            snapshot = .idle
            return
        }

        snapshot = TranslationSnapshot(
            phase: .trigger,
            sourceText: text,
            translatedText: "",
            message: nil
        )
    }

    /// 用户激活 Translation Trigger State 后才向 Translation Provider 发送文本。
    public func activate() async {
        guard snapshot.phase == .trigger else { return }

        if snapshot.sourceText.count > Self.selectionLimit {
            snapshot = TranslationSnapshot(
                phase: .sizeLimited,
                sourceText: snapshot.sourceText,
                translatedText: "",
                message: "选区超过 50,000 个字符，未发送翻译请求。"
            )
            return
        }

        let id = sessionID
        let sourceText = snapshot.sourceText
        snapshot = TranslationSnapshot(
            phase: .translating,
            sourceText: sourceText,
            translatedText: "",
            message: nil
        )

        let direction = languageResolver.direction(for: sourceText)
        let request = TranslationRequest(
            sourceText: sourceText,
            detectedLanguage: direction.detectedLanguage,
            targetLanguage: direction.targetLanguage
        )

        let task = Task { await self.consume(request: request, sessionID: id) }
        translationTask = task
        await task.value
    }

    /// 结束当前 Selection Session，并丢弃未完成的翻译。
    public func dismiss() {
        sessionID = UUID()
        translationTask?.cancel()
        translationTask = nil
        snapshot = .idle
    }

    private func consume(request: TranslationRequest, sessionID: UUID) async {
        let stream = provider.translate(request)
        for await event in stream {
            guard self.sessionID == sessionID, !Task.isCancelled else { return }
            apply(event, sessionID: sessionID)
        }
    }

    private func apply(_ event: TranslationEvent, sessionID: UUID) {
        guard self.sessionID == sessionID else { return }
        switch event {
        case .update(let addition):
            var next = snapshot
            next.phase = .translating
            next.translatedText += addition
            snapshot = next
        case .completed:
            var next = snapshot
            next.phase = .completed
            snapshot = next
        case .failure(let message):
            snapshot = TranslationSnapshot(
                phase: .failed,
                sourceText: snapshot.sourceText,
                translatedText: snapshot.translatedText,
                message: message
            )
        }
    }
}
