import Foundation

/// 零配置 Default Translation Provider，对接 Google Translate 消费端接口。
///
/// 可用性不受保证；失败必须作为 Translation Failure 展示，不得切换提供方。
public struct UnofficialGoogleProvider: TranslationProvider {
    public let id = "unofficial-google"

    private let http: any HTTPPerforming
    private let endpoint: URL

    public init(
        http: any HTTPPerforming = URLSessionHTTPClient(),
        endpoint: URL = URL(string: "https://translate.googleapis.com/translate_a/single")!
    ) {
        self.http = http
        self.endpoint = endpoint
    }

    public func translate(_ request: TranslationRequest) -> AsyncStream<TranslationEvent> {
        AsyncStream { continuation in
            let task = Task {
                do {
                    let data = try await send(request)
                    let text = try Self.parseTranslatedText(from: data)
                    continuation.yield(.update(text))
                    continuation.yield(.completed)
                } catch {
                    continuation.yield(.failure(Self.failureMessage(for: error)))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// 把 Google `translate_a/single` 的 JSON 数组拼成一条译文。
    /// - Parameter data: 响应体。允许前缀 `)]}'`。
    /// - Returns: 各句译文按原文顺序拼接的结果。
    public static func parseTranslatedText(from data: Data) throws -> String {
        var payload = data
        if let raw = String(data: data, encoding: .utf8) {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix(")]}'") {
                let index = trimmed.index(trimmed.startIndex, offsetBy: 4)
                payload = Data(trimmed[index...].utf8)
            }
        }

        guard let root = try JSONSerialization.jsonObject(with: payload) as? [Any],
              let sentences = root.first as? [Any]
        else {
            throw UnofficialGoogleError.unreadableResponse
        }

        var translated = ""
        for sentence in sentences {
            guard let row = sentence as? [Any] else { continue }
            if let piece = row.first as? String {
                translated += piece
            }
        }

        let result = translated.trimmingCharacters(in: .whitespacesAndNewlines)
        if result.isEmpty {
            throw UnofficialGoogleError.emptyTranslation
        }
        return translated
    }

    private func send(_ request: TranslationRequest) async throws -> Data {
        var urlRequest = URLRequest(url: endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue(
            "application/x-www-form-urlencoded;charset=UTF-8",
            forHTTPHeaderField: "Content-Type"
        )
        urlRequest.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")

        var components = URLComponents()
        components.queryItems = [
            URLQueryItem(name: "client", value: "gtx"),
            URLQueryItem(name: "sl", value: request.detectedLanguage ?? "auto"),
            URLQueryItem(name: "tl", value: request.targetLanguage),
            URLQueryItem(name: "dt", value: "t"),
            URLQueryItem(name: "q", value: request.sourceText),
        ]
        urlRequest.httpBody = components.percentEncodedQuery?.data(using: .utf8)

        let (data, response) = try await http.data(for: urlRequest)
        if let httpResponse = response as? HTTPURLResponse, !(200...299).contains(httpResponse.statusCode) {
            throw UnofficialGoogleError.httpStatus(httpResponse.statusCode)
        }
        return data
    }

    private static func failureMessage(for error: Error) -> String {
        if let error = error as? UnofficialGoogleError {
            return error.localizedDescription
        }
        return "Unofficial Google Provider 请求失败。"
    }
}

enum UnofficialGoogleError: LocalizedError {
    case httpStatus(Int)
    case emptyTranslation
    case unreadableResponse

    var errorDescription: String? {
        switch self {
        case .httpStatus(let code):
            return "Unofficial Google Provider 请求失败（HTTP \(code)）。"
        case .emptyTranslation:
            return "Unofficial Google Provider 返回了空译文。"
        case .unreadableResponse:
            return "Unofficial Google Provider 返回了无法解析的响应。"
        }
    }
}

/// 未配置时的 Default Translation Provider。
public enum DefaultTranslationProvider {
    public static func unconfigured() -> any TranslationProvider {
        UnofficialGoogleProvider()
    }
}
