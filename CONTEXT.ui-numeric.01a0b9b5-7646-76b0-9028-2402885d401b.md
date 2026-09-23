# UI 数值规格与验收

Codex-Thread: 01a0b9b5-7646-76b0-9028-2402885d401b
Source-Spec: https://github.com/1504101951/translateApp/issues/1

## 规格整理与授权提交（2026-09-23）

用户授权整理本地和GitHub Spec并提交当前所有相关改动，要求关联Issue、说明具体工作。已将子工具能力矩阵、对象与默认值边界、历史事件与主题重建、双行工具栏、固定签名串行交付收口进三类Spec；修正马赛克不读取线宽的冲突说明。GitHub #1/#67/#68正文已同步。当前验证为Flutter118通过、analyze无问题，脚本语法/索引覆盖/diffcheck通过；未修改应用源代码后重跑冗余测试。

本轮按规格、设置交互、截图与历史、串行交付四组提交；提交使用Refs关联Issue，不关闭工单。用户反馈当前效果“看起来没问题”，保留在验收记录。未请求推送，提交保留在本地main；不得将本机提交误报成已发布远端代码。只读审计子智能体仍因模型服务404失败，由主智能体完成核对。

## Xcode组件与串行脚本（2026-09-23）

用户反馈本轮效果“看起来没问题”，询问更新组件及新增串行package/install脚本。已执行xcodebuild -runFirstLaunch -checkForNewerComponents：Install Succeeded，No new updates for 27A266a；CoreSimulator旧服务1051.54切换到1171.7。checkFirstLaunchStatus退出0，showdestinations正常列出macOS目标，CoreDevice缺符号与CoreSimulator版本错误未再出现。未升级Xcode/macOS、未重新安装或启动TranslateApp。检查日志/private/tmp/xcode-components-check.01a0b9b5-7646-76b0-9028-2402885d401b.log。

新增可执行scripts/package-and-install-macos.sh，set -euo pipefail依次调用现有打包与安装脚本，打包失败不安装残留ZIP；继承现有运行进程检查、签名校验和回滚。README、macOS安装文档及目录索引同步，bash -n与diffcheck通过。未实际运行串行脚本（用户尚未退出当前应用），未提交或推送。

## 子工具隔离与页面细节（2026-09-23）

用户反馈打包报错、具体子工具配置隔离、权限合组、历史header间距及二级模式按钮玻璃。已修改DrawingPreferences以variants按四种图形和两种画笔独立存储，styleFor解析具体子模式；保留已有基础配置值。模式按钮统一使用NativeGlassSurface，32×32pt、r8、gap4；外壳透明。权限同卡片、登录启动独立，两项minTileHeight56。历史刷新/文字gap12、文字/开关gap8、右边16。三类本地及GitHubSpec已同步。

完整Flutter118项通过、analyze无问题、diffcheck通过；未改原生代码，本轮不重复原生测试。未使用computer-use。原有字号测试点击被输入层遮挡，删去该无效点击，该段只验证已有文字调色不会污染默认颜色，不再把它视为字号修改验收。只读子智能体服务因gpt-5.6-luna不可用均失败，转本地执行。

打包成功；Xcode CoreDevice缺少符号，CoreSimulator1051.54.0低于1171.7.0，是设备框架版本不匹配，本轮未改系统环境。日志/private/tmp/subtools-{full-test,analyze,package}.01a0b9b5-7646-76b0-9028-2402885d401b.log。新ZIP SHA256 b1cdb6e188f72d26a8b35c91926b9cb2b56ae922bede82383b8ba9db92039ddc，固定签名TranslateApp Local Signing；解包/private/tmp/subtools-verify.m7zfox4j/TranslateApp.app，沙盒外deep/strict通过。尚未安装；当前/Applications应用进程92204仍运行，须用户保存退出。未提交/推送，不能关闭Issue。评论脚本/private/tmp/subtools-comments.01a0b9b5-7646-76b0-9028-2402885d401b.py已成功为#69/#73/#74/#75/#76/#66补记当前结果；开放工单标待验收，未修改关闭状态，重复执行先按标记查重。

