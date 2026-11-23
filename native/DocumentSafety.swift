import Foundation

// 文档完成恢复前不能写入草稿；每次载入使用独立代次，隔离旧编辑器消息。
struct DocumentSession {
    private(set) var generation = 0
    private(set) var initialized = false
    private(set) var synchronized = false

    mutating func beginLoad() -> Int {
        generation += 1
        initialized = true
        synchronized = false
        return generation
    }

    mutating func finishLoad(_ generation: Int) {
        guard generation == self.generation else { return }
        synchronized = true
    }

    mutating func editorTerminated() { synchronized = false }

    func acceptsChange(_ generation: Int) -> Bool {
        initialized && generation == self.generation
    }
}

enum DiskBaseline: Equatable {
    case unchanged
    case modified
    case missing
    case unreadable(String)

    static func inspect(_ url: URL, savedContent: String) -> DiskBaseline {
        do {
            return try String(contentsOf: url, encoding: .utf8) == savedContent ? .unchanged : .modified
        } catch {
            let failure = error as NSError
            if failure.domain == NSCocoaErrorDomain && failure.code == NSFileReadNoSuchFileError {
                return .missing
            }
            return .unreadable(error.localizedDescription)
        }
    }
}

enum DocumentCapacity {
    // 提醒阈值而非读写上限，确保应用保存的文档仍然可以重新打开。
    static let warningBytes = 20 * 1024 * 1024

    static func needsWarning(byteCount: Int) -> Bool { byteCount >= warningBytes }

    static func needsSaveWarning(content: String, savedContent: String, newDestination: Bool) -> Bool {
        needsWarning(byteCount: content.utf8.count) &&
            (newDestination || !needsWarning(byteCount: savedContent.utf8.count))
    }
}
