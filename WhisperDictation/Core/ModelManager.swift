import Foundation

/// On-disk management of downloaded WhisperKit models (list / size / delete).
enum ModelManager {
    /// WhisperKit download root. Overrides the default `~/Documents/huggingface`
    /// (TCC-gated for non-sandboxed apps) with always-writable Application Support.
    static var downloadBase: URL {
        let url = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
            .appendingPathComponent("WhisperDictation", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Where WhisperKit lays down model folders.
    static var modelsDirectory: URL {
        downloadBase.appendingPathComponent("models/argmaxinc/whisperkit-coreml", isDirectory: true)
    }

    /// Names of fully/partially downloaded models (folder names).
    static func downloadedModels() -> [String] {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(atPath: modelsDirectory.path) else { return [] }
        return items
            .filter { !$0.hasPrefix(".") }
            .filter { name in
                var isDir: ObjCBool = false
                fm.fileExists(atPath: modelsDirectory.appendingPathComponent(name).path, isDirectory: &isDir)
                return isDir.boolValue
            }
            .sorted()
    }

    /// Total bytes on disk for a model.
    static func size(of name: String) -> Int64 {
        let dir = modelsDirectory.appendingPathComponent(name)
        guard let enumerator = FileManager.default.enumerator(
            at: dir, includingPropertiesForKeys: [.fileSizeKey]
        ) else { return 0 }

        var total: Int64 = 0
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.fileSizeKey])
            total += Int64(values?.fileSize ?? 0)
        }
        return total
    }

    static func delete(_ name: String) throws {
        try FileManager.default.removeItem(at: modelsDirectory.appendingPathComponent(name))
    }

    static func sizeString(of name: String) -> String {
        ByteCountFormatter.string(fromByteCount: size(of: name), countStyle: .file)
    }
}