## 外观、历史与绘图属性验收修复（2026-09-22）

用户确认来源存在，实际不可见原因是浅色文字颜色；#69改为此缺陷。新增#73外观hover、#74历史自动刷新、#75图形合并/画笔马赛克、#76第二行及按工具保存属性。禁止computer-use；未提交或推送，不能关闭Issue。

NativeGlassSegments局部TextButton明确禁用默认overlay，实际像素hover回归通过。HistoryApp在实际主题Builder下重建缓存文字样式；成功写入经原生通知刷新历史，版本号排除迟到响应。图形支持矩形/圆形描边和填充，画笔支持普通/马赛克，绘图属性通过主引擎settings队列持久化。第二行32pt、间距4pt、双行总高84pt；每工具独立颜色/线宽，文字草稿与默认值独立，编辑已有文字不覆盖未来默认值。DrawingPreferences新增目录索引，旧工具排序/快捷键/显隐合并。

最终Flutter117项通过，analyze无问题；原生25通过、1因测试进程未获录屏权限跳过。索引38目录192文件与spec链接检查通过。产物dist/TranslateApp.zip固定签名TranslateApp Local Signing，deep/strict和ZIP完整性校验通过，SHA256 e5dd040a908bbf811dcb06ae889cadb7315aa2057bb0095b91a5ab61b4cd354e。日志/private/tmp/refine.01a0b9b5-7646-76b0-9028-2402885d401b/。尚未安装，当前已安装进程31529在运行，需要用户保存退出。本地spec完整；最终GitHub同步及验收评论重试均遭遇EOF，系统curl的IPv4/TLS1.2也失败。初始spec和Issue创建已成功，最终补充尚未同步；网络恢复后运行publish-spec.py和comment-delivery.py（评论带去重标记），不得声称最终同步或待验收标签已完成。

## 紧凑设置与 #69–#72（2026-09-22）

用户授权先更新Spec再实现分段按钮无hover、按下反馈、快捷键同排及删除相关底部说明，并实施#69–#72。禁止computer-use，用户效果验收；本轮未提交或推送。

本地及GitHub #1/#67/#68已同步数值。新增不可变DrawingStyle、独立ColorPicker与StrokeWidthPicker；图形默认黑色填充或12px马赛克，线宽1–20pt默认3步长1，调色盘含色域、色相、8预设和6位HEX。选中修改沿用文档撤销；PNG/预览同绘制器；文字草稿调色保留输入，旧工具延迟单击不能变成新工具输入。

#69在原文采集开始时从同一NSRunningApplication冻结名称和PID，异步完成不重查PID。真实名称与失效PID事件编码测试通过；这修复一个丢失路径，但用户现场新记录空值根因未复现，仍需新构建人工验收。不得用strings缺少完整sourceAppName宣称混合二进制，Swift短字符串可能拆分成指令立即数。

最终v8 Flutter111项通过，analyze无问题；原生25通过1因屏幕录制权限跳过。38目录191文件索引覆盖与diff check通过。日志/private/tmp/drawing.01a0b9b5-7646-76b0-9028-2402885d401b。#69–#72评论并标待验收，#66追加设置说明，没有关闭Issue。固定签名Release已生成dist/TranslateApp.zip，证书TranslateApp Local Signing（BC17D788EC4AB832B46614F9198FAA3A80A5402A），ZIP SHA256 f7d495f53da23116b69634e43ca5f4b3ab114f9bcf8f663549439f4e8f3087c3；解包deep/strict验证通过。尚未安装，/Applications/TranslateApp.app进程834仍运行，安装前需用户保存退出。

## 目录索引与提交（2026-09-21）

用户授权为维护目录新增逐项一句话index.md、汉化AGENTS.md并提交全部相关改动。已生成38个目录索引，覆盖152个原有维护文件及直接子目录；排除Git元数据、依赖缓存、构建输出和个人工作区。索引覆盖与链接检查通过，规则明确后续新增/删除/重命名文件同步维护索引。

