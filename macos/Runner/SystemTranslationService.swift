import Foundation
import Translation

/// Apple 系统翻译：按语言对创建无界面 TranslationSession，在本机翻译一组段落。
/// 只按请求 ID 持有进行中的会话以便取消，不保存翻译业务状态；分片、配对与错误文案由 Dart 负责。
@MainActor
final class SystemTranslationService {
    /// 进行中的会话；键为 Dart 生成的请求 ID，完成、失败或取消后移除。
    private var sessions: [String: TranslationSession] = [:]

    /// 框架未返回某个段落的译文；整批按失败处理，Dart 不接受不完整结果。
    struct IncompleteResponse: Error {}

    /// requestId 定位会话，texts 为待译段落，source/target 为语言码（如 zh-CN、en），strategy 为策略协议值。
    /// 返回与 texts 下标一一对应的译文；语言包未安装、语言对不支持或框架失败时抛出错误。
    func translate(
        requestId: String, texts: [String], source: String, target: String, strategy: String
    ) async throws -> [String] {
        // makeSession 按系统版本决定是否带策略参数。
        let session = Self.makeSession(source: source, target: target, strategy: strategy)
        sessions[requestId] = session
        defer { sessions[requestId] = nil }
        // clientIdentifier 为段落下标，响应据此对回原段，不依赖返回顺序。
        let requests = texts.indices.map {
            TranslationSession.Request(sourceText: texts[$0], clientIdentifier: String($0))
        }
        let responses = try await session.translations(from: requests)
        var translations = [String?](repeating: nil, count: texts.count)
        for response in responses {
            guard let id = response.clientIdentifier, let index = Int(id), translations.indices.contains(index) else {
                continue
            }
            translations[index] = response.targetText
        }
        let complete = translations.compactMap { $0 }
        guard complete.count == texts.count else { throw IncompleteResponse() }
        return complete
    }

    /// requestId 为 Dart 已放弃的请求；停止对应会话的本机计算，不存在时忽略，无返回值。
    func cancel(requestId: String) {
        sessions.removeValue(forKey: requestId)?.cancel()
    }

    /// pairs 为 [源语言, 目标语言] 列表；返回一一对应的安装状态协议值，不触发下载。
    nonisolated static func status(pairs: [[String]]) async -> [String] {
        let availability = LanguageAvailability()
        var statuses: [String] = []
        for pair in pairs {
            let status = await availability.status(
                from: Locale.Language(identifier: pair[0]), to: Locale.Language(identifier: pair[1])
            )
            switch status {
            case .installed:
                statuses.append(AppConstants.systemTranslationInstalled)
            case .supported:
                statuses.append(AppConstants.systemTranslationSupported)
            case .unsupported:
                statuses.append(AppConstants.systemTranslationUnsupported)
            @unknown default:
                // 框架新增的状态无法确认可用，按不支持提示，不尝试翻译。
                statuses.append(AppConstants.systemTranslationUnsupported)
            }
        }
        return statuses
    }

    /// error 为翻译抛出的错误；返回跨端错误码：语言包未安装、语言对不支持，其余为一般翻译失败。
    nonisolated static func errorCode(for error: Error) -> String {
        switch error {
        case TranslationError.notInstalled:
            return AppConstants.translationNotInstalledError
        case TranslationError.unsupportedSourceLanguage,
             TranslationError.unsupportedTargetLanguage,
             TranslationError.unsupportedLanguagePairing:
            return AppConstants.translationUnsupportedError
        default:
            return AppConstants.translateFailedError
        }
    }

    /// source/target 为语言码，strategy 为策略协议值；返回只使用已安装语言包的无界面会话。
    private static func makeSession(source: String, target: String, strategy: String) -> TranslationSession {
        let from = Locale.Language(identifier: source)
        let to = Locale.Language(identifier: target)
        // macOS 26.4 之前没有策略参数，由系统选择模型。
        guard #available(macOS 26.4, *) else {
            return TranslationSession(installedSource: from, target: to)
        }
        let preferred: TranslationSession.Strategy = strategy == AppConstants.systemTranslationHighFidelity
            ? .highFidelity
            : .lowLatency
        return TranslationSession(installedSource: from, target: to, preferredStrategy: preferred)
    }
}
