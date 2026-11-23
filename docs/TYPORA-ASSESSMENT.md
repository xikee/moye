# Typora 对比与墨页改进记录

日期：2026-11-19。结论：保留墨页项目，定向重构文档可靠性与编辑器集成。现有证据不支持为了接近 Typora 而整体重写原生层，也不足以证明必须弃用 Milkdown。

## 结论依据

本地参考对象为 Typora 1.14.15（7789），`Typora.app`。墨页当前版本为 0.1.0。此次检查读取应用包、依赖信息及现有墨页源码，没有运行 Typora，也没有将 Typora 的实现代码、主题、图标或其他资源用于墨页。

| 比较项 | 新建项目复刻 | 保留墨页定向重构 |
| --- | --- | --- |
| 原生文件与窗口 | 重新建立并验证 | 保留已实现的 AppKit/WKWebView、打开保存、外部修改检查 |
| 编辑内核 | 仍需选择现成引擎或独立实现 | 先修复已确认的集成问题，再用兼容性验证决定是否替换 |
| 草稿与导出 | 重新实现恢复、HTML、分页 PDF | 保留现有链路，修正恢复和导出状态副作用 |
| 接近 Typora 的主要成本 | Markdown 语义、交互细节与回归测试依然需要完成 | 同样需要补兼容性，但无需重复建立已工作的原生基础 |
| 当前风险 | 同时承担功能重建和新架构回归 | 可按具体问题逐项验证，改动范围更小 |

墨页已经具备单文档编辑的主要链路，基础测试和生产构建均能通过。它的主要差距集中在文档语义与状态管理，以及未覆盖的产品能力；更换整个应用框架不能自动消除这些差距。

本机应用包磁盘占用约为 Typora 46 MB、墨页 14 MB。该数字只说明这两个本地构建的体积，不代表启动速度、输入延迟、内存或功能完整度。

## craft-anything 的学习与实际运行

