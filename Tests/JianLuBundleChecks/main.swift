import Foundation

func fail(_ message: String) -> Never {
    fputs("Bundle check failed: \(message)\n", stderr)
    exit(1)
}

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        fail(message)
    }
}

let arguments = CommandLine.arguments
guard arguments.count >= 2 else {
    fail("usage: JianLuBundleChecks /path/to/app.bundle")
}

let appURL = URL(fileURLWithPath: arguments[1], isDirectory: true)
let fileManager = FileManager.default
let infoPlistURL = appURL.appendingPathComponent("Contents/Info.plist")
let executableURL = appURL.appendingPathComponent("Contents/MacOS/JianLu")

var isDirectory: ObjCBool = false
expect(fileManager.fileExists(atPath: appURL.path, isDirectory: &isDirectory) && isDirectory.boolValue, "app bundle exists")
expect(fileManager.fileExists(atPath: infoPlistURL.path), "Info.plist exists")
expect(fileManager.isExecutableFile(atPath: executableURL.path), "JianLu executable is present and executable")

guard let infoPlist = NSDictionary(contentsOf: infoPlistURL) as? [String: Any] else {
    fail("Info.plist can be read")
}

func stringValue(_ key: String) -> String {
    guard let value = infoPlist[key] as? String, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        fail("\(key) is present and non-empty")
    }
    return value
}

expect(stringValue("CFBundleExecutable") == "JianLu", "CFBundleExecutable is JianLu")
expect(stringValue("CFBundleIdentifier") == "com.local.JianLu", "CFBundleIdentifier is stable")
expect(stringValue("CFBundlePackageType") == "APPL", "bundle package type is APPL")
expect(stringValue("NSPrincipalClass") == "NSApplication", "NSPrincipalClass is NSApplication")

let minimumSystemVersion = stringValue("LSMinimumSystemVersion")
let minimumMajorVersion = Int(minimumSystemVersion.split(separator: ".").first ?? "") ?? 0
expect(minimumMajorVersion >= 15, "minimum macOS version is at least 15")

let usageDescriptionKeys = [
    "NSScreenCaptureUsageDescription",
    "NSCameraUsageDescription",
    "NSMicrophoneUsageDescription",
    "NSAudioCaptureUsageDescription"
]
for key in usageDescriptionKeys {
    expect(stringValue(key).contains("简录"), "\(key) explains why JianLu needs the permission")
}

let projectRoot = appURL
    .deletingLastPathComponent()
    .deletingLastPathComponent()
let environmentURL = projectRoot.appendingPathComponent(".codex/environments/environment.toml")
expect(fileManager.fileExists(atPath: environmentURL.path), "Codex environment config exists")

let environment = (try? String(contentsOf: environmentURL, encoding: .utf8)) ?? ""
expect(environment.contains("name = \"Run\""), "Codex Run action exists")
expect(environment.contains("command = \"./script/build_and_run.sh\""), "Codex Run action points at build_and_run.sh")

let controlBarSourceURL = projectRoot.appendingPathComponent("Sources/JianLu/Services/RecordingControlBarWindowController.swift")
let controlBarSource = (try? String(contentsOf: controlBarSourceURL, encoding: .utf8)) ?? ""
expect(controlBarSource.contains(".nonactivatingPanel"), "recording control bar does not activate JianLu while recording")
expect(controlBarSource.contains("panel.orderFrontRegardless()"), "recording control bar is shown without becoming key")

print("JianLuBundleChecks passed")
