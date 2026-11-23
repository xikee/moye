# 墨页验证记录

## 2026-11-22 文档安全修复验证

环境：本机 macOS、Apple Silicon。`npm test` 3 项通过，`npm run test:native` 25 项通过，`npm run build` 通过；修正菜单校验的选择器警告后，重新构建原生应用通过。真实 WKWebView 集成检查 33 项全部通过。

本轮覆盖：

- 恢复前的新建、载入、保存和关闭受到保护，草稿暂存不写入初始空状态；此阶段退出保留原有恢复文件。
- 每次载入分配代次，旧编辑消息和旧载入确认不会改变当前文档。
- 关闭时选择“不保存”后重新显示窗口，原生内容、正文、源码和两种模式的撤销历史一致；撤销不能恢复已放弃的编辑。
- 放弃修改后打开目标失败，仍保留原保存基线、文件路径和一致的编辑器内容。
- 外部修改或非 UTF-8 文件的保存取消操作保持磁盘内容；明确覆盖后才写入新内容。原文件删除后，取消不会重建，确认后才重新创建。
- 打开和保存共用包含边界的 20 MiB 提醒阈值；测试 UTF-8 字节计数、首次跨越阈值、重复保存和新目标提醒，并验证超过旧上限的内容可完整写入和读取。容量策略为提醒后允许继续，没有新增硬性读写上限。

集成测试执行实际原生文档方法和 WKWebView 编辑器，通过脚本选择 NSAlert 的响应，没有逐个点击真实系统面板。测试模式不读写用户草稿；大于 20 MiB 的验证覆盖原生文件往返和提醒策略，未对该体积文档进行界面性能测试。完整结果位于本地 `build/document-safety-check/result.json`。

原有编辑历史、图片 alt、HTML 和分页 PDF 检查继续通过。PDF 仍输出系统 CoreText 字体回退提示；未逐字核对所有导出字形或公式。此轮未提交或推送，未运行远端 CI。

## 2026-11-19 定向重构验证

环境：macOS 14.8.9、Apple Silicon。`npm test` 3 项通过，`npm run test:native` 8 项通过，`npm run build` 和签名检查通过。真实 WKWebView 集成检查共 18 项通过；浅色和深色窗口截图已查看，界面正常。

新增覆盖：

| 检查 | 验证内容 |
| --- | --- |
| imageAltPreserved | 正文实际编辑后，中文、数字、空图片 alt 与标题保留 |
| fileListStableDuringEdit | 编辑时原生状态回传不会重建文件列表节点 |
| richHistorySurvivesViewingSource | 仅查看源码后，正文撤销历史和内容保留 |
| sourceSyncHasNoUndoEntry | 首次同步源码不产生整篇替换撤销项 |
| sourceExportDoesNotMutateRichState | 源码修改后导出使用新源码，但不修改隐藏正文及其历史 |
| sourceHistorySurvivesViewingRich | 仅查看正文后，源码撤销历史保留 |
| changedSourceResetsRichHistory | 源码修改后正文使用新的撤销基线 |

原生恢复测试覆盖：干净快照采用磁盘新内容、保留文件路径、未保存编辑及原保存基线、文件丢失时保留草稿、无路径草稿隔离，以及 JSON 格式兼容。该测试已加入 GitHub Actions；远端 CI 本次未运行。

完整结果见 [verification.json](analysis/typora/verification.json)，方案依据见 [Typora 对比与墨页改进记录](TYPORA-ASSESSMENT.md)。本地 smoke 输出与截图位于 `build/refactor-check/`。PDF 检查输出系统 CoreText 字体回退提示，页数及末段文本断言通过；未对所有导出字形与公式逐一做视觉核对。

以下保留初始版本的验证记录。

## v0.1.0 初始验证

验证日期：2026-11-10。环境：macOS 14.8.9，Apple Silicon，Swift 5.9；Web 资源完全随应用打包，无运行时 CDN 或服务依赖。

## 自动检查

`npm test`：3 项通过，覆盖 Markdown 大纲（包含代码围栏与 Setext 标题）、中西文字数与文件名边界。

`npm run build`：TypeScript 类型检查、Vite 生产构建、原生 Swift 编译与 ad-hoc 签名通过。

真实 WKWebView 集成检查：11 项通过。

| 检查 | 验证内容 |
| --- | --- |
| editorReady | 本地编辑器和打包资源完成初始化 |
| outline | Markdown 标题正确生成大纲 |
| loadPreservesMarkdown | 打开文件不改写原始标记，也不产生修改状态 |
| sourceMode | 可以切换至 CodeMirror 源码模式 |
| sourceEditReachesNative | 编辑源码后，中文内容和修改状态到达原生层 |
| modeSwitchPreservesMarkdown | 切换编辑模式保持内容一致 |
| richEditReachesNative | 即时渲染编辑的内容到达原生层 |
| nativeSave | 原生保存结果与编辑内容一致，保存后清除修改状态 |
| htmlExport | HTML 保留表格、粗体与代码语言 |
| pdfExport | 短文导出为 1 页 A4 PDF，文件大小合理 |
| multipagePDF | 120 段中文生成 6 页 A4 PDF，末段内容保留 |

修复后重复执行同一集成检查，验证初始化无需等待窗口动画帧。

## 版面检查

使用应用自身 WKWebView 快照核对浅色与深色界面；使用 Poppler 渲染 PDF，核对中文、任务勾选、代码、表格和多页正文，无重复页面或异常空白页。

## 验证范围

上述集成测试调用真实编辑器和原生保存代码，但未用桌面自动化逐个点击系统文件选择框、打印面板或保存确认框。未在 Intel Mac、其他 macOS 版本或另一台机器上验证，也未进行 Apple 公证。

当前单文档模型把窗口和文件职责放在原生层，编辑交互放在 Web 层，PDF 单独排版；避免引入账户、数据库或同步服务。
