# v0.1.0 验证记录

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
