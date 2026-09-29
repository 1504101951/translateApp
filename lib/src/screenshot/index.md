# lib/src/screenshot目录索引

截图编辑、标注渲染、工具栏布局与OCR翻译编排。

1. [edit_document.dart](edit_document.dart)：维护截图裁剪、标注、编辑历史及统一图片渲染。
2. [index.md](index.md)：索引本目录直接子文件和子目录的用途。
3. [screenshot_app.dart](screenshot_app.dart)：实现截图画布、采集工具组、文字编辑和导出操作。
4. [screenshot_editor_layout.dart](screenshot_editor_layout.dart)：计算工具栏避让布局并保持截图画布位置与比例。
5. [screenshot_translation.dart](screenshot_translation.dart)：编排截图OCR文本的语言识别、翻译和历史写入。

6. [drawing_style.dart](drawing_style.dart)：定义不可变共享绘制样式与工具能力。
7. [drawing_controls.dart](drawing_controls.dart)：提供带应用和取消语义的独立调色盘与粗细选择控件。

8. [drawing_preferences.dart](drawing_preferences.dart)：定义按工具独立保存的绘图属性及其持久化格式。