提交前flutter test --no-pub共105项通过，flutter analyze无问题，git diff --cached --check通过。功能与回归测试已本地提交0433882，提交正文逐项注明相关Issue、完成事项以及#61/#63/#69仍未解决和#70–#72只做规格的边界。文档与索引单独提交，不推送、不关闭Issue、不computer-use。

## 当前任务：三类Spec与新增工单（2026-09-20）

用户已授权本地/GitHub分功能与交互、样式、架构三类Spec并新建4个Issue；此前不创建Issue限制由本轮明确授权更新，仍禁止关闭Issue、computer-use或修改功能代码。#8由用户手动关闭。

本地docs/specs/{functional,style,architecture}.md及README索引已整理，AGENTS、UI规则入口、领域、tracker、README、架构实现文档已连接。样式保留明确数值并将调色盘/线宽/图形模式未确认参数显式列出；共享模型+能力映射+独立控件组合设计已写入架构约束。

GitHub三类Spec为#1功能与交互、#67样式、#68架构；执行工单#69历史来源、#70图形、#71共享颜色与调色盘、#72共享粗细已发布。三类正文互链、执行清单及4张工单在#1下的原生父子关联已完成；#8追加独立来源工单关联评论，未改Issue关闭状态。发布脚本完成远端逐项回读并检查无占位符。三类本地正文与发布稿同步，本地6份Markdown链接检查与git diff --check通过。临时发布记录在/private/tmp/spec-split.01a0b9b5-7646-76b0-9028-2402885d401b/published.json。调色盘/线宽/图形模式待确认数值继续在样式Spec列出，本轮未实施功能代码。

## 当前任务：快捷键、工具显隐与历史来源（2026-09-20）

用户反馈全部截图工具快捷键失效；新完成历史的来源仍为空。禁止computer-use和UI自动化，效果由用户验收。不得创建或关闭Issue。

快捷键根因已由原生测试先红证实：非激活截图面板的routeScreenshotKey缺少已保存工具组合的派发。现按keyId/modifiers匹配并消费，向Dart发送带captureId的screenshotToolbarAction语义动作；不重放字符。文字输入状态通知带captureId，拒绝旧捕获污染。隐藏工具仍可通过快捷键调用。相关原生4项通过，Dart相关19项通过；484pt列表宽度和Command+2录制持久化补充3项通过，analyze无问题。

眼睛开关已实现：15顶层工具默认显示，18pt蓝色睁眼/灰色划线眼、32pt命中，无独立背景；隐藏保留顺序与快捷键，即时保存并同步当前截图。拖柄在左，行分隔1pt；工具栏按可见按钮占位。Spec #1及本地规则已先同步，README/architecture已更新。#62已评论5748817349。

历史来源尚未修复：此前“已有来源App名”的判断证据不足，用户已否定效果。当前真实应用PID→原生事件编码测试testSelectionSourceSurvivesNativeEventEncoding通过；Dart/SQLite传递也未见丢弃。没有用户环境的空值payload，不把延迟PID查询的可能性当作根因，不改生产来源逻辑。已询问原文来自哪个App，等待答复。完整Flutter105项通过、analyze无问题，原生本轮5项通过。固定签名ZIP已生成，SHA256为9eb3a93c8433a06bb0d92cf069f99f252f02a08b87c744f0213160453aaca3d6；证书TranslateApp Local Signing及requirement保持不变。当前安装版仍是上一轮四角光标版，尚未替换。#8调查评论5748851361已发布并标回待实现。

## 四角原生光标修复（2026-09-20）

用户确认文本框和截图区域四角不显示对角拉伸光标。已证实根因：Flutter3.47.2 macOS引擎FlutterMouseCursorPlugin.mm映射没有resizeUpLeftDownRight/resizeUpRightDownLeft，未知kind回退arrow。此前纯Dart枚举测试漏掉原生显示。当前项目macOS26部署，AppKit公开frameResize(position:directions:)自15可用。

