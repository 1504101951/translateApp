# lib/src/translation目录索引

语言方向、翻译数据契约、段落对照及分片流程。

1. [providers/](providers/index.md)：各翻译服务的HTTP协议与响应适配。
2. [index.md](index.md)：索引本目录直接子文件和子目录的用途。
3. [language_direction.dart](language_direction.dart)：按主要语言、次要语言和检测结果决定目标语言。
4. [model_result.dart](model_result.dart)：校验并解析模型返回的段落对应结果。
5. [paragraph_translation.dart](paragraph_translation.dart)：按原文段落组织翻译并保留分隔结构。
6. [segmented_translation.dart](segmented_translation.dart)：切分长文并管理串行翻译、滑动上下文和失败恢复。
7. [translation_types.dart](translation_types.dart)：定义单篇与批量翻译的请求、结果事件及服务契约。
8. [provider_selection.dart](provider_selection.dart)：按已提交偏好选择翻译服务并提取对应历史模型信息。
9. [live_region_session.dart](live_region_session.dart)：维护实时翻译的段落块、批次调度、失败处理和结果快照。
10. [live_block_cache.dart](live_block_cache.dart)：按内存预算保存一次实时翻译会话的段落块译文与失败记录。
11. [numbered_batch.dart](numbered_batch.dart)：为批次内段落编号，并把模型的流式输出按编号归属到段落。
12. [glossary.dart](glossary.dart)：定义术语条目，按目标语言与整词规则筛选本次请求命中的术语。
