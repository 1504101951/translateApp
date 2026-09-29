# Spec 分类与维护入口

Codex-Thread: 01a0b9b5-7646-76b0-9028-2402885d401b

| 类别 | 本地规范正文 | GitHub规格 | 负责内容 |
| --- | --- | --- | --- |
| 功能与交互 | [functional.md](functional.md) | [#1](https://github.com/1504101951/translateApp/issues/1) | 能力、用户操作、状态变化、数据保留、功能验收 |
| 样式 | [style.md](style.md) | [#67](https://github.com/1504101951/translateApp/issues/67) | 每个组件的尺寸、圆角、间距、颜色、字号、命中区、动效和数值边界 |
| 架构设计约束 | [architecture.md](architecture.md) | [#68](https://github.com/1504101951/translateApp/issues/68) | 模块职责、数据契约、复用方式、依赖方向和技术验收 |

## 维护契约

1. GitHub三类规格与本地同名文档保持同一规范正文；只因平台不同转换相对链接。#1是功能与交互Spec，也提供三类导航，不能把它作为唯一的样式或架构正文。
2. 已批准需求先更新涉及类别的本地与GitHub Spec，再实施。跨类需求必须同时检查行为、数值和技术职责，避免只改其中一处。
3. 执行工单注明Source-Spec、Style-Spec、Architecture-Spec，记录验收与真实阻塞。需求获批不表示实现完成；未定参数列出待确认字段，不用模糊形容词代替数值。
4. docs/agents/liquid-glass-ui.md是样式阅读入口；docs/architecture.md描述当前实现；docs/screenshot-editor-design.md描述截图接口。实现文档不能自行改变规范，冲突时先核对用户授权并同步对应Spec。
5. 功能行为以功能Spec为准，组件数值以样式Spec为准，技术边界以架构Spec为准。引用其他类别是为了完整验收，不另外复制一套可独立演变的数值。
6. Issue标签用“规格”及“规格：功能交互/规格：样式/规格：架构”区分类别；执行工单按功能或缺陷、待实现/待澄清/待验收标注。只评论与打标签，不关闭Issue。
7. 禁止computer-use。自动化检查、测试、构建和签名核验由智能体负责；用户确认界面效果。

## 本轮执行工单

1. [屏幕录制](https://github.com/1504101951/translateApp/issues/21)：显示器、窗口或区域的无声MP4录制及本地预览保存。
2. [GIF导出](https://github.com/1504101951/translateApp/issues/23)：从已完成录制中选择片段、帧率和宽度并导出GIF。
3. [手动滚动长截图](https://github.com/1504101951/translateApp/issues/28)：手动向下滚动、上下固定区去重、结束直接进入已有截图编辑流程。