新原生测试testScreenshotDiagonalCursorUsesNativeFrameResize先红：实际arrow图像583248bytes/热点5,5，期望对角10092bytes/热点11,11。Dart新增共享NativeResizeCursor及MouseCursorSession，仅两对角经现有截图channel setResizeCursor发送nwse/nesw；Swift验证轴+窗口可见后调用AppKit原生光标，关闭/shutdown复位，迟到请求不影响桌面。横纵/文字/移动仍交Flutter；无新增依赖、无自绘光标、无平台降级。Spec #1补充原生显示验收要求并发布08:33:52Z；规则、architecture同步。

Dart截图定向22通过，analyze无问题。原生全量及新对角测试通过；固定签名包已安装并启动，strict/deep通过，安装与归档主程序一致。ZIP SHA256 459b871964bce1447cda1914817d6427447b4b5d959636fc99829ac63db6f201；主程序SHA256 e858ee9f0c70679fd9da8d0cb3f97e57ea6518b34e6d804db1bdcfc58504c41b。证书与requirement沿用固定身份。临时red/green Debug及解压/Release App均已核对身份并清理。#27已发布根因/红灯证据评论5748725513。继续禁止computer-use、不创建/关闭Issue。

## 本轮源码状态（2026-09-20 光标与工具配置）

用户补充：#61遮挡发生于computer-use期间；#63怀疑computer-use与TranslateApp联动。禁止computer-use，界面效果仍由用户验收。原生核查无持续SCStream、无普通字符post路径，设置contentLayoutGuide安全区回归成立；仅记录共现条件，不宣称已证明#63根因或修复#61所有场景。两项定位已评论到原Issue（#61 comment5748622937、#63 comment5748618775）。发现退出与异步截图并发任务未取消，未证明与本轮症状相关，暂未修改。

历史来源已核实：sourcePID→NSRunningApplication.localizedName→sourceAppName→主引擎冻结→SQLite source_label→历史标题。选中文本已有来源App名；旧记录不可补推，截图OCR只标“截图”。#8已评论说明（comment5748623379）。

本轮实现：贴图移除右上角关闭按钮，保留Esc/双击；光标工具优先命中选中文字控制点、顶层文字，再命中截图区域，均可选择/移动/拉伸；双击文字在第二次松开后编辑，截图仅裁剪工具新建框选。文本和截图共用八点视觉（8pt、24pt命中、边线±6pt）。#62改截图页底部默认收起页内列表，15顶层工具有图标和拖拽手柄，支持键盘上下排序，颜色/字号/Finder固定位置不自定义；移除已取消的上下文绑定，保留顶层相对顺序，未知ID仍报错。Spec #1先发布并回读确认（08:06:04Z），本地规则/README/architecture同步。

验证中：光标实际几何/导出尺寸回归已通过，排序真实拖拽/键盘回归已通过。排序测试84pt落在框架原位边界，改112pt跨过下一行中线后commit0→1；临时DEBUG已全部移除。原生22通过/1跳过（测试进程无录屏权限），临时Debug App已清理。完整Flutter 105项全部通过，flutter analyze无问题，git diff --check通过。固定签名本轮包已安装到/Applications/TranslateApp.app并启动，安装主程序与ZIP一致，strict/deep校验通过，requirement与上一固定签名版本完全一致。ZIP SHA256 ca2c871f553e32985473ef0b7270aa8d8512c2204f0b8a8665994916f6dfb896；主程序SHA256 ba0e51f08e6ac46e527917e7dcb71a08066ba31f80b21695c56aa1f1df0a61e4。临时解压与Release App均已清理；未读取或修改权限数据库。用户退出后完成安装，效果由用户验收。#27/#48/#62实现评论均发布成功（5748679155/5748676709/5748679845），未创建或关闭Issue。

## 当前交付状态（2026-09-20 固定签名安装）

本节为当前状态，后文为此前会话记录。用户禁止computer-use；效果验收由用户执行。不得创建或关闭Issue，只评论与中文标签。工作区未提交/推送，保留既有修改。

