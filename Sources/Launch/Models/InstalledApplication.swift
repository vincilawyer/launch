import Foundation

/// The small, persistence-safe description of an application installed on the Mac.
///
/// `id` is stable across application updates. It is normally the bundle identifier,
/// falling back to the canonical bundle path for applications without one.
public struct InstalledApplication: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public var name: String
    public var bundleIdentifier: String?
    public var bundleURL: URL
    public var iconURL: URL?

    public init(
        id: String? = nil,
        name: String,
        bundleIdentifier: String? = nil,
        bundleURL: URL,
        iconURL: URL? = nil
    ) {
        let normalizedBundleIdentifier = bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines)

        self.id = id ?? Self.stableIdentifier(
            bundleIdentifier: normalizedBundleIdentifier,
            bundleURL: bundleURL
        )
        self.name = name
        self.bundleIdentifier = normalizedBundleIdentifier?.isEmpty == false ? normalizedBundleIdentifier : nil
        self.bundleURL = bundleURL
        self.iconURL = iconURL
    }

    public static func stableIdentifier(bundleIdentifier: String?, bundleURL: URL) -> String {
        if let bundleIdentifier,
           !bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return bundleIdentifier
        }

        return bundleURL
            .resolvingSymlinksInPath()
            .standardizedFileURL
            .path
    }
}

/// One row in the unified application-management list. Visibility is derived
/// from `LaunchPreferences.hiddenApplicationIDs`; it is intentionally not
/// persisted separately, so the list and launcher layout cannot drift apart.
public struct ManagedApplication: Hashable, Identifiable, Sendable {
    public let application: InstalledApplication
    public let isVisible: Bool

    public var id: String { application.id }

    public init(application: InstalledApplication, isVisible: Bool) {
        self.application = application
        self.isVisible = isVisible
    }
}
