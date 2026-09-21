/// 翻译会话阶段；选择、浮层和历史共同依据它判断完整成功。
enum TranslationPhase {
  idle,
  trigger,
  translating,
  completed,
  failed,
  sizeLimited,
}