已实现：开关按钮手形光标；默认服务无底部介绍；初始截图框为未选中预览，可直接重新框选；后台保存无状态文字；翻译阅读面提供Material正文基底，消除黄色双下划线；透明截图工具栏padding8/gap4；历史译文原文间1pt线、上下10pt；贴图首次鼠标接受与拖动前选择；22个截图工具/上下文操作的排序、自定义快捷键、清除、冲突检查、持久化及热更新。文字输入状态同步原生，编辑快捷键与组词回车交给文本系统。

Spec #1逐组件说明书及本地liquid-glass-ui规则已同步，包含具体尺寸、圆角、间距、配色与输入契约；README、architecture、macos签名文档已同步。

验证：最终定向17项通过（settings_app4、settings_autosave3、screenshot_controls8、screenshot_toolbar_preferences2）；flutter analyze无问题，git diff --check通过。此前完整Flutter运行102通过/1失败，失败为旧“已自动保存”断言，修正后的相关文件已通过；不宣称完整套件全部重新运行。原生22通过/1跳过/0失败。

固定签名证书TranslateApp Local Signing有效，SHA-1 BC17D788EC4AB832B46614F9198FAA3A80A5402A。安装在/Applications/TranslateApp.app并已启动。ZIP SHA256 c15f50b81ca9fb8c90015fb28cb50f8442c19857b0019ac015477baba6691766；安装/归档主程序SHA256 80da07c589f635446825bd9cd4bed418ed9533fa46b1330293e4bb8c6b29a53e。strict/deep签名校验通过，designated requirement绑定com.coolyang.translateApp及证书，不含cdhash；不同内容重签身份一致。首次切换固定身份可能需要重新授权，未操作TCC数据库；不声称已证明权限永久保留。用户退出旧版后执行无GUI安装，失败恢复备份已随成功清理。

待用户验收：上述界面修正、历史分页及重启保持、贴图首次拖动、截图工具快捷键与排序、固定签名首次授权及后续更新保持。#63普通输入重复尚无复现，保留待实现；已修正的文字编辑原生吞键不代表普通重复问题已解决。#61系统录屏标记覆盖红绿灯尚未解决。

自动审批拒绝了含创建新Issue的操作，已改为只对现有Issue评论与打标签。回填脚本为/private/tmp/implementation.01a0b9b5-7646-76b0-9028-2402885d401b/comment-final-fixed.py。#8、#48、#62已评论并标为待验收，保持OPEN；验收、修复及固定签名记录已发布到现有 #27、#56、#58、#65、#66、#57、#8、#48、#62、#63、#16；最后一次补发返回FAILED_ISSUES []。#63保持待实现，未创建或关闭任何Issue。临时签名验证original/modified App已在核对身份及无运行后删除，Release构建App已清理；保留安装版与ZIP。

## 当前实现

数值规格位于 Spec #1 的「UI 数值规格（TranslateApp）」及 `docs/agents/liquid-glass-ui.md`；尺寸常量在 `lib/src/common/constants/glass_metrics.dart`。标准控件复用 `NativeGlassSurface`；材料平台视图从语义与键盘焦点遍历中排除。菜单打开时聚焦当前值，关闭后焦点回到触发器。圆角采用 Flutter 连续超椭圆，原生材料使用 NSGlassEffectView。

设置导航嵌入页面；标题在字段轮廓外，长当前值换行；离散编辑自动保存，滑块调整结束提交。保存使用版本化串行事务，失败保留草稿并允许重试，旧快照不覆盖新编辑。主要按钮32pt、普通按钮28pt、独立命中区域至少32pt，触发按钮84×30pt、原生命中窗口84×32pt。截图工具栏48pt，复制成功提示1000ms。

长文恢复使用 TranslationProgress，只保留完整片，失败从当前片重试；冻结提供方与语言方向，完整成功前不写历史。跨模块平台协议、状态、外观模式与通知均在 common 常量中。协议/安全过滤/剪贴板/编辑状态函数与类型注释已独立核验补齐。

