import Foundation

/// UI language. `system` follows the Mac's preferred languages, so a Chinese system
/// gets 中文 and everything else gets English.
public enum AppLanguage: String, Codable, CaseIterable, Sendable {
    case system
    case chinese
    case english

    public var displayName: String {
        switch self {
        case .system:
            tr("跟随系统", "System")
        case .chinese:
            "简体中文"
        case .english:
            "English"
        }
    }

    /// The language actually used for rendering — `system` resolved against the Mac's
    /// preferred languages.
    public var resolved: AppLanguage {
        guard self == .system else { return self }
        let preferred = Locale.preferredLanguages.first ?? "en"
        return preferred.hasPrefix("zh") ? .chinese : .english
    }
}

/// Bilingual UI strings.
///
/// The app is small enough that inline pairs beat a key table: every call site reads
/// as its own translation, nothing can drift out of sync with a separate catalog, and
/// interpolation just works. `L10n.setLanguage` is called whenever the preference
/// changes, and SwiftUI re-renders because the preference itself is published.
public enum L10n {
    private static let storage = LanguageStorage()

    public static func setLanguage(_ language: AppLanguage) {
        storage.set(language.resolved)
    }

    public static var current: AppLanguage {
        storage.get()
    }

    public static var isChinese: Bool {
        current == .chinese
    }
}

/// Pick the string for the current UI language.
public func tr(_ chinese: String, _ english: String) -> String {
    L10n.isChinese ? chinese : english
}

private final class LanguageStorage: @unchecked Sendable {
    private let lock = NSLock()
    private var language: AppLanguage = AppLanguage.system.resolved

    func set(_ language: AppLanguage) {
        lock.lock()
        self.language = language
        lock.unlock()
    }

    func get() -> AppLanguage {
        lock.lock()
        defer { lock.unlock() }
        return language
    }
}
