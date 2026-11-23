import AppKit
import WebKit
import UniformTypeIdentifiers
import PDFKit

// 编辑内容由原生层持有；WebView 只负责排版和编辑交互。
final class ResourceHandler: NSObject, WKURLSchemeHandler {
    var documentDirectory: URL?
    let root: URL

    init(root: URL) { self.root = root }

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url else { return }
        let isDocument = url.host == "document"
        guard url.host == "app" || isDocument,
              let base = isDocument ? documentDirectory : root else {
            urlSchemeTask.didFailWithError(NSError(domain: NSURLErrorDomain, code: NSURLErrorFileDoesNotExist)); return
        }
        let path = url.path == "/" ? "index.html" : String(url.path.dropFirst())
        let target = base.appendingPathComponent(path).standardizedFileURL.resolvingSymlinksInPath()
        let basePath = base.standardizedFileURL.resolvingSymlinksInPath().path + "/"
        guard target.path.hasPrefix(basePath), let data = try? Data(contentsOf: target) else {
            urlSchemeTask.didFailWithError(NSError(domain: NSURLErrorDomain, code: NSURLErrorFileDoesNotExist)); return
        }
        let mime: String
        switch target.pathExtension.lowercased() {
        case "js", "mjs": mime = "application/javascript"
        case "css": mime = "text/css"
        case "html": mime = "text/html"
        case "svg": mime = "image/svg+xml"
        case "woff2": mime = "font/woff2"
        case "woff": mime = "font/woff"
        default: mime = UTType(filenameExtension: target.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        }
        urlSchemeTask.didReceive(URLResponse(url: url, mimeType: mime, expectedContentLength: data.count, textEncodingName: mime.hasPrefix("text/") || mime.contains("javascript") ? "utf-8" : nil))
        urlSchemeTask.didReceive(data)
        urlSchemeTask.didFinish()
    }
    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate, NSMenuItemValidation {
    var window: NSWindow!
    var webView: WKWebView!
    var resources: ResourceHandler!
    var content = ""
    var savedContent = ""
    var fileURL: URL?
    var documentName = "开始书写.md"
    var ready = false
    var session = DocumentSession()
    var canUseDocument: Bool { ready && session.synchronized }
    var pendingOpen: URL?
    // smoke 使用脚本化面板选择，仍执行实际文档流程，且不触碰用户草稿。
    var smokeResponses: [NSApplication.ModalResponse] = []
    var smokeStartupChecks: [String: Bool] = [:]
    var recoveryWork: DispatchWorkItem?
    var folderURL: URL?
    var allowedFilePaths = Set<String>()
    var dirty: Bool { content != savedContent }
    let defaults = UserDefaults.standard
    let supportURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("MoYe", isDirectory: true)
    var recoveryURL: URL { supportURL.appendingPathComponent("draft.json") }
    var isSmokeTest: Bool { ProcessInfo.processInfo.arguments.contains("--smoke-test") }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSWindow.allowsAutomaticWindowTabbing = false
        makeMenus()
        guard let resourceURL = Bundle.main.resourceURL else { fatalError("Missing resources") }
        resources = ResourceHandler(root: resourceURL.appendingPathComponent("Web"))
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(resources, forURLScheme: "moye")
        configuration.userContentController.add(self, name: "native")
        if isSmokeTest {
            configuration.userContentController.addUserScript(WKUserScript(source: "window.addEventListener('error', e => window.webkit.messageHandlers.native.postMessage({action:'error',message:e.message})); window.addEventListener('unhandledrejection', e => window.webkit.messageHandlers.native.postMessage({action:'error',message:String(e.reason)}));", injectionTime: .atDocumentStart, forMainFrameOnly: true))
        }
        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = false
        if #available(macOS 13.3, *) { webView.isInspectable = true }
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 820), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "墨页"
        window.minSize = NSSize(width: 760, height: 560)
        window.titlebarAppearsTransparent = true
        window.backgroundColor = NSColor(calibratedRed: 0.988, green: 0.988, blue: 0.98, alpha: 1)
        window.delegate = self
        window.contentView = webView
        window.setFrameAutosaveName("MoYeMainWindow")
        if !window.setFrameUsingName("MoYeMainWindow") { window.center() }
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        if isSmokeTest {
            newDocument()
            load("不应载入的初始内容", url: nil, name: "不应出现.md")
            smokeStartupChecks["startupCommandsBlocked"] = content.isEmpty && !session.initialized && !save() && !windowShouldClose(window)
            smokeStartupChecks["startupDraftWriteBlocked"] = !persistDraft()
            smokeStartupChecks["startupQuitPreservesDraft"] = applicationShouldTerminate(NSApp) == .terminateNow
        }
        webView.load(URLRequest(url: URL(string: "moye://app/index.html")!))
        if !isSmokeTest, let path = ProcessInfo.processInfo.arguments.dropFirst().first, !path.hasPrefix("-") {
            pendingOpen = URL(fileURLWithPath: path)
        }
        if isSmokeTest {
            DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
                guard let self = self, !self.ready else { return }
                self.webView.evaluateJavaScript("JSON.stringify({state:document.readyState,url:location.href,editor:!!window.moye,body:document.body?.innerText?.slice(0,400),scripts:[...document.scripts].map(s=>s.src)})") { value, error in
                    self.finishSmokeTest(["passed": false, "error": "Editor readiness timeout", "diagnostic": value as? String ?? error?.localizedDescription ?? "No response"])
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 50) { [weak self] in self?.finishSmokeTest(["passed": false, "error": "Integration test timeout"]) }
        }
    }

    func makeMenus() {
        let main = NSMenu()
        func submenu(_ title: String) -> NSMenu {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            main.addItem(item)
            let menu = NSMenu(title: title); item.submenu = menu; return menu
        }
        func add(_ menu: NSMenu, _ title: String, _ selector: Selector?, _ key: String = "", _ modifiers: NSEvent.ModifierFlags = .command) {
            let item = NSMenuItem(title: title, action: selector, keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers
            if selector != nil { item.target = self }
            menu.addItem(item)
        }
        let app = submenu("墨页")
        add(app, "关于墨页", #selector(about))
        app.addItem(.separator())
        let services = NSMenuItem(title: "服务", action: nil, keyEquivalent: "")
        services.submenu = NSMenu(title: "服务"); app.addItem(services); NSApp.servicesMenu = services.submenu
        app.addItem(.separator())
        let hide = NSMenuItem(title: "隐藏墨页", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h"); app.addItem(hide)
        let hideOthers = NSMenuItem(title: "隐藏其他", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h"); hideOthers.keyEquivalentModifierMask = [.command, .option]; app.addItem(hideOthers)
        app.addItem(.separator())
        app.addItem(NSMenuItem(title: "退出墨页", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        let file = submenu("文件")
        add(file, "新建", #selector(newDocument), "n")
        add(file, "打开…", #selector(openDocument), "o")
        add(file, "打开文件夹…", #selector(openFolder), "o", [.command, .shift])
        file.addItem(.separator())
        add(file, "保存", #selector(saveDocument), "s")
        add(file, "另存为…", #selector(saveAs), "s", [.command, .shift])
        file.addItem(.separator())
        add(file, "导出 HTML…", #selector(exportHTML))
        add(file, "导出 PDF…", #selector(exportPDF))
        add(file, "打印…", #selector(printDocument), "p")
        file.addItem(.separator())
        add(file, "关闭窗口", #selector(closeWindow), "w")
        let edit = submenu("编辑")
        // 由系统响应链处理撤销和剪贴板，兼容 WebKit 与中文输入法。
        for (title, action, key) in [("撤销", "undo:", "z"), ("重做", "redo:", "Z"), ("剪切", "cut:", "x"), ("复制", "copy:", "c"), ("粘贴", "paste:", "v"), ("全选", "selectAll:", "a")] {
            let item = NSMenuItem(title: title, action: Selector(action), keyEquivalent: key)
            if title == "重做" { item.keyEquivalentModifierMask = [.command, .shift] }
            edit.addItem(item)
            if title == "重做" || title == "粘贴" { edit.addItem(.separator()) }
        }
        edit.addItem(.separator())
        add(edit, "查找…", #selector(find), "f")
        add(edit, "查找下一个", #selector(findNextItem), "g")
        let format = submenu("格式")
        add(format, "粗体", #selector(bold), "b")
        add(format, "斜体", #selector(italic), "i")
        add(format, "链接", #selector(link), "k")
        let view = submenu("显示")
        add(view, "源码模式", #selector(sourceMode), "/")
        add(view, "显示 / 隐藏侧边栏", #selector(sidebar), "l", [.command, .shift])
        add(view, "专注模式", #selector(focusMode), "f", [.command, .shift])
        add(view, "打字机模式", #selector(typewriter))
        add(view, "切换明暗主题", #selector(theme))
        view.addItem(.separator())
        add(view, "放大文字", #selector(zoomIn), "+")
        add(view, "缩小文字", #selector(zoomOut), "-")
        add(view, "实际大小", #selector(zoomReset), "0")
        let full = NSMenuItem(title: "进入全屏幕", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f"); full.keyEquivalentModifierMask = [.command, .control]; view.addItem(full)
        let windows = submenu("窗口"); NSApp.windowsMenu = windows
        windows.addItem(NSMenuItem(title: "最小化", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m"))
        windows.addItem(NSMenuItem(title: "缩放", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: ""))
        let helpMenu = submenu("帮助"); NSApp.helpMenu = helpMenu
        add(helpMenu, "快捷键与使用说明", #selector(help))
        NSApp.mainMenu = main
    }

    func call(_ function: String, _ arguments: [Any] = [], completion: ((Any?, Error?) -> Void)? = nil) {
        guard ready else { return }
        let serialized = arguments.map { argument -> String in
            guard let data = try? JSONSerialization.data(withJSONObject: argument, options: [.fragmentsAllowed]), let string = String(data: data, encoding: .utf8) else { return "null" }
            return string
        }.joined(separator: ",")
        webView.evaluateJavaScript("window.moye.\(function)(\(serialized))", completionHandler: completion)
    }

    func command(_ name: String) { call("command", [name]) }
    func state(_ status: String? = nil) {
        window.title = "\(documentName) — 墨页"
        window.isDocumentEdited = dirty
        window.representedURL = fileURL
        var data: [String: Any] = ["name": documentName, "dirty": dirty, "path": fileURL?.path ?? ""]
        if let status = status { data["status"] = status }
        call("state", [data])
    }

    func load(_ text: String, url: URL?, name: String, recovered: Bool = false) {
        guard ready else { return }
        recoveryWork?.cancel()
        let generation = session.beginLoad()
        content = text
        if !recovered { savedContent = text }
        fileURL = url; documentName = name
        resources.documentDirectory = url?.deletingLastPathComponent()
        call("load", [["content": text, "path": url?.path ?? "", "name": name, "dirty": dirty, "recovered": recovered, "generation": generation]]) { [weak self] _, error in
            guard let self = self, self.ready, self.session.generation == generation else { return }
            if let error = error {
                self.state("编辑器载入失败，草稿已保留")
                self.showError("无法载入文档", error.localizedDescription)
                return
            }
            self.session.finishLoad(generation)
            if let url = self.pendingOpen {
                self.pendingOpen = nil
                if self.confirmUnsaved() { self.open(url) }
            }
        }
        state(recovered ? "已恢复上次草稿" : nil)
        persistDraft()
        refreshFiles()
    }

    func discardChanges() {
        // 载入操作同时清空两种编辑模式的撤销历史，并使旧代次的 change 消息失效。
        load(savedContent, url: fileURL, name: documentName)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        let documentActions: [Selector] = [#selector(newDocument), #selector(openDocument), #selector(openFolder), #selector(saveDocument), #selector(saveAs), #selector(exportHTML), #selector(exportPDF), #selector(printDocument), #selector(closeWindow)]
        guard let action = menuItem.action else { return true }
        return !documentActions.contains(action) || canUseDocument
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        if isSmokeTest { print("Bridge: \(message.frameInfo.request.url?.absoluteString ?? "nil")"); fflush(stdout) }
        guard message.frameInfo.isMainFrame, message.frameInfo.request.url?.host == "app",
              let payload = message.body as? [String: Any], let action = payload["action"] as? String else { return }
        switch action {
        case "ready":
            ready = true
            applyTheme(payload["dark"] as? Bool ?? false)
            if isSmokeTest { runSmokeTest(); return }
            if session.initialized {
                // Web 内容进程重启时优先使用原生内存快照，不能让磁盘草稿倒退当前编辑。
                load(content, url: fileURL, name: documentName, recovered: true)
            } else if let data = try? Data(contentsOf: recoveryURL), let draft = try? JSONDecoder().decode(Draft.self, from: data) {
                let disk = draft.path.flatMap { try? String(contentsOfFile: $0, encoding: .utf8) }
                let restored = draft.resolvingDiskContent(disk)
                savedContent = restored.savedContent
                load(restored.content, url: restored.path.map { URL(fileURLWithPath: $0) }, name: restored.name, recovered: restored.isDirty || restored.path == nil)
            } else {
                load(payload["welcome"] as? String ?? "", url: nil, name: "开始书写.md")
            }
        case "change":
            guard ready, let generation = payload["generation"] as? Int, session.acceptsChange(generation),
                  let text = payload["content"] as? String else { return }
            content = text; state("草稿正在暂存…"); scheduleDraft()
        case "new": newDocument()
        case "open": openDocument()
        case "openFolder": openFolder()
        case "openPath":
            if let path = payload["path"] as? String, allowedFilePaths.contains(path), confirmUnsaved() { open(URL(fileURLWithPath: path)) }
        case "save": saveDocument()
        case "saveAs": saveAs()
        case "exportHTML": exportHTML()
        case "exportPDF": exportPDF()
        case "theme": applyTheme(payload["dark"] as? Bool ?? false)
        case "error":
            let message = payload["message"] as? String ?? "未知错误"
            if isSmokeTest { finishSmokeTest(["passed": false, "error": message]) }
            else { showError("编辑器启动失败", message) }
        default: break
        }
    }

    func applyTheme(_ dark: Bool) {
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.backgroundColor = dark ? NSColor(calibratedRed: 0.125, green: 0.141, blue: 0.122, alpha: 1) : NSColor(calibratedRed: 0.988, green: 0.988, blue: 0.98, alpha: 1)
        webView.underPageBackgroundColor = window.backgroundColor
    }

    func scheduleDraft() {
        recoveryWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            if self.persistDraft() { self.state(self.dirty ? "草稿已暂存" : nil) }
        }
        recoveryWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: work)
    }

    @discardableResult func persistDraft() -> Bool {
        guard session.initialized else { return false }
        guard !isSmokeTest else { return true }
        do {
            try FileManager.default.createDirectory(at: supportURL, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(Draft(content: content, savedContent: savedContent, path: fileURL?.path, name: documentName))
            try data.write(to: recoveryURL, options: .atomic)
            return true
        } catch { state("草稿暂存失败，请按 ⌘S 保存"); return false }
    }

    func confirmUnsaved() -> Bool {
        guard canUseDocument else { return false }
        guard dirty else { return true }
        persistDraft()
        let alert = NSAlert()
        alert.messageText = "要保存对“\(documentName)”的修改吗？"
        alert.informativeText = "保存后再继续，或选择不保存以放弃这次修改。"
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "取消")
        alert.addButton(withTitle: "不保存")
        switch present(alert) {
        case .alertFirstButtonReturn: return save()
        case .alertThirdButtonReturn: discardChanges(); return true
        default: return false
        }
    }

    @objc func newDocument() {
        guard confirmUnsaved() else { return }
        load("", url: nil, name: "未命名.md")
        window.makeKeyAndOrderFront(nil)
    }

    @objc func openDocument() {
        guard canUseDocument else { return }
        let panel = NSOpenPanel()
        panel.title = "打开 Markdown 文件"
        panel.allowedContentTypes = [.plainText, UTType(filenameExtension: "md") ?? .plainText, UTType(filenameExtension: "markdown") ?? .plainText]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url, confirmUnsaved() else { return }
        open(url)
    }

    func open(_ url: URL) {
        guard ready, session.initialized else { return }
        do {
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard values.isRegularFile == true else { throw NSError(domain: "MoYe", code: 1, userInfo: [NSLocalizedDescriptionKey: "请选择一个文件。"] ) }
            if DocumentCapacity.needsWarning(byteCount: values.fileSize ?? 0), !confirmLargeDocument() { return }
            let text = try String(contentsOf: url, encoding: .utf8)
            load(text, url: url, name: url.lastPathComponent)
            if !isSmokeTest {
                var recent = defaults.stringArray(forKey: "recentFiles") ?? []
                recent.removeAll { $0 == url.path }; recent.insert(url.path, at: 0)
                defaults.set(Array(recent.prefix(30)), forKey: "recentFiles")
            }
            NSDocumentController.shared.noteNewRecentDocumentURL(url)
            refreshFiles()
            window.makeKeyAndOrderFront(nil)
        } catch { showError("无法打开文件", error.localizedDescription) }
    }

    @objc func openFolder() {
        guard canUseDocument else { return }
        let panel = NSOpenPanel(); panel.title = "选择 Markdown 文件夹"
        panel.canChooseDirectories = true; panel.canChooseFiles = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        folderURL = url; refreshFiles()
    }

    func refreshFiles() {
        var files: [[String: String]] = []
        if let folder = folderURL,
           let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles, .skipsPackageDescendants]) {
            for case let url as URL in enumerator {
                let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                if values?.isSymbolicLink == true { enumerator.skipDescendants(); continue }
                if values?.isRegularFile == true && ["md", "markdown", "mdown"].contains(url.pathExtension.lowercased()) {
                    files.append(["name": url.lastPathComponent, "path": url.path, "relative": String(url.path.dropFirst(folder.path.count + 1))])
                }
                if files.count >= 500 { break }
            }
            files.sort { ($0["relative"] ?? "").localizedStandardCompare($1["relative"] ?? "") == .orderedAscending }
        } else {
            files = (defaults.stringArray(forKey: "recentFiles") ?? []).filter { FileManager.default.fileExists(atPath: $0) }.map { ["name": URL(fileURLWithPath: $0).lastPathComponent, "path": $0] }
        }
        allowedFilePaths = Set(files.compactMap { $0["path"] })
        call("files", [files, folderURL?.lastPathComponent ?? "最近打开"])
    }

    @objc func saveDocument() { _ = save() }
    @objc func saveAs() { _ = save(forcePanel: true) }

    func confirmLargeDocument() -> Bool {
        let alert = NSAlert()
        alert.messageText = "文档已达到 20 MiB"
        alert.informativeText = "较大的文档（尤其是内嵌图片）可能使排版和编辑变慢。可以继续打开或保存；应用不会截断内容。"
        alert.addButton(withTitle: "取消")
        alert.addButton(withTitle: "继续")
        return present(alert) == .alertSecondButtonReturn
    }

    @discardableResult func save(forcePanel: Bool = false) -> Bool {
        guard canUseDocument else { return false }
        var destination = fileURL
        if forcePanel || destination == nil {
            let panel = NSSavePanel(); panel.title = "保存 Markdown"
            panel.nameFieldStringValue = documentName == "开始书写.md" ? "未命名.md" : documentName
            panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
            panel.canCreateDirectories = true
            panel.directoryURL = fileURL?.deletingLastPathComponent()
            guard panel.runModal() == .OK else { return false }
            destination = panel.url
        }
        guard let url = destination else { return false }
        if DocumentCapacity.needsSaveWarning(content: content, savedContent: savedContent, newDestination: url != fileURL), !confirmLargeDocument() { return false }
        if url == fileURL {
            let baseline = DiskBaseline.inspect(url, savedContent: savedContent)
            if baseline != .unchanged {
                let alert = NSAlert()
                switch baseline {
                case .modified:
                    alert.messageText = "文件已被其他应用修改"
                    alert.informativeText = "“\(url.lastPathComponent)”在磁盘上的内容已经变化。覆盖会替换外部修改，也可以取消后另存为。"
                case .missing:
                    alert.messageText = "原文件已不存在"
                    alert.informativeText = "无法确认“\(url.lastPathComponent)”的原保存内容。继续会在原位置重新创建文件，也可以取消后另存为。"
                case .unreadable(let reason):
                    alert.messageText = "无法检查原文件内容"
                    alert.informativeText = "不能确认“\(url.lastPathComponent)”是否已被外部修改。覆盖会替换磁盘文件，也可以取消后另存为。\n\n\(reason)"
                case .unchanged: break
                }
                alert.addButton(withTitle: "取消"); alert.addButton(withTitle: "覆盖保存")
                guard present(alert) == .alertSecondButtonReturn else { return false }
            }
        }
        do {
            try content.write(to: url, atomically: true, encoding: .utf8)
            savedContent = content; fileURL = url; documentName = url.lastPathComponent
            resources.documentDirectory = url.deletingLastPathComponent()
            persistDraft(); state("文件已保存")
            if !isSmokeTest {
                var recent = defaults.stringArray(forKey: "recentFiles") ?? []
                recent.removeAll { $0 == url.path }; recent.insert(url.path, at: 0)
                defaults.set(Array(recent.prefix(30)), forKey: "recentFiles")
            }
            refreshFiles()
            call("toast", ["已保存 · \(documentName)"])
            return true
        } catch { showError("保存失败", error.localizedDescription); return false }
    }

    @objc func exportHTML() {
        guard canUseDocument else { return }
        let panel = NSSavePanel(); panel.title = "导出 HTML"
        panel.nameFieldStringValue = (documentName as NSString).deletingPathExtension + ".html"
        panel.allowedContentTypes = [.html]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        call("exportHTML", completion: { [weak self] result, error in
            guard let self = self else { return }
            guard error == nil, let html = result as? String else { self.showError("导出失败", error?.localizedDescription ?? "无法生成 HTML"); return }
            do { try html.write(to: url, atomically: true, encoding: .utf8); self.call("toast", ["HTML 已导出"]) }
            catch { self.showError("导出失败", error.localizedDescription) }
        })
    }

    func printInfo() -> NSPrintInfo {
        let info = NSPrintInfo.shared.copy() as! NSPrintInfo
        info.paperSize = NSSize(width: 595.28, height: 841.89)
        info.topMargin = 44; info.bottomMargin = 44; info.leftMargin = 48; info.rightMargin = 48
        info.horizontalPagination = .fit; info.verticalPagination = .automatic
        info.isVerticallyCentered = false
        return info
    }

    @objc func exportPDF() {
        guard canUseDocument else { return }
        let panel = NSSavePanel(); panel.title = "导出 PDF"
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = (documentName as NSString).deletingPathExtension + ".pdf"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { @MainActor in
            do {
                call("toast", ["正在排版 PDF…"])
                guard let html = try await webView.evaluateJavaScript("window.moye.exportHTML()") as? String else { return }
                try await PDFExporter(resources: resources).render(html: html, to: url)
                call("toast", ["PDF 已导出"])
            } catch { showError("PDF 导出失败", error.localizedDescription) }
        }
    }

    @objc func printDocument() {
        guard canUseDocument else { return }
        Task { @MainActor in
            do {
                guard let html = try await webView.evaluateJavaScript("window.moye.exportHTML()") as? String else { return }
                let url = FileManager.default.temporaryDirectory.appendingPathComponent("moye-print-\(UUID().uuidString).pdf")
                try await PDFExporter(resources: resources).render(html: html, to: url)
                guard let pdf = PDFDocument(url: url), let operation = pdf.printOperation(for: printInfo(), scalingMode: .pageScaleToFit, autoRotate: true) else { return }
                operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
            } catch { showError("打印失败", error.localizedDescription) }
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else { decisionHandler(.cancel); return }
        if url.scheme == "moye" && url.host == "app" { decisionHandler(.allow); return }
        if navigationAction.navigationType == .linkActivated, ["https", "http", "mailto"].contains(url.scheme ?? "") { NSWorkspace.shared.open(url) }
        decisionHandler(.cancel)
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url, ["https", "http", "mailto"].contains(url.scheme ?? "") { NSWorkspace.shared.open(url) }
        return nil
    }

    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.beginSheetModal(for: window) { response in completionHandler(response == .OK ? panel.urls : nil) }
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        ready = false; session.editorTerminated(); persistDraft(); webView.reload()
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if isSmokeTest { print("Navigation finished: \(webView.url?.absoluteString ?? "nil")"); fflush(stdout) }
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if isSmokeTest { finishSmokeTest(["passed": false, "error": error.localizedDescription]) }
    }

    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        let url = URL(fileURLWithPath: filename)
        if canUseDocument { if confirmUnsaved() { open(url) } } else { pendingOpen = url }
        return true
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { window.makeKeyAndOrderFront(nil); return true }
    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // 启动恢复尚未开始时可以退出，但 persistDraft 不得覆盖已有草稿。
        guard session.initialized else { return .terminateNow }
        guard confirmUnsaved() else { return .terminateCancel }
        persistDraft(); return .terminateNow
    }
    func applicationWillTerminate(_ notification: Notification) { recoveryWork?.cancel(); persistDraft() }
    func windowShouldClose(_ sender: NSWindow) -> Bool { let close = confirmUnsaved(); if close { persistDraft() }; return close }

    @discardableResult func present(_ alert: NSAlert) -> NSApplication.ModalResponse {
        if isSmokeTest {
            guard !smokeResponses.isEmpty else {
                finishSmokeTest(["passed": false, "error": "Unexpected alert: \(alert.messageText)"])
                return .abort
            }
            return smokeResponses.removeFirst()
        }
        return alert.runModal()
    }

    func showError(_ title: String, _ message: String) {
        let alert = NSAlert(); alert.alertStyle = .warning; alert.messageText = title; alert.informativeText = message; present(alert)
    }
    @objc func about() {
        NSApp.orderFrontStandardAboutPanel(options: [.applicationName: "墨页 MoYe", .applicationVersion: "0.1.0", .version: "1", .credits: NSAttributedString(string: "让想法，自然成文。\n原生 macOS Markdown 编辑器\n编辑引擎：Milkdown / ProseMirror / CodeMirror")])
    }
    @objc func closeWindow() { window.performClose(nil) }
    @objc func sourceMode() { command("source") }
    @objc func sidebar() { command("sidebar") }
    @objc func focusMode() { command("focus") }
    @objc func typewriter() { command("typewriter") }
    @objc func theme() { command("theme") }
    @objc func find() { command("find") }
    @objc func findNextItem() { command("findNext") }
    @objc func zoomIn() { command("zoomIn") }
    @objc func zoomOut() { command("zoomOut") }
    @objc func zoomReset() { command("zoomReset") }
    @objc func bold() { command("bold") }
    @objc func italic() { command("italic") }
    @objc func link() { command("link") }
    @objc func help() { command("help") }

    // 在真实 WKWebView 中验证编辑、桥接、文件保存、打印和离线资源。
    func runSmokeTest() {
        Task { @MainActor in
            do {
                let fixture = "# 集成测试\n\n中文 **粗体** 与 *斜体*。\n\n## 第二节\n\n- [x] 完成任务\n\n```swift\nlet value = 42\n```\n\n| 列一 | 列二 |\n| --- | --- |\n| A | B |\n"
                let testDirectory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["MOYE_SMOKE_RESULT"] ?? "/tmp/moye-smoke-result.json").deletingLastPathComponent()
                var checks = smokeStartupChecks
                load(fixture, url: nil, name: "集成测试.md")
                try await Task.sleep(nanoseconds: 500_000_000)
                let initialJSON = try await webView.evaluateJavaScript("JSON.stringify(window.moye.debugState())") as? String ?? "{}"
                let initial = try JSONSerialization.jsonObject(with: Data(initialJSON.utf8)) as? [String: Any] ?? [:]
                checks["editorReady"] = initial["editor"] as? Bool == true
                checks["outline"] = initial["headings"] as? Int == 2
                checks["loadPreservesMarkdown"] = (initial["markdown"] as? String == fixture) && !dirty

                command("source")
                try await Task.sleep(nanoseconds: 150_000_000)
                checks["sourceMode"] = try await webView.evaluateJavaScript("window.moye.debugState().sourceMode") as? Bool == true
                _ = try await webView.evaluateJavaScript("document.querySelector('#source-editor .cm-content').focus(); document.execCommand('selectAll'); document.execCommand('insertText', false, '# 修改后的文档\\n\\n中文输入与即时保存。\\n')")
                try await Task.sleep(nanoseconds: 150_000_000)
                checks["sourceEditReachesNative"] = content.contains("修改后的文档") && dirty
                let sourceContent = content
                command("source")
                try await Task.sleep(nanoseconds: 250_000_000)
                checks["modeSwitchPreservesMarkdown"] = content == sourceContent
                _ = try await webView.evaluateJavaScript("document.querySelector('.ProseMirror').focus(); document.execCommand('selectAll'); document.execCommand('insertText', false, '即时编辑与保存验证')")
                try await Task.sleep(nanoseconds: 120_000_000)
                checks["richEditReachesNative"] = content.contains("即时编辑与保存验证")
                let testFile = testDirectory.appendingPathComponent("smoke-saved.md")
                try savedContent.write(to: testFile, atomically: true, encoding: .utf8)
                fileURL = testFile
                let saved = save()
                let savedText = try String(contentsOf: testFile, encoding: .utf8)
                checks["nativeSave"] = saved && savedText == content && !dirty
                checks.merge(try await runEditingRegressionChecks()) { _, latest in latest }
                checks.merge(try await runDocumentSafetyChecks(in: testDirectory)) { _, latest in latest }

                load(fixture, url: nil, name: "集成测试.md")
                try await Task.sleep(nanoseconds: 200_000_000)
                let html = try await webView.evaluateJavaScript("window.moye.exportHTML()") as? String ?? ""
                checks["htmlExport"] = html.contains("<table>") && html.contains("<strong>") && html.contains("data-language=\"swift\"")
                try html.write(to: testDirectory.appendingPathComponent("smoke-export.html"), atomically: true, encoding: .utf8)

                let pdfURL = testDirectory.appendingPathComponent("smoke-export.pdf")
                try await PDFExporter(resources: resources).render(html: html, to: pdfURL)
                let pdf = PDFDocument(url: pdfURL)
                checks["pdfExport"] = pdf?.pageCount == 1 && ((try? Data(contentsOf: pdfURL))?.count ?? 0) < 2_000_000
                let longHTML = html.replacingOccurrences(of: "</body>", with: (1...120).map { "<p>分页段落 \($0)：中文排版与多页导出验证，保留完整正文。</p>" }.joined() + "</body>")
                let longPDFURL = testDirectory.appendingPathComponent("smoke-multipage.pdf")
                try await PDFExporter(resources: resources).render(html: longHTML, to: longPDFURL)
                let longPDF = PDFDocument(url: longPDFURL)
                checks["multipagePDF"] = (longPDF?.pageCount ?? 0) > 2 && (longPDF?.pageCount ?? 0) < 12 && (longPDF?.string?.contains("120") == true)

                let welcomeText = try await webView.evaluateJavaScript("window.__moyeWelcome || ''") as? String ?? ""
                if !welcomeText.isEmpty { load(welcomeText, url: nil, name: "开始书写.md") }
                _ = try await webView.evaluateJavaScript("document.documentElement.dataset.theme = 'light'; document.querySelector('#editor-scroll').scrollTop = 0; document.activeElement.blur(); document.querySelector('#toast').style.display = 'none'; const style=document.createElement('style'); style.textContent='.ProseMirror{caret-color:transparent!important}.prosemirror-virtual-cursor{display:none!important}'; document.head.append(style); true")
                try await Task.sleep(nanoseconds: 200_000_000)
                let image = try await webView.takeSnapshot(configuration: nil)
                if let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff), let png = bitmap.representation(using: .png, properties: [:]) {
                    try png.write(to: testDirectory.appendingPathComponent("preview-light.png"))
                }
                _ = try await webView.evaluateJavaScript("document.documentElement.dataset.theme = 'dark'")
                try await Task.sleep(nanoseconds: 100_000_000)
                let darkImage = try await webView.takeSnapshot(configuration: nil)
                if let tiff = darkImage.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff), let png = bitmap.representation(using: .png, properties: [:]) {
                    try png.write(to: testDirectory.appendingPathComponent("preview-dark.png"))
                }
                finishSmokeTest(["passed": checks.values.allSatisfy { $0 }, "checks": checks])
            } catch { finishSmokeTest(["passed": false, "error": error.localizedDescription]) }
        }
    }

    @MainActor func runEditingRegressionChecks() async throws -> [String: Bool] {
        var checks: [String: Bool] = [:]
        func editorState() async throws -> [String: Any] {
            let json = try await webView.evaluateJavaScript("JSON.stringify(window.moye.debugState())") as? String ?? "{}"
            return try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] ?? [:]
        }
        let imageFixture = "# 图片语义\n\n![示意图](missing.png \"说明\")\n\n![42](numeric.png)\n\n![](empty.png)\n\n保留正文。\n"
        load(imageFixture, url: nil, name: "图片回归.md")
        _ = try await webView.evaluateJavaScript("window.moye.files([{name:'测试.md',path:'/tmp/moye-test.md'}]); window.__moyeFileNode=document.querySelector('.file-item'); const heading=document.querySelector('.ProseMirror h1'); const range=document.createRange(); range.selectNodeContents(heading); range.collapse(false); const selection=window.getSelection(); selection.removeAllRanges(); selection.addRange(range); heading.closest('.ProseMirror').focus(); document.execCommand('insertText',false,'修改');")
        let edited = try await editorState()
        let editedMarkdown = edited["markdown"] as? String ?? ""
        checks["imageAltPreserved"] = editedMarkdown.contains("![示意图](missing.png \"说明\")") && editedMarkdown.contains("![42](numeric.png)") && editedMarkdown.contains("![](empty.png)") && editedMarkdown.contains("图片语义修改")
        checks["fileListStableDuringEdit"] = try await webView.evaluateJavaScript("window.__moyeFileNode===document.querySelector('.file-item')") as? Bool == true
        let richDepth = edited["richUndoDepth"] as? Int ?? 0
        _ = try await webView.evaluateJavaScript("window.moye.command('source'); window.moye.command('source'); true")
        let roundtrip = try await editorState()
        checks["richHistorySurvivesViewingSource"] = richDepth > 0 && roundtrip["richUndoDepth"] as? Int == richDepth && roundtrip["markdown"] as? String == editedMarkdown

        _ = try await webView.evaluateJavaScript("window.moye.command('source'); true")
        try await Task.sleep(nanoseconds: 100_000_000)
        let sourceBeforeEdit = try await editorState()
        checks["sourceSyncHasNoUndoEntry"] = sourceBeforeEdit["sourceUndoDepth"] as? Int == 0
        _ = try await webView.evaluateJavaScript("document.querySelector('#source-editor .cm-content').focus(); document.execCommand('selectAll'); document.execCommand('insertText',false,'# 源码导出回归\\n\\n源码编辑后导出不应改写正文历史。\\n')")
        let beforeExport = try await editorState()
        let exported = try await webView.evaluateJavaScript("window.moye.exportHTML()") as? String ?? ""
        let afterExport = try await editorState()
        checks["sourceExportDoesNotMutateRichState"] = exported.contains("源码导出回归") && beforeExport["richMarkdown"] as? String == afterExport["richMarkdown"] as? String && beforeExport["richUndoDepth"] as? Int == afterExport["richUndoDepth"] as? Int
        _ = try await webView.evaluateJavaScript("window.moye.command('source'); window.moye.command('source'); true")
        let sourceRoundtrip = try await editorState()
        checks["sourceHistorySurvivesViewingRich"] = (beforeExport["sourceUndoDepth"] as? Int ?? 0) > 0 && sourceRoundtrip["sourceUndoDepth"] as? Int == beforeExport["sourceUndoDepth"] as? Int
        checks["changedSourceResetsRichHistory"] = sourceRoundtrip["richUndoDepth"] as? Int == 0
        _ = try await webView.evaluateJavaScript("window.moye.command('source'); true")
        return checks
    }

    @MainActor func runDocumentSafetyChecks(in directory: URL) async throws -> [String: Bool] {
        var checks: [String: Bool] = [:]
        func editorState() async throws -> [String: Any] {
            let json = try await webView.evaluateJavaScript("JSON.stringify(window.moye.debugState())") as? String ?? "{}"
            return try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] ?? [:]
        }
        let baseline = "# 已保存的基线\n\n关闭、重新打开与失败回退验证。\n"
        let url = directory.appendingPathComponent("safety-saved.md")
        try baseline.write(to: url, atomically: true, encoding: .utf8)
        load(baseline, url: url, name: url.lastPathComponent)
        _ = try await editorState()
        _ = try await webView.evaluateJavaScript("if (!window.moye.debugState().sourceMode) window.moye.command('source'); true")
        try await Task.sleep(nanoseconds: 100_000_000)
        _ = try await webView.evaluateJavaScript("document.querySelector('#source-editor .cm-content').focus(); document.execCommand('selectAll'); document.execCommand('insertText',false,'未保存并准备放弃的修改'); true")
        try await Task.sleep(nanoseconds: 100_000_000)
        checks["discardFixtureIsDirty"] = dirty
        let discardedGeneration = session.generation
        smokeResponses = [.alertThirdButtonReturn]
        let closed = windowShouldClose(window)
        _ = applicationShouldHandleReopen(NSApp, hasVisibleWindows: false)
        let restored = try await editorState()
        checks["discardSynchronizesEditors"] = closed && !dirty && content == baseline && restored["markdown"] as? String == baseline && restored["richMarkdown"] as? String == baseline
        checks["discardResetsBothHistories"] = restored["sourceUndoDepth"] as? Int == 0 && restored["richUndoDepth"] as? Int == 0
        checks["discardRejectsOldChanges"] = !session.acceptsChange(discardedGeneration)
        _ = try await webView.evaluateJavaScript("window.moye.command('source'); document.querySelector('.ProseMirror').focus(); document.execCommand('undo'); true")
        let afterUndo = try await editorState()
        checks["discardCannotBeUndone"] = afterUndo["markdown"] as? String == baseline

        // 实际执行“放弃后打开失败”，错误面板使用脚本选择，原生及编辑器应保持基线。
        content = baseline + "\n临时编辑"
        smokeResponses = [.alertThirdButtonReturn, .alertFirstButtonReturn]
        if confirmUnsaved() { open(directory.appendingPathComponent("missing-\(UUID().uuidString).md")) }
        let afterFailure = try await editorState()
        checks["failedOpenAfterDiscardStaysConsistent"] = content == baseline && !dirty && fileURL == url && afterFailure["markdown"] as? String == baseline

        content = baseline + "\n准备保存的修改"
        try "外部修改".write(to: url, atomically: true, encoding: .utf8)
        smokeResponses = [.alertFirstButtonReturn]
        let canceledModified = !save()
        let external = try String(contentsOf: url, encoding: .utf8)
        checks["modifiedFileCancelPreservesDisk"] = canceledModified && external == "外部修改" && dirty

        let invalid = Data([0xff, 0xfe, 0x80])
        try invalid.write(to: url)
        smokeResponses = [.alertFirstButtonReturn]
        let canceledUnreadable = !save()
        let protectedBytes = try Data(contentsOf: url)
        checks["unreadableFileCancelPreservesBytes"] = canceledUnreadable && protectedBytes == invalid && dirty
        smokeResponses = [.alertSecondButtonReturn]
        let overwritten = save()
        let overwrittenText = try String(contentsOf: url, encoding: .utf8)
        checks["unreadableFileExplicitOverwrite"] = overwritten && overwrittenText == content && !dirty

        try FileManager.default.removeItem(at: url)
        content += "\n文件已删除"
        smokeResponses = [.alertFirstButtonReturn]
        checks["missingFileCancelDoesNotRecreate"] = !save() && !FileManager.default.fileExists(atPath: url.path) && dirty
        smokeResponses = [.alertSecondButtonReturn]
        let recreated = save()
        let recreatedText = try String(contentsOf: url, encoding: .utf8)
        checks["missingFileExplicitRecreate"] = recreated && recreatedText == content && !dirty
        checks["safetyAlertsConsumed"] = smokeResponses.isEmpty
        return checks
    }

    func finishSmokeTest(_ result: [String: Any]) {
        if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]) {
            let path = ProcessInfo.processInfo.environment["MOYE_SMOKE_RESULT"] ?? "/tmp/moye-smoke-result.json"
            try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
            print(String(data: data, encoding: .utf8) ?? "")
        }
        exit(result["passed"] as? Bool == true ? 0 : 1)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
