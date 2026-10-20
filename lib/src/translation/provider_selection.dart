import '../common/constants/text_mode.dart';
import '../platform/settings_platform.dart';
import '../settings/app_settings.dart';
import '../settings/service_config.dart';
import 'providers/api_translation_provider.dart';
import 'providers/apple_translation_provider.dart';
import 'providers/unofficial_google_provider.dart';
import 'translation_types.dart';

/// settings为启动请求时的配置，platform提供凭据读取；返回对应服务，凭据在请求前读取。
/// 返回值同时支持单篇翻译和实时翻译使用的批量翻译。
BatchTranslationProvider providerForSettings(
  AppSettings settings,
  SettingsPlatform platform,
) {
  if (settings.defaultServiceId == ServiceConfig.builtinId) {
    return UnofficialGoogleProvider();
  }
  final config = settings.services.singleWhere(
    (service) => service.id == settings.defaultServiceId,
  );
  // 系统翻译在本机完成，不读取凭据。
  if (config.isSystem) return AppleTranslationProvider(config: config);
  return ApiTranslationProvider(
    config: config,
    credentials: () => platform.readCredentials(settings.defaultServiceId),
  );
}

/// settings 为发起时的配置，platform 提供凭据读取，mode 为润色、纠错或解释。
/// 返回使用默认服务与内置提示词的模型 Provider；默认服务不是模型服务时返回 null，由调用方提示。
TranslationProvider? assistProviderForSettings(
  AppSettings settings,
  SettingsPlatform platform,
  TextMode mode,
) {
  if (settings.defaultServiceId == ServiceConfig.builtinId) return null;
  final config = settings.services.singleWhere(
    (service) => service.id == settings.defaultServiceId,
  );
  if (!config.isModel) return null;
  return ApiTranslationProvider(
    config: config,
    credentials: () => platform.readCredentials(config.id),
    mode: mode,
  );
}

/// provider为请求实际使用的服务；返回可记录的模型名，非模型服务返回null。
String? translationHistoryModel(TranslationProvider provider) {
  if (provider is! ApiTranslationProvider || provider.config.model.isEmpty) {
    return null;
  }
  return provider.config.model;
}
