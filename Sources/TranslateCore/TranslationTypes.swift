import CoreGraphics
import Foundation

/// 发给 Translation Provider 的标准化请求。调用方不传入第三方专属字段。
public struct TranslationRequest: Equatable, Sendable {
    /// 当前 Selection Session 的原文。
    public var sourceText: String
    /// 设备本地得到的 Detected Language；无法识别时为 nil，由提供方自行处理。
    public var detectedLanguage: String?
    /// 本会话的 Translation Direction 目标语言。
    public var targetLanguage: String

    public init(sourceText: String, detectedLanguage: String?, targetLanguage: String) {
        self.sourceText = sourceText
        self.detectedLanguage = detectedLanguage
        self.targetLanguage = targetLanguage
    }
}

/// 提供方输出的统一事件。Translation Update 是对已展示译文的增量追加。
public enum TranslationEvent: Equatable, Sendable {
    case update(String)
    case completed
    case failure(String)
}

/// Translation Overlay 在一次 Selection Session 中的可观察状态。
public struct TranslationSnapshot: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        case idle
        case trigger
        case translating
        case completed
        case failed
        case sizeLimited
    }

    public var phase: Phase
    public var sourceText: String
    public var translatedText: String
    public var message: String?

    public static let idle = TranslationSnapshot(
        phase: .idle,
        sourceText: "",
        translatedText: "",
        message: nil
    )

    public init(phase: Phase, sourceText: String, translatedText: String, message: String?) {
        self.phase = phase
        self.sourceText = sourceText
        self.translatedText = translatedText
        self.message = message
    }
}

/// 能开始 Selection Session 的鼠标手势。键盘选区不是 Selection Gesture。
public enum SelectionGesture: Equatable, Sendable {
    case drag
    case doubleClick
    case tripleClick
}

/// 全局鼠标监听交给检测器的指针事件。不含键盘。
public struct MousePointerEvent: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case down
        case dragged
        case up
    }

    public var kind: Kind
    public var clickCount: Int
    public var x: CGFloat
    public var y: CGFloat

    public init(kind: Kind, clickCount: Int, x: CGFloat, y: CGFloat) {
        self.kind = kind
        self.clickCount = clickCount
        self.x = x
        self.y = y
    }
}

/// Translation Provider 只消费标准化请求，并异步输出统一事件。
public protocol TranslationProvider: Sendable {
    var id: String { get }
    func translate(_ request: TranslationRequest) -> AsyncStream<TranslationEvent>
}

/// HTTP 系统边界。生产用 URLSession，测试注入固定响应。
public protocol HTTPPerforming: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

public struct URLSessionHTTPClient: HTTPPerforming {
    public init() {}

    public func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await URLSession.shared.data(for: request)
    }
}
