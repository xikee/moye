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
print("原生恢复测试：\(count) 项通过")
