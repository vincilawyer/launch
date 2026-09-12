import Foundation

/// The complete persistence unit for Launch. Layout and preferences are kept in
/// one file because hidden application IDs directly affect folder membership.
public struct LaunchSnapshot: Codable, Hashable, Sendable {
    public static let currentFormatVersion = 1

    public var formatVersion: Int
    public var layout: LaunchLayout
    public var preferences: LaunchPreferences

    public init(
        formatVersion: Int = LaunchSnapshot.currentFormatVersion,
        layout: LaunchLayout = .empty,
        preferences: LaunchPreferences = .default
    ) {
        self.formatVersion = formatVersion
        self.layout = layout
        self.preferences = preferences
    }
}

public enum LayoutStoreError: LocalizedError, Sendable {
    case incompleteApplicationScan([AppScanIssue])
    case unsupportedSnapshotVersion(Int)

    public var errorDescription: String? {
        switch self {
        case let .incompleteApplicationScan(issues):
            let detail = issues.first?.message ?? "Unknown filesystem error"
            return "The application scan was incomplete and the saved layout was left unchanged: \(detail)"
        case let .unsupportedSnapshotVersion(version):
            return "The saved Launch data uses unsupported format version \(version)."
        }
    }
}

/// Serializes access to one atomic snapshot containing both layout and preferences.
///
/// Older `layout.json` and `preferences.json` files are read independently and
/// migrated only after both decode successfully. They are retained as a recovery
/// copy; a malformed legacy file therefore never causes the valid sibling to be
/// overwritten.
public actor LayoutStore {
    public nonisolated let directoryURL: URL

    public nonisolated var snapshotFileURL: URL {
        directoryURL.appendingPathComponent("snapshot.json", isDirectory: false)
    }

    /// Legacy pre-snapshot location, retained for migration and recovery.
    public nonisolated var layoutFileURL: URL {
        directoryURL.appendingPathComponent("layout.json", isDirectory: false)
    }

    /// Legacy pre-snapshot location, retained for migration and recovery.
    public nonisolated var preferencesFileURL: URL {
        directoryURL.appendingPathComponent("preferences.json", isDirectory: false)
    }

    /// - Parameter directoryURL: The exact directory in which persisted data is
    ///   stored. Supplying one keeps tests and portable builds isolated.
    public init(directoryURL: URL? = nil) {
        if let directoryURL {
            self.directoryURL = directoryURL.standardizedFileURL
        } else if let isolatedDirectory = ProcessInfo.processInfo.environment["LAUNCH_DATA_DIRECTORY"],
                  !isolatedDirectory.isEmpty {
            // A separate data root lets development and UI acceptance builds
            // exercise every layout mutation without touching the user's real
            // Launch snapshot. Normal app launches never set this variable.
            self.directoryURL = URL(
                fileURLWithPath: isolatedDirectory,
                isDirectory: true
            ).standardizedFileURL
        } else {
            let fileManager = FileManager.default
            let applicationSupport = fileManager.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first ?? fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)

            self.directoryURL = applicationSupport
                .appendingPathComponent("Launch", isDirectory: true)
        }
    }

    public func loadLayout() throws -> LaunchLayout {
        try loadSnapshotMigratingLegacy().layout
    }

    public func saveLayout(_ layout: LaunchLayout) throws {
        var snapshot = try loadSnapshotMigratingLegacy()
        snapshot.layout = layout
        snapshot.formatVersion = LaunchSnapshot.currentFormatVersion
        try saveSnapshot(snapshot)
    }

    public func loadPreferences() throws -> LaunchPreferences {
        try loadSnapshotMigratingLegacy().preferences
    }

    public func savePreferences(_ preferences: LaunchPreferences) throws {
        var snapshot = try loadSnapshotMigratingLegacy()
        snapshot.preferences = preferences
        snapshot.formatVersion = LaunchSnapshot.currentFormatVersion
        try saveSnapshot(snapshot)
    }

    public func load() throws -> (
        layout: LaunchLayout,
        preferences: LaunchPreferences
    ) {
        let snapshot = try loadSnapshotMigratingLegacy()
        return (snapshot.layout, snapshot.preferences)
    }

    public func save(
        layout: LaunchLayout,
        preferences: LaunchPreferences
    ) throws {
        try saveSnapshot(
            LaunchSnapshot(layout: layout, preferences: preferences)
        )
    }

    /// Loads, reconciles, and persists a ready-to-present configuration.
    /// Incomplete scans are rejected before any persisted data is read or written.
    public func loadAndReconcile(
        scanResult: AppScanResult
    ) throws -> (
        layout: LaunchLayout,
        preferences: LaunchPreferences
    ) {
        try requireComplete(scanResult)

        var snapshot = try loadSnapshotMigratingLegacy()
        let reconciled = snapshot.layout.reconciled(
            with: scanResult.applications,
            preferences: snapshot.preferences
        )

        if reconciled != snapshot.layout {
            snapshot.layout = reconciled
            snapshot.formatVersion = LaunchSnapshot.currentFormatVersion
            try saveSnapshot(snapshot)
        }

        return (snapshot.layout, snapshot.preferences)
    }

    /// Reconciles an in-memory layout after a rescan and atomically stores the
    /// resulting layout together with the preferences that governed it.
    public func reconcileAndSave(
        layout: LaunchLayout,
        scanResult: AppScanResult,
        preferences: LaunchPreferences
    ) throws -> LaunchLayout {
        try requireComplete(scanResult)

        let reconciled = layout.reconciled(
            with: scanResult.applications,
            preferences: preferences
        )
        if reconciled != layout {
            try save(layout: reconciled, preferences: preferences)
        }
        return reconciled
    }

    private func requireComplete(_ scanResult: AppScanResult) throws {
        guard scanResult.isComplete else {
            throw LayoutStoreError.incompleteApplicationScan(scanResult.issues)
        }
    }

    private func loadSnapshotMigratingLegacy() throws -> LaunchSnapshot {
        let fileManager = FileManager.default

        if fileManager.fileExists(atPath: snapshotFileURL.path) {
            let snapshot = try decode(LaunchSnapshot.self, from: snapshotFileURL)
            guard snapshot.formatVersion == LaunchSnapshot.currentFormatVersion else {
                throw LayoutStoreError.unsupportedSnapshotVersion(snapshot.formatVersion)
            }
            return snapshot
        }

        // Decode both legacy components before writing anything. If either file
        // is malformed, the other remains authoritative and untouched on disk.
        let legacyLayout = try decodeIfPresent(LaunchLayout.self, from: layoutFileURL) ?? .empty
        let legacyPreferences = try decodeIfPresent(
            LaunchPreferences.self,
            from: preferencesFileURL
        ) ?? .default
        let snapshot = LaunchSnapshot(
            layout: legacyLayout,
            preferences: legacyPreferences
        )
        try saveSnapshot(snapshot)
        return snapshot
    }

    private func saveSnapshot(_ snapshot: LaunchSnapshot) throws {
        try encodeAndAtomicallyWrite(snapshot, to: snapshotFileURL)
    }

    private func decode<Value: Decodable>(
        _ type: Value.Type,
        from url: URL
    ) throws -> Value {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(type, from: data)
    }

    private func decodeIfPresent<Value: Decodable>(
        _ type: Value.Type,
        from url: URL
    ) throws -> Value? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try decode(type, from: url)
    }

    private func encodeAndAtomicallyWrite<Value: Encodable>(
        _ value: Value,
        to destinationURL: URL
    ) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: nil
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(value)
        let temporaryURL = directoryURL.appendingPathComponent(
            ".\(destinationURL.lastPathComponent).\(UUID().uuidString).tmp",
            isDirectory: false
        )

        do {
            try data.write(to: temporaryURL)

            if fileManager.fileExists(atPath: destinationURL.path) {
                _ = try fileManager.replaceItemAt(
                    destinationURL,
                    withItemAt: temporaryURL,
                    backupItemName: nil,
                    options: [.usingNewMetadataOnly]
                )
            } else {
                try fileManager.moveItem(at: temporaryURL, to: destinationURL)
            }
        } catch {
            try? fileManager.removeItem(at: temporaryURL)
            throw error
        }
    }
}
