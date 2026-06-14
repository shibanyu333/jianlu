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
                .compactMap { sanitized($0, fileManager: fileManager) }
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

    private static func sanitized(_ project: RecordingProject, fileManager: FileManager) -> RecordingProject? {
        guard fileManager.fileExists(atPath: project.screenRecordingURL.path) else {
            return nil
        }

        var project = project
        if let cameraURL = project.cameraRecordingURL,
           !fileManager.fileExists(atPath: cameraURL.path) {
            project.cameraRecordingURL = nil
        }
        if let microphoneURL = project.microphoneRecordingURL,
           !fileManager.fileExists(atPath: microphoneURL.path) {
            project.microphoneRecordingURL = nil
        }
        return project
    }
}
