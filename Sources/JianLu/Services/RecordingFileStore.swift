import Foundation

enum RecordingFileStore {
    static var recordingsDirectory: URL {
        let base = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return base.appendingPathComponent("简录", isDirectory: true)
    }

    static func makeRecordingURL(prefix: String, extension fileExtension: String = "mov") throws -> URL {
        try FileManager.default.createDirectory(at: recordingsDirectory, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let timestamp = formatter.string(from: Date())
        return recordingsDirectory.appendingPathComponent("\(prefix)-\(timestamp).\(fileExtension)")
    }
}
