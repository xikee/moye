import Foundation

var count = 0
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError(message) }
    count += 1
    print("✓ \(message)")
}

let clean = Draft(content: "旧内容", savedContent: "旧内容", path: "/tmp/document.md", name: "document.md")
let refreshed = clean.resolvingDiskContent("外部新内容")
check(refreshed.content == "外部新内容" && refreshed.savedContent == "外部新内容" && !refreshed.isDirty, "干净草稿恢复时读取最新磁盘内容")
check(refreshed.path == clean.path, "刷新磁盘内容后保留原文件位置")

let dirty = Draft(content: "未保存的编辑", savedContent: "旧内容", path: clean.path, name: clean.name)
let conflict = dirty.resolvingDiskContent("外部新内容")
check(conflict.content == dirty.content && conflict.savedContent == "旧内容" && conflict.isDirty, "磁盘变化时保留未保存编辑和冲突基线")
check(conflict.path == dirty.path, "未保存草稿保留冲突检测的原路径")
let deletedDirty = dirty.resolvingDiskContent(nil)
check(deletedDirty.content == dirty.content && deletedDirty.isDirty, "原文件丢失不覆盖未保存的编辑")

let missing = clean.resolvingDiskContent(nil)
check(missing.path == nil && missing.content == clean.content && missing.isDirty, "原文件丢失时将快照恢复为未保存文档")
let untitled = Draft(content: "未命名草稿", savedContent: "", path: nil, name: "未命名.md")
check(untitled.resolvingDiskContent("其他内容").content == untitled.content, "无路径草稿不采用磁盘内容")

let encoded = try JSONEncoder().encode(dirty)
let decoded = try JSONDecoder().decode(Draft.self, from: encoded)
check(decoded.content == dirty.content && decoded.savedContent == dirty.savedContent && decoded.path == dirty.path, "草稿格式保持向后兼容")

var session = DocumentSession()
check(!session.initialized && !session.synchronized, "恢复前不能写入草稿或执行文档命令")
check(!session.acceptsChange(0), "恢复前忽略编辑器初始内容")
let firstGeneration = session.beginLoad()
check(session.initialized && !session.synchronized, "恢复内容已可暂存但需等待编辑器载入")
session.finishLoad(firstGeneration)
check(session.synchronized && session.acceptsChange(firstGeneration), "载入完成后接受当前文档编辑")
let nextGeneration = session.beginLoad()
session.finishLoad(firstGeneration)
check(!session.synchronized && !session.acceptsChange(firstGeneration), "放弃或切换后拒绝旧编辑消息和旧载入确认")
session.finishLoad(nextGeneration)
session.editorTerminated()
check(session.initialized && !session.synchronized, "编辑器进程退出后仍保留可暂存的原生快照")

let directory = FileManager.default.temporaryDirectory.appendingPathComponent("moye-safety-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: directory) }
let file = directory.appendingPathComponent("document.md")
try "保存基线".write(to: file, atomically: true, encoding: .utf8)
check(DiskBaseline.inspect(file, savedContent: "保存基线") == .unchanged, "未变化的 UTF-8 文件允许直接保存")
check(DiskBaseline.inspect(file, savedContent: "旧内容") == .modified, "检测外部 UTF-8 修改")
try Data([0xff, 0xfe, 0x80]).write(to: file)
if case .unreadable = DiskBaseline.inspect(file, savedContent: "保存基线") {
    check(true, "非 UTF-8 外部文件要求明确覆盖确认")
} else { fatalError("非 UTF-8 文件不能跳过冲突检测") }
if case .unreadable = DiskBaseline.inspect(directory, savedContent: "") {
    check(true, "读取失败要求明确覆盖确认")
} else { fatalError("读取失败不能视为基线未变") }
check(DiskBaseline.inspect(directory.appendingPathComponent("missing.md"), savedContent: "") == .missing, "原文件缺失时要求确认重新创建")

check(!DocumentCapacity.needsWarning(byteCount: DocumentCapacity.warningBytes - 1), "小于 20 MiB 不提醒")
check(DocumentCapacity.needsWarning(byteCount: DocumentCapacity.warningBytes), "打开和保存共用包含边界的 20 MiB 提醒阈值")
let large = String(repeating: "中", count: DocumentCapacity.warningBytes / 3 + 1)
check(DocumentCapacity.needsSaveWarning(content: large, savedContent: "", newDestination: false), "容量按 UTF-8 字节计算，跨越阈值时提醒")
check(!DocumentCapacity.needsSaveWarning(content: large, savedContent: large, newDestination: false), "大文档重复保存不反复提醒")
check(DocumentCapacity.needsSaveWarning(content: large, savedContent: large, newDestination: true), "大文档另存到新位置时提醒")
try large.write(to: file, atomically: true, encoding: .utf8)
let reopened = try String(contentsOf: file, encoding: .utf8)
check(reopened == large && DiskBaseline.inspect(file, savedContent: large) == .unchanged, "超过旧打开上限的文档可完整保存并重新读取")
print("原生文档安全测试：\(count) 项通过")
