import '../platform/settings_platform.dart';
import '../settings/app_settings.dart';
import '../settings/service_config.dart';
import 'providers/api_translation_provider.dart';
import 'providers/unofficial_google_provider.dart';
import 'translation_types.dart';

/// settings为启动请求时的配置，platform提供凭据读取；返回对应服务，凭据在请求前读取。
TranslationProvider providerForSettings(
  AppSettings settings,
  SettingsPlatform platform,
) {
  if (settings.defaultServiceId == ServiceConfig.builtinId) {
    return UnofficialGoogleProvider();
  }
  return ApiTranslationProvider(
    config: settings.services.singleWhere(
      (service) => service.id == settings.defaultServiceId,
    ),
    credentials: () => platform.readCredentials(settings.defaultServiceId),
  );
}

/// provider为请求实际使用的服务；返回可记录的模型名，非模型服务返回null。
String? translationHistoryModel(TranslationProvider provider) {
  if (provider is! ApiTranslationProvider || provider.config.model.isEmpty) {
    return null;
  }
  return provider.config.model;
}
