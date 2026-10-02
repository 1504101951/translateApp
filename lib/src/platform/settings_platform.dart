/// 设置模块所需的系统存储边界；主引擎持有实现，窗口不另建配置或凭据副本。
abstract interface class SettingsPlatform {
  /// settings为已校验的完整偏好，credentials按服务ID表示写入或删除；系统事务成功后完成。
  Future<void> applySettings(
    Map<String, Object> settings, {
    Map<String, Map<String, String>?> credentials = const {},
  });

  /// id为服务账户；返回仅供主引擎使用的凭据字段，不写入普通偏好快照。
  Future<Map<String, String>> readCredentials(String id);

  /// ids为服务账户列表；返回已有凭据的账户ID，不返回凭据内容。
  Future<List<String>> credentialIds(List<String> ids);
}