参考：[官方仓库](https://github.com/storytold/craft-anything)、[v0.6.1 源码](https://github.com/storytold/craft-anything/tree/v0.6.1)、[工具目录](https://github.com/storytold/craft-anything/blob/v0.6.1/docs/tools.md)。

使用官方 macOS universal CLI **0.6.1**。发布标签指向 `48a9c5a60ff83ff620f98661339be6281a7debc6`。下载归档 SHA-256 为 `ddbae05f52a5526e149f656b0b44cf73a60ad9ec0a33d718f330bf231b988c2f`，与 GitHub 发布元数据一致；macOS 签名验证通过，开发者为 Learning Machines LLC，Team ID 为 `DJ6XS33FX8`。工具放在独立临时目录运行，未全局安装，也未注册为 MCP。

craft-anything 的桌面端、CLI 与 MCP 使用同一引擎。它支持先分析再生成和比较项目，但官方明确标注仍为 early alpha，桌面行为对比尚不完整。本次使用不需要 AI 的本地静态检查；`--deep` 仅作用于本次命令，没有运行自动重建代理。

实际运行的检查：

| 工具 | 产出及结论 | 边界 |
| --- | --- | --- |
| `app-folder-explain` | 扫描 887 个目录项，识别 Typora 版本与原生程序 | 只查看少量文件内容，不证明所有资源都在运行时使用 |
| `apple-app-graph-build` | 原生可执行文件、Sparkle、97 个界面文件、WebView 内容线索 | 主要根据应用包结构推断 |
| `native-library-calls-list` | 读取主程序 arm64 导入；筛选 WebKit 后观察到 `WKWebView` 等 14 个导入 | 只分析 universal 程序中的 arm64 切片；完整导入列表输出为分页结果 |
| `js-app-map` | 分析 TypeMark 的 JavaScript/Web 资源，识别打包与模块线索 | 结果为部分覆盖，节点上限导致 31,777 个节点未保留，不能当作完整实现图 |

可复用的命令形式（在已提供 CLI 的环境中）：

```bash
craft-anything-cli --deep app-folder-explain --path "$PWD/Typora.app"
```

```bash
craft-anything-cli --deep apple-app-graph-build --path "$PWD/Typora.app"
```

```bash
craft-anything-cli --deep native-library-calls-list "$PWD/Typora.app/Contents/MacOS/Typora" --contains WebKit
```

```bash
craft-anything-cli --deep js-app-map --input-path "$PWD/Typora.app/Contents/Resources/TypeMark" --max-files 400 --max-total-bytes 40000000 --max-nodes 2000 --limit 15
```

**需要交叉验证的工具结论：** `js-app-map` 将 TypeMark 的 JavaScript 资源标记为 Electron；单靠共享脚本中的 Electron 线索不能认定此 macOS 主程序使用 Electron。应用包没有观察到 Electron Framework，主程序实际导入 AppKit 与 WKWebView。这里采用“原生程序 + WebView 编辑资源”的判断，保留原工具标签与覆盖限制以便复核。

证据文件位于 [analysis/typora](analysis/typora/folder.json)：`folder.json`、`apple-graph.json`、`imports.json`、`webkit-imports.json` 和 `javascript-summary.json`。大型 JavaScript 原始结果保留在本地 `build/refactor-check/craft-javascript-raw.json`，摘要不包含重建所需的原实现。

## 已执行的定向改进

### 图片语义

Crepe 默认块图片节点把 Markdown 的 alt 当作缩放比例读取，并以数字比例序列化回 alt。因此，在正文其他位置编辑也会把 `![示意图](a.png)` 中的替代文本改写。

新增 `src/markdown-editor.ts`，通过公开 schema 配置分离 alt 与 ratio，保留中文、数字和空 alt 以及图片标题；DOM 导出也使用标准 alt/title。缩放比例是编辑器内的显示属性，不再写入 Markdown alt，因此该比例不会通过 Markdown 保存恢复。

### 双模式撤销

原实现每次进入源码模式都派发全文替换，返回正文模式也全文替换，可能污染撤销历史。现在仅在内容确实不同的时候同步：

- 只切换查看：保留各编辑器已有历史与选区。
- 在另一模式修改后返回：以新内容重新建立目标编辑器状态和撤销基线，避免撤销越过旧整篇替换而抹去新内容。
- 打开另一文档：清空该文档的旧编辑历史。

这是按模式管理历史的明确约定，并非跨模式统一撤销栈。

### 导出无状态副作用

源码模式 HTML 导出通过 parser 和 DOMSerializer 创建独立文档，不再把源码先替换进隐藏的正文编辑器。原生 PDF 继续复用 HTML 导出和现有独立排版器。导出不再改变正文文档与撤销历史。

### 草稿恢复

将 Draft 模型和恢复规则提取到 `native/Draft.swift`，保留原 JSON 格式：

- 干净的文件快照：读取当前磁盘内容，避免重启后显示退出前的过期版本。
- 未保存草稿：保留编辑内容与原保存基线，使保存时的外部修改检查继续有效。
- 干净快照的原文件不可读：保留快照并移除原文件位置，作为未保存位置的文档恢复。

### 输入刷新

文档状态回传仅在路径变化时重新渲染文件列表；文件列表数据更新仍正常刷新。逐字输入和草稿状态更新不再销毁重建侧边栏全部文件按钮。打开文档时也取消旧的大纲刷新计时器。

没有把全文桥接简单改成防抖，避免在未建立保存 flush/ack 协议前引入最后输入尚未送达的问题。

## 验证结果

本机 macOS 14.8.9、Apple Silicon：

- `npm test`：3 项通过。
- `npm run test:native`：8 项通过，覆盖磁盘更新、未保存编辑、冲突基线、文件缺失与 JSON 兼容。
- `npm run build`：类型检查、Web 打包、Swift 编译和 ad-hoc 签名通过。
- 真实应用 `--smoke-test`：18 项通过，包含原有编辑/保存/HTML/PDF 检查，以及新增图片 alt、双模式历史、导出状态隔离和文件列表节点保留检查。
- 已读取真实 WKWebView 的浅色与深色截图，窗口内容正常。

新增原生恢复测试已接入 GitHub Actions；本次没有推送或在远端运行 CI。完整检查项目见 [TESTING.md](TESTING.md)，实际布尔结果见 [verification.json](analysis/typora/verification.json)。

新增测试辅助方法首次运行出现主线程断言，随后发现 WKWebView 异步 JS 返回 undefined 的测试调用问题；均已修正，最终完整检查通过。PDF 检查期间系统输出 CoreText 字体回退提示；PDF 页数和末段文本断言通过，本次未验证所有字形和公式的视觉一致性。

## 结论边界

这些改动完成了已确认问题的第一组修复，并未实现 Typora 的全部行为。现有正文编辑依然会对整篇 Markdown 序列化，不能承诺编辑其他段落时保留原文每个字节。front matter、脚注、引用式链接、原始 HTML、图表及其他扩展语法的完整往返兼容性尚未验证。

相对图片跨目录另存、HTML/PDF 的完整公式排版、跨模式统一撤销、桥接 revision/flush 协议、多文档、目录树与持续文件监听也不在本次完成范围。大文档输入延迟和内存没有做性能基准测试；本次能确认减少了文件列表重建，不能据此给出性能提升比例。

craft-anything 能帮助建立证据与重建任务，但静态分析、生成新项目与达到成熟编辑器的兼容程度之间仍有明显距离。本次选择保留墨页，是基于现有功能可以复用及具体缺陷可以定向修复，而非基于工具的自动生成承诺。
