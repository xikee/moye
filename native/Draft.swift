import Foundation

struct Draft: Codable {
    var content: String
    var savedContent: String
    var path: String?
    var name: String

    var isDirty: Bool { content != savedContent }

    // 未修改快照以当前磁盘内容为准；未保存的编辑始终保留原基线，供保存冲突检查。
    func resolvingDiskContent(_ diskContent: String?) -> Draft {
        guard !isDirty, path != nil else { return self }
        guard let diskContent = diskContent else {
            // 原文件已删除或不可读时，保留快照为未保存文档，避免误报为已保存。
            return Draft(content: content, savedContent: "", path: nil, name: name)
        }
        return Draft(content: diskContent, savedContent: diskContent, path: path, name: name)
    }
}
