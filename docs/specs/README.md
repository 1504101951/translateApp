# 规格与工单导航

Codex-Thread: 01a0fa7e-90ee-7600-919f-2aba8d7000d4
Source: 用户确认的 Issue 权威来源与本地规格保留规则。

| 类别 | GitHub 权威规格 | 负责内容 |
| --- | --- | --- |
| 功能与交互 | [#1](https://github.com/1504101951/translateApp/issues/1) | 能力、用户操作、状态变化、数据保留与功能验收 |
| 样式 | [#67](https://github.com/1504101951/translateApp/issues/67) | 组件尺寸、圆角、间距、颜色、字号、命中区、动效与数值边界 |
| 架构设计约束 | [#68](https://github.com/1504101951/translateApp/issues/68) | 模块职责、数据契约、复用方式、依赖方向与技术验收 |

## Issue 与本地文档规则

1. Issue 已关闭且有说明时，以 Issue 正文与说明为准，删除对应的本地规格副本；不以本地副本覆盖关闭结论。
2. Issue 未关闭且内容已同步时，以 Issue 为准，删除本地规格副本。
3. Issue 未关闭且内容未同步时，先将尚未同步的内容写入对应 Issue 并回读核对，再删除本地规格副本。
4. Issue 未关闭，但已经确定的内容不适合在 Issue 中体现时，才保留一份本地规格。文档注明关联 Issue、会话标记（`<框架名>-Thread`）、保留理由与确定范围，不重复复制 Issue 正文。
5. 本地索引、工作规则、当前实现说明和领域上下文各自承担导航、流程或代码解释职责，不作为覆盖 Issue 的另一份规范。
6. 实施已批准需求前先更新对应 Issue。具体功能在其工单集中维护方案、参数、验收与待确认项，通过 Source-Spec、Style-Spec、Architecture-Spec 引用通用约束，避免同一规则多处独立维护。
7. 需求获批不表示实现完成；未定数值和交互明确列为待确认，工单标“待澄清”，不能据此宣称可开发或已验收。Issue 使用既有中文标签，智能体只更新正文、评论和标签，不关闭 Issue。
8. 禁止 computer-use；代码、自动化、构建和签名核验由智能体负责，界面效果由用户验收。

## 相关工单

用户指定保留的本地文档：[实时区域翻译澄清规格](live-region-translation.md)。记录 #24 的已确认结论与术语，同步 Issue 后仍按用户要求保留；推荐选项不视为批准。

1. [区域实时文字翻译 #24](https://github.com/1504101951/translateApp/issues/24)：完整功能、采集与调度方案、窗口边界、待确认项及验收。
2. [屏幕录制 #21](https://github.com/1504101951/translateApp/issues/21)：显示器、窗口或区域的无声 MP4 录制及本地预览保存。
3. [GIF 导出 #23](https://github.com/1504101951/translateApp/issues/23)：录制视频的 GIF 导出范围与验收。
4. [手动滚动长截图 #28](https://github.com/1504101951/translateApp/issues/28)：滚动拼接、固定区处理和结果操作，关联 #88、#89。
5. [共享粗细 #72](https://github.com/1504101951/translateApp/issues/72)：线宽控件的范围、实现说明与验收记录。
