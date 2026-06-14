import Foundation

public enum RecordingProjectLibrary {
    public static let defaultLimit = 20

    public static func load(
        from url: URL,
        limit: Int = defaultLimit,
        fileManager: FileManager = .default
    ) throws -> [RecordingProject] {
        guard fileManager.fileExists(atPath: url.path) else {
            return []
        }

        let data = try Data(contentsOf: url)
        let projects = try JSONDecoder().decode([RecordingProject].self, from: data)
        return Array(
            projects
                .filter { fileManager.fileExists(atPath: $0.screenRecordingURL.path) }
                .prefix(max(0, limit))
        )
    }

    public static func save(
        _ projects: [RecordingProject],
        to url: URL,
        limit: Int = defaultLimit,
        fileManager: FileManager = .default
    ) throws {
        let limitedProjects = Array(projects.prefix(max(0, limit)))
        let directory = url.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(limitedProjects)
        try data.write(to: url, options: [.atomic])
    }
}