## 验证与安装

完整Flutter测试96项通过；最终设置规格4项定向检查通过，包含开关标题悬停像素回归。flutter analyze无问题，git diff --check通过。原生测试21 passed、1 skipped、0 failed。

安装产物：`/Applications/TranslateApp.app`，归档：`dist/TranslateApp.zip`。ZIP SHA-256：`ef247feace9a186648280d51012a7dca3d939f4762edec01dbcddfed2e309af6`。安装版严格签名检查通过，归档/安装主可执行SHA-256一致：`ed548b8bb5183bdda5589f0eb83e912697c9cbcf7bd7472ad9dfe2da1ca431b2`。安装后的源码补充仅涉及回归测试，不改变运行逻辑。源代码未提交/推送；工作区有本轮开始前的修改，必须保留。

实机通过：设置/权限窗口的浅深色、透明度0%/80%、重启持久化、菜单鼠标/键盘选择、外置标签、当前值完整展示、服务弹窗阅读底色、截图快捷键短按钮轮廓。验收后已恢复原有深色/0%透明度和OpenAI-compatible默认服务，未改变用户凭据。

## 尚待完成

最终安装版的辅助功能与屏幕录制均显示已授权。用户已自行完成权限开启，无需请求权限刷新或修改TCC数据库。

待继续实机验收：真实区域截图复制1秒提示、回车复制退出、选区翻译触发84×30居中/拖动、历史/设置/截图/翻译多引擎外观同步，以及系统可访问性/多屏组合。#7、#51、#64、#65按已具备证据关闭；#56–#61保留needs-verification，未宣称所有实机验收完成。

本会话测试Debug App已在核对身份与无运行进程后清理，保留安装版和ZIP。临时日志、tracker脚本位于 `/private/tmp/implementation.01a0b9b5-7646-76b0-9028-2402885d401b/` 及验证子任务的完整thread-id路径。

Tracker回填：#7、#51、#64、#65已成功发布本轮验收评论并关闭。#56–#61仍为既有needs-verification；补充本轮最终构建评论时GitHub API连续TLS EOF失败，尚未发布这6项的新评论。重试脚本 `update-verified-issues.py` 已跳过关闭的4项，并在写入前查询唯一标题/完整线程ID避免重复。

## 设置页六项修订（2026-09-20）

Spec #1「设置页面与服务约束」已发布并回读确认；AGENTS.md明确后续先更新Spec及规则，再实现验收。本轮跟踪Issue #66，已附测试、安装与实机验收证据并关闭。

普通窗口由 NativeReadingCanvas 与 NativeGlassWindowPage 提供同一 sRGB、不透明阅读背景（浅#F7F7F7/深#171717），AppKit负责唯一外圆角；系统安全区保留，红绿灯下无第二个圆角面板。导航独立于ListView：左右22、上下12、控件高32，正文距导航8。外观分段平整228×28、每段76、r8、无内缩；选中蓝#007AFF白#FFFFFF，相邻未选分隔1pt/上下7pt/35% onSurface。开关行hover/focus/pressed透明。辅助功能与录屏都在通用页，截图页只放目录和快捷键。

新建服务为谷歌翻译、百度翻译、OpenAI、Anthropic。已有OpenAI-compatible默认名显示OpenAI，自定义名保留；现有DeepSeek协议ID继续工作，新建菜单不单列，未迁移端点、模型或凭据。

完整Flutter96项通过，最终分隔线后控件/规格定向6项通过；analyze无问题。原生21 passed / 1 skipped / 0 failed。最终 settings_spec_test 4项通过，包含开关标题hover前后像素一致回归；flutter analyze再次通过。

安装归档SHA-256：ef247feace9a186648280d51012a7dca3d939f4762edec01dbcddfed2e309af6；安装/ZIP主可执行SHA-256：ed548b8bb5183bdda5589f0eb83e912697c9cbcf7bd7472ad9dfe2da1ca431b2。签名通过、临时Debug App已清理。

