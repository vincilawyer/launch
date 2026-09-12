import Foundation

/// A Launchpad-style folder. Folders intentionally contain applications only;
/// nested folders are not supported by macOS Launchpad either.
public struct LaunchFolder: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var applicationIDs: [String]

    public init(
        id: UUID = UUID(),
        name: String,
        applicationIDs: [String] = []
    ) {
        self.id = id
        self.name = name
        self.applicationIDs = applicationIDs
    }
}
