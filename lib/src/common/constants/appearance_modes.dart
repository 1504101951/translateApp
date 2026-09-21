/// 持久化与跨引擎外观协议；Swift AppearanceMode 保持相同原始值。
abstract final class AppearanceModes {
  static const system = 'system';
  static const light = 'light';
  static const dark = 'dark';
  static const values = [system, light, dark];
  static const labels = {system: '跟随系统', light: '浅色', dark: '深色'};
}
