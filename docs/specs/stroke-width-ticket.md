# 功能：提取共享粗细控件，为画笔、箭头和矩形调整线宽

发布工单：[共享粗细 #72](https://github.com/1504101951/translateApp/issues/72)。

Codex-Thread: 01a0b9b5-7646-76b0-9028-2402885d401b

Source: 用户在当前任务确认的新增Issue与三类Spec拆分
Source-Spec: https://github.com/1504101951/translateApp/issues/1
Style-Spec: https://github.com/1504101951/translateApp/issues/67
Architecture-Spec: https://github.com/1504101951/translateApp/issues/68

## 父级规格

功能与交互 https://github.com/1504101951/translateApp/issues/1；样式 https://github.com/1504101951/translateApp/issues/67；架构设计约束 https://github.com/1504101951/translateApp/issues/68。本地对应docs/specs/functional.md、style.md、architecture.md。

## 要实现的内容

画笔、箭头、图形描边共用独立的线宽选择控件；未选中时作用于后续绘制，选中已有支持对象时调整该对象并支持撤销。

## 执行范围

StrokeWidthPicker只处理当前线宽、范围/步长与选择结果；复用共享绘制样式、能力映射及现有编辑历史。文字字号独立，图形纯色填充不提供线宽，马赛克画笔使用轨迹线宽。UI单位与图像像素通过统一坐标换算处理，不让各工具自行换算。颜色和粗细可分工实现，不能各建一套样式真值。

## 验收标准

- [ ] 三种工具共享同一个粗细选择能力，当前值可见，最小/最大/默认/步长按样式Spec。
- [ ] 未选中时已画对象保持原线宽；选中后仅目标对象线宽改变。
- [ ] 连续调整作为一次完整编辑支持撤销/重做，不生成逐帧历史。
- [ ] 不同DPR、截图显示比例下线宽换算稳定，预览和复制/保存/贴图输出一致。
- [ ] 调色与调粗细互不覆盖，切换工具保持草稿；不支持的对象不显示线宽控件。
- [ ] 在样式Spec先确认单位、上下限、默认值、步长、预设档位、滑块与预览尺寸及跨工具默认值保持规则，再实现。

## 阻塞于

无执行工单硬阻塞；共享样式结构已由架构Spec约束。样式Spec已确定线宽1–20pt、默认3pt、步长1pt及控件尺寸。与颜色工单协作时复用先落地的模型，不重复建立。

## 交付权限

禁止computer-use；自动化测试与用户效果验收分别记录。只评论、打中文标签，不关闭Issue。
