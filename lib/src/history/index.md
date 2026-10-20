# lib/src/history目录索引

翻译记录与生词本的SQLite存储、分页与历史窗口。

1. [history_app.dart](history_app.dart)：展示历史卡片、分页、刷新与记录开关，并以分段切换生词本。
2. [index.md](index.md)：索引本目录直接子文件和子目录的用途。
3. [translation_history.dart](translation_history.dart)：定义翻译记录并管理SQLite写入、分页与记录设置。
4. [history_requests.dart](history_requests.dart)：处理主引擎历史分页和记录开关请求，不依赖设置提交队列。
5. [vocabulary.dart](vocabulary.dart)：定义生词条目，管理生词本表的增改删、CSV 导出与历史窗口请求。
6. [vocabulary_page.dart](vocabulary_page.dart)：历史窗口的生词本分段，展示、删除生词并经保存面板导出 CSV。
