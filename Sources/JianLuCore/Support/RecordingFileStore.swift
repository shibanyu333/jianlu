import Foundation

public enum RecordingFileStore {
    public static var defaultRecordingsDirectory: URL {
        let base = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return base.appendingPathComponent("简录", isDirectory: true)
    }

    public static func recordingsDirectory(path: String?) -> URL {
        guard let path, !path.isEmpty else {
            return defaultRecordingsDirectory
        }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    public static func makeRecordingURL(
        prefix: String,
        extension fileExtension: String = "mov",
        directoryPath: String? = nil,
        date: Date = Date(),
        uniqueID: String = UUID().uuidString,
        fileManager: FileManager = .default
    ) throws -> URL {
        let directory = recordingsDirectory(path: directoryPath)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        let baseName = "\(prefix)-\(timestamp(from: date))-\(shortIdentifier(from: uniqueID))"
        var candidate = directory.appendingPathComponent("\(baseName).\(fileExtension)")
        var counter = 2
        while fileManager.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(baseName)-\(counter).\(fileExtension)")
            counter += 1
        }
        return candidate
    }

    private static func timestamp(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        return formatter.string(from: date)
    }

    private static func shortIdentifier(from uniqueID: String) -> String {
        let compact = uniqueID.filter { $0.isLetter || $0.isNumber }
        return String((compact.isEmpty ? UUID().uuidString.filter { $0.isLetter || $0.isNumber } : compact).prefix(8))
    }
}
