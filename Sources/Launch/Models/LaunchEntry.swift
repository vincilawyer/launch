import Foundation

/// One visible grid item on a launcher page.
public struct LaunchEntry: Codable, Hashable, Identifiable, Sendable {
    public enum Kind: Codable, Hashable, Sendable {
        case application(String)
        case folder(LaunchFolder)
    }

    public var id: UUID
    public var kind: Kind

    public init(id: UUID = UUID(), kind: Kind) {
        self.id = id
        self.kind = kind
    }

    public static func application(_ applicationID: String, id: UUID = UUID()) -> Self {
        Self(id: id, kind: .application(applicationID))
    }

    public static func folder(_ folder: LaunchFolder, id: UUID? = nil) -> Self {
        Self(id: id ?? folder.id, kind: .folder(folder))
    }

    public var applicationID: String? {
        guard case let .application(applicationID) = kind else { return nil }
        return applicationID
    }

    public var folder: LaunchFolder? {
        guard case let .folder(folder) = kind else { return nil }
        return folder
    }
}