实机确认：连续标题背景、分段白字、滚动时固定导航、两权限集中通用、服务名称与四项新建菜单。已取消验收用服务草稿，没有新建服务或改变凭据。用户同时操作应用，部分CUA操作因用户状态变化被拒绝后重新取状态；不得依赖旧坐标。最终应用已显示辅助功能和屏幕录制均已授权（用户自行操作完成），无需再申请旧的开关刷新许可。

## 逐组件说明书与修订（2026-09-20）

用户禁止智能体关闭Issue，只允许评论与标签。AGENTS.md、issue-tracker规则、README均已同步。18个标签已原地汉化并保留关联。#8/#48/#62/#63保持OPEN，已评论未完成并标待实现；#65/#66保持原CLOSED状态，追加反馈与待验收标签，不据此认定完成。

Spec #1先发布逐组件说明书：布局/尺寸/圆角/状态/输入输出/验收；滑块仅6pt轨道+16pt白点，无玻璃外壳，蓝#007AFF、未选20%onSurface；开关仅36×32按钮响应，标题说明空白不可切换；服务操作各32×32，图标16/padding8、两按钮gap8；次要语言精确一句，翻译快捷键无常驻底部说明；默认560×720单服务免滚动。裁剪点8pt、24pt命中，边线±6pt及对应方向光标。

根因回归：旧开关标题点击确实改变值；原生预选crop初始cropSelected=false使左上显示precise。修复共享开关、预选状态和光标状态更新；拖动保持activeHandle方向；静止鼠标随裁剪状态更新。修改geometry命中用于角/中点优先，再边线，再内部。只使用公开Flutter系统光标，未添加NSCursor桥。

验证：完整Flutter运行98通过/2失败，失败均为测试输入契约（新测试漏systemStatus、旧滑块端点坐标）；修正后settings_spec6项+glass_appearance2项通过；analyze无问题。八点/四边/内外光标回归与开关点击范围回归通过。构建安装由native_validation执行，待记录新哈希与实机结果。

标题遮挡：CUA实机确认紫色系统共享标记覆盖小窗口红绿灯位置；AppKit AX三按钮仍存在，点击zoom可放大再恢复。源码标准titled/closable/miniaturizable/resizable+fullSizeContentView与contentLayoutGuide，不绘制紫色标记。公开SDK未发现移动/关闭隐私标记接口；不通过sharingType.none、关权限、伪造红绿灯绕开。待用户说明正在使用哪个录屏工具及最终实机点击验收，尚未解决，不得标已完成。


本轮新包已安装运行：ZIP SHA256 c729f30a3692f20d6d49b2d70a312e2f177442ddf0e071de12f43f012c6bc8c2；安装/ZIP主可执行SHA256 3e6ac4600cc7b89f7dbbb3c225ca0e4b39b7b8dad05abec34d3523258d6b1d44；CDHash 8c2a465ce3a69d7880374eff1d3bab8f4657357c，strict codesign通过。非GUI安装流程有备份和失败恢复，未操作旧副本。生成Debug/Release App均不存在。

实机已确认本轮滑块无外壳、白色滑点/6pt轨道，翻译页单服务默认尺寸不滚动、8pt服务操作间距、次要语言一句、快捷键无底部说明、仅使用快捷键标题点击不变且无整行背景。原用户深色/0%透明度/快捷键开关状态保持，未修改凭据。

新ad-hoc安装启动后辅助功能与录屏再次报告未授权。应用正常申请入口打开系统录屏页，TranslateApp开关实际为on；未触碰开关，也未绕过此前“短暂关闭再开启需要确认”的自动审批边界。裁剪安装版实机验收因系统授权缓存不一致尚未执行；回归测试不等于系统鼠标渲染实机验收。

远端状态新核对：#56–#60已由其他操作关闭，#61仍OPEN；不沿用较早的#56–#61全部OPEN说法。本轮对#27/#58/#61追加组件修订评论，#27/#58保持原关闭状态，#61保持开启；未执行关闭动作。
