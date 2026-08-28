import Foundation
import TranslateCore

/// 测试用 Translation Provider：记录标准化请求并回放预设事件，不碰网络。
final class RecordingProvider: TranslationProvider, @unchecked Sendable {
    let id: String
    private let lock = NSLock()
    private var recorded: [TranslationRequest] = []
    var events: [TranslationEvent]

    init(id: String = "recording", events: [TranslationEvent] = [.update("你好"), .completed]) {
        self.id = id
        self.events = events
    }

    var requests: [TranslationRequest] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func translate(_ request: TranslationRequest) -> AsyncStream<TranslationEvent> {
        lock.lock()
        recorded.append(request)
        lock.unlock()
        let events = events
        return AsyncStream { continuation in
            for event in events {
                continuation.yield(event)
            }
            continuation.finish()
        }
    }
}

/// 可取消的慢提供方，用于验证新 Selection Session 丢弃未完成翻译。
final class DelayedProvider: TranslationProvider, @unchecked Sendable {
    let id = "delayed"
    private let lock = NSLock()
    private var recorded: [TranslationRequest] = []
    let delay: Duration

    init(delay: Duration = .seconds(5)) {
        self.delay = delay
    }

    var requests: [TranslationRequest] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func translate(_ request: TranslationRequest) -> AsyncStream<TranslationEvent> {
        lock.lock()
        recorded.append(request)
        lock.unlock()
        let delay = delay
        return AsyncStream { stream in
            let task = Task {
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled else {
                    stream.finish()
                    return
                }
                stream.yield(.update("迟到的译文"))
                stream.yield(.completed)
                stream.finish()
            }
            stream.onTermination = { _ in task.cancel() }
        }
    }
}

final class StubHTTP: HTTPPerforming, @unchecked Sendable {
    var statusCode: Int
    var body: Data
    var lastRequest: URLRequest?

    init(body: Data, statusCode: Int = 200) {
        self.body = body
        self.statusCode = statusCode
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        lastRequest = request
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: nil
        )!
        return (body, response)
    }
}
