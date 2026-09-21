# 液态玻璃 UI 规则入口

Codex-Thread: 01a0b9b5-7646-76b0-9028-2402885d401b

## 必读规范

1. 设计、实现、重构或审查UI前，完整读取[样式规格](../specs/style.md)，GitHub对应[样式Spec](https://github.com/1504101951/translateApp/issues/67)；每个组件的尺寸、圆角、配色和命中区以该文档为准。
2. 操作行为、编辑对象选择、保存、键盘与验收边界读取[功能与交互规格](../specs/functional.md)，GitHub对应[功能Spec](https://github.com/1504101951/translateApp/issues/1)。
3. 材料接入职责、共享绘制样式、颜色/粗细控件边界读取[架构设计约束](../specs/architecture.md)，GitHub对应[架构Spec](https://github.com/1504101951/translateApp/issues/68)。仅实际选用liquid_glass_widgets时应用其专属API附录。
4. 规格修改遵循[分类与维护契约](../specs/README.md)，本文件不另设重复数值。新调色盘、线宽和图形模式的待确认参数须先完成规格，再实施。
5. 禁止computer-use，用户负责界面效果验收；测试通过不等于视觉验收通过。

## 材料来源

来源与使用边界见样式规格“来源与改编说明”；许可证保存在[原文](liquid-glass-source-license.txt)。
