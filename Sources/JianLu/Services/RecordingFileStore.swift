import Foundation

enum RecordingFileStore {
    static var defaultRecordingsDirectory: URL {
        let base = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return base.appendingPathComponent("简录", isDirectory: true)
    }

    static func recordingsDirectory(path: String?) -> URL {
        guard let path, !path.isEmpty else {
            return defaultRecordingsDirectory
        }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    static func makeRecordingURL(prefix: String, extension fileExtension: String = "mov", directoryPath: String? = nil) throws -> URL {
        let directory = recordingsDirectory(path: directoryPath)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let timestamp = formatter.string(from: Date())
        return directory.appendingPathComponent("\(prefix)-\(timestamp).\(fileExtension)")
    }
}
