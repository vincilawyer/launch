import Foundation

/// Tiny dependency-free localization helper for the two bundled UI languages.
enum LaunchText {
    static let usesChinese: Bool = {
        Locale.preferredLanguages.first?.lowercased().hasPrefix("zh") == true
    }()

    static func value(_ chinese: String, _ english: String) -> String {
        usesChinese ? chinese : english
    }
}
