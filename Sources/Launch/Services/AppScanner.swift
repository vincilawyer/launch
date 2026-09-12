import Foundation

/// A filesystem problem encountered while scanning one configured search root.
public struct AppScanIssue: Hashable, Sendable {
    public let rootURL: URL
    public let affectedURL: URL
    public let message: String

    public init(rootURL: URL, affectedURL: URL, message: String) {
        self.rootURL = rootURL
        self.affectedURL = affectedURL
        self.message = message
    }
}

/// Applications found by a scan together with evidence that the inventory is
/// complete. A partial result is useful for display, but must never drive
/// destructive uninstall reconciliation.
public struct AppScanResult: Sendable {
    public let applications: [InstalledApplication]
    public let issues: [AppScanIssue]

    public init(applications: [InstalledApplication], issues: [AppScanIssue] = []) {
        self.applications = applications
        self.issues = issues
    }

    public var isComplete: Bool { issues.isEmpty }
}

/// Discovers application bundles in the standard macOS application locations.
public struct AppScanner: Sendable {
    private struct ApplicationCandidate {
        var application: InstalledApplication
        let alternateNames: [String]
    }

    public let searchRoots: [URL]
    private let optionalMissingRootPaths: Set<String>
    private let preferredLanguages: [String]

    public init() {
        let homeApplications = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications", isDirectory: true)
        let systemUtilities = URL(
            fileURLWithPath: "/System/Applications/Utilities",
            isDirectory: true
        )

        searchRoots = AppScanner.defaultSearchRoots
        preferredLanguages = Locale.preferredLanguages
        optionalMissingRootPaths = Set(
            [homeApplications, systemUtilities].map {
                $0.resolvingSymlinksInPath().standardizedFileURL.path
            }
        )
    }

    /// Explicitly supplied roots are expected to exist unless listed as optional.
    public init(
        searchRoots: [URL],
        optionalMissingSearchRoots: [URL] = [],
        preferredLanguages: [String] = Locale.preferredLanguages
    ) {
        self.searchRoots = searchRoots
        self.preferredLanguages = preferredLanguages
        optionalMissingRootPaths = Set(
            optionalMissingSearchRoots.map {
                $0.resolvingSymlinksInPath().standardizedFileURL.path
            }
        )
    }

    public static var defaultSearchRoots: [URL] {
        let fileManager = FileManager.default
        return [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications/Utilities", isDirectory: true),
            fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent("Applications", isDirectory: true)
        ]
    }

    /// Performs filesystem work away from the caller's executor.
    public func scanApplications() async -> AppScanResult {
        await Task.detached(priority: .utility) {
            scanApplicationsSynchronously()
        }.value
    }

    /// Synchronous form useful to command-line clients and deterministic tests.
    public func scanApplicationsSynchronously() -> AppScanResult {
        let fileManager = FileManager.default
        var discoveredCandidates: [(rootIndex: Int, url: URL)] = []
        var seenBundlePaths = Set<String>()
        var issues: [AppScanIssue] = []

        for (rootIndex, root) in searchRoots.enumerated() {
            let canonicalRoot = canonicalURL(root)

            if canonicalRoot.pathExtension.caseInsensitiveCompare("app") == .orderedSame {
                if let candidate = validatedCandidate(canonicalRoot, fileManager: fileManager) {
                    discoveredCandidates.append((rootIndex, candidate))
                } else if !optionalMissingRootPaths.contains(canonicalRoot.path) {
                    issues.append(
                        AppScanIssue(
                            rootURL: canonicalRoot,
                            affectedURL: canonicalRoot,
                            message: "The configured application bundle is unavailable."
                        )
                    )
                }
                continue
            }

            var rootIssues: [AppScanIssue] = []
            guard let enumerator = fileManager.enumerator(
                at: canonicalRoot,
                includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey],
                options: [.skipsHiddenFiles],
                errorHandler: { affectedURL, error in
                    rootIssues.append(
                        AppScanIssue(
                            rootURL: canonicalRoot,
                            affectedURL: affectedURL,
                            message: error.localizedDescription
                        )
                    )
                    return true
                }
            ) else {
                var isDirectory: ObjCBool = false
                if fileManager.fileExists(atPath: canonicalRoot.path, isDirectory: &isDirectory) {
                    let message = isDirectory.boolValue
                        ? "The search root could not be enumerated."
                        : "The search root is not a directory."
                    issues.append(
                        AppScanIssue(
                            rootURL: canonicalRoot,
                            affectedURL: canonicalRoot,
                            message: message
                        )
                    )
                } else if !optionalMissingRootPaths.contains(canonicalRoot.path) {
                    issues.append(
                        AppScanIssue(
                            rootURL: canonicalRoot,
                            affectedURL: canonicalRoot,
                            message: "The configured search root does not exist."
                        )
                    )
                }
                continue
            }

            while let candidate = enumerator.nextObject() as? URL {
                guard candidate.pathExtension.caseInsensitiveCompare("app") == .orderedSame else {
                    continue
                }

                // Explicitly skip descendants rather than relying solely on package
                // metadata. This prevents helper apps inside another .app bundle from
                // appearing as independent launcher entries.
                enumerator.skipDescendants()
                if let candidate = validatedCandidate(candidate, fileManager: fileManager) {
                    discoveredCandidates.append((rootIndex, candidate))
                }
            }
            issues.append(contentsOf: rootIssues)
        }

        // FileManager does not promise enumeration order. Sort before both path
        // and identifier de-duplication so repeated scans always choose the same
        // copy of an application. Earlier search roots retain precedence.
        discoveredCandidates.sort { lhs, rhs in
            if lhs.rootIndex != rhs.rootIndex { return lhs.rootIndex < rhs.rootIndex }
            return lhs.url.path < rhs.url.path
        }

        var candidateURLs: [(rootIndex: Int, url: URL)] = []
        for candidate in discoveredCandidates where seenBundlePaths.insert(candidate.url.path).inserted {
            candidateURLs.append(candidate)
        }

        var applicationCandidates: [ApplicationCandidate] = []
        var seenApplicationIDs = Set<String>()

        for candidateURL in candidateURLs {
            do {
                guard let candidate = try makeApplication(
                    at: candidateURL.url,
                    fileManager: fileManager
                ) else {
                    // Finder aliases and unrelated directories ending in .app
                    // are not application bundles. In particular, the absence
                    // of a standard Contents directory is not itself evidence
                    // that an otherwise complete inventory is partial.
                    continue
                }
                guard seenApplicationIDs.insert(candidate.application.id).inserted else {
                    continue
                }
                applicationCandidates.append(candidate)
            } catch {
                // A bundle can be observed while an installer is replacing its
                // Info.plist. Treat that as a partial inventory rather than
                // temporarily changing the app's stable ID to its path and
                // destructively reconciling the saved layout.
                let rootURL = canonicalURL(searchRoots[candidateURL.rootIndex])
                issues.append(
                    AppScanIssue(
                        rootURL: rootURL,
                        affectedURL: candidateURL.url.appendingPathComponent(
                            "Contents/Info.plist",
                            isDirectory: false
                        ),
                        message: error.localizedDescription
                    )
                )
            }
        }

        let applications = disambiguatedApplications(applicationCandidates)

        return AppScanResult(
            applications: applications.sorted(by: Self.stableApplicationOrder),
            issues: issues
        )
    }

    private func validatedCandidate(
        _ url: URL,
        fileManager: FileManager
    ) -> URL? {
        let canonical = canonicalURL(url)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: canonical.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return nil
        }
        return canonical
    }

    private func canonicalURL(_ url: URL) -> URL {
        url.resolvingSymlinksInPath().standardizedFileURL
    }

    private func makeApplication(
        at bundleURL: URL,
        fileManager: FileManager
    ) throws -> ApplicationCandidate? {
        let standardContentsURL = bundleURL.appendingPathComponent(
            "Contents",
            isDirectory: true
        )
        var isStandardContentsDirectory: ObjCBool = false

        let metadata: [String: Any]
        let resourcesURL: URL
        let localizationBundleURL: URL
        let alternateBundleName: String?
        let resolvesDirectIconFile: Bool

        if fileManager.fileExists(
            atPath: standardContentsURL.path,
            isDirectory: &isStandardContentsDirectory
        ), isStandardContentsDirectory.boolValue {
            // Once a conventional Contents directory exists, a missing,
            // unreadable, or truncated Info.plist is most likely an installer
            // replacement in progress. Propagate the error so callers mark the
            // inventory partial and never reconcile it destructively.
            metadata = try readRequiredPropertyList(
                at: standardContentsURL.appendingPathComponent(
                    "Info.plist",
                    isDirectory: false
                )
            )
            resourcesURL = standardContentsURL.appendingPathComponent(
                "Resources",
                isDirectory: true
            )
            localizationBundleURL = bundleURL
            alternateBundleName = nil
            resolvesDirectIconFile = true
        } else {
            // Apple-Silicon Macs can install compatible iOS applications as an
            // outer launchable .app containing exactly one Wrapper/*.app. The
            // inner bundle uses the iOS flat layout (Info.plist and resources at
            // its root), while NSWorkspace must still launch the outer URL.
            guard let wrappedBundleURL = singleWrappedApplication(
                in: bundleURL,
                fileManager: fileManager
            ), let wrappedMetadata = try? readRequiredPropertyList(
                at: wrappedBundleURL.appendingPathComponent(
                    "Info.plist",
                    isDirectory: false
                )
            ) else {
                // A nonstandard directory is safely ignored. It must not make
                // every future scan permanently partial merely because its name
                // ends in .app.
                return nil
            }
            metadata = wrappedMetadata
            resourcesURL = wrappedBundleURL
            localizationBundleURL = wrappedBundleURL
            alternateBundleName = wrappedBundleURL
                .deletingPathExtension()
                .lastPathComponent
            // Inner iOS icon PNGs are commonly low-resolution CgBI assets and
            // can render corruptly or with the wrong mask when loaded directly
            // by NSImage. Leave iconURL nil so LauncherModel asks IconServices
            // for the canonical macOS icon of the outer launchable wrapper.
            resolvesDirectIconFile = false
        }

        let fallbackName = bundleURL.deletingPathExtension().lastPathComponent
        let localizedBundle = Bundle(url: localizationBundleURL)
        let localizedMetadata = readLocalizedInfo(
            resourcesURL: resourcesURL,
            bundle: localizedBundle
        )
        let finderDisplayName = localizedFileName(
            fileManager.displayName(atPath: bundleURL.path)
        )

        // Tahoe system apps commonly store names in InfoPlist.loctable, while
        // older and third-party apps use InfoPlist.strings. Prefer both forms
        // before falling back to the unlocalized Info.plist value.
        let localizedDisplayName = nonEmptyString(
            localizedMetadata["CFBundleDisplayName"]
        )
        let localizedBundleName = nonEmptyString(localizedMetadata["CFBundleName"])
        let bundleDisplayName = nonEmptyString(metadata["CFBundleDisplayName"])
        let bundleName = nonEmptyString(metadata["CFBundleName"])
        let displayName = localizedDisplayName
            ?? localizedBundleName
            ?? nonEmptyString(
            localizedBundle?.object(forInfoDictionaryKey: "CFBundleDisplayName")
        )
            ?? nonEmptyString(localizedBundle?.object(forInfoDictionaryKey: "CFBundleName"))
            ?? bundleDisplayName
            ?? bundleName
            ?? finderDisplayName
            ?? fallbackName
        let bundleIdentifier = nonEmptyString(metadata["CFBundleIdentifier"])
        let iconURL = resolvesDirectIconFile
            ? resolveIconURL(
                metadata: metadata,
                resourcesURL: resourcesURL,
                fileManager: fileManager
            )
            : nil

        let application = InstalledApplication(
            name: displayName,
            bundleIdentifier: bundleIdentifier,
            bundleURL: bundleURL,
            iconURL: iconURL
        )
        return ApplicationCandidate(
            application: application,
            alternateNames: uniqueNames([
                localizedBundleName,
                bundleName,
                alternateBundleName,
                fallbackName,
                finderDisplayName,
                bundleDisplayName,
                localizedDisplayName,
            ])
        )
    }

    /// Returns the one flat iOS bundle embedded in an Apple-Silicon wrapper.
    /// Requiring exactly one immediate .app directory avoids guessing through
    /// arbitrary nested content or treating a half-copied wrapper as valid.
    private func singleWrappedApplication(
        in outerBundleURL: URL,
        fileManager: FileManager
    ) -> URL? {
        let wrapperURL = outerBundleURL.appendingPathComponent(
            "Wrapper",
            isDirectory: true
        )
        guard let children = try? fileManager.contentsOfDirectory(
            at: wrapperURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        let wrappedApplications = children.filter { child in
            guard child.pathExtension.caseInsensitiveCompare("app") == .orderedSame,
                  let values = try? child.resourceValues(forKeys: [.isDirectoryKey]) else {
                return false
            }
            return values.isDirectory == true
        }
        guard wrappedApplications.count == 1 else { return nil }
        return canonicalURL(wrappedApplications[0])
    }

    private func readRequiredPropertyList(at url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        guard let propertyList = try PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: nil
        ) as? [String: Any] else {
            throw CocoaError(.propertyListReadCorrupt)
        }
        return propertyList
    }

    /// Localized display names are normally authoritative. Some separately
    /// installable variants nevertheless ship the same localized name while
    /// retaining a distinct CFBundleName or bundle directory. Keep the first
    /// stable candidate's localized name and use those app-provided alternates
    /// only for actual collisions; this preserves localization without adding
    /// product-specific suffixes or hard-coded application names.
    private func disambiguatedApplications(
        _ candidates: [ApplicationCandidate]
    ) -> [InstalledApplication] {
        var applications = candidates.map(\.application)
        let originalKeys = applications.map { normalizedNameKey($0.name) }
        let groupedIndices = Dictionary(
            grouping: applications.indices,
            by: { originalKeys[$0] }
        )
        var reservedKeys = Set(originalKeys)

        for indices in groupedIndices.values where indices.count > 1 {
            let stableIndices = indices.sorted { lhs, rhs in
                let leftPath = applications[lhs].bundleURL.path
                let rightPath = applications[rhs].bundleURL.path
                if leftPath != rightPath { return leftPath < rightPath }
                return applications[lhs].id < applications[rhs].id
            }

            for index in stableIndices.dropFirst() {
                guard let alternate = candidates[index].alternateNames.first(where: {
                    let key = normalizedNameKey($0)
                    return key != originalKeys[index] && !reservedKeys.contains(key)
                }) else {
                    continue
                }
                applications[index].name = alternate
                reservedKeys.insert(normalizedNameKey(alternate))
            }
        }
        return applications
    }

    private func readPropertyList(at url: URL) -> [String: Any] {
        guard let data = try? Data(contentsOf: url),
              let propertyList = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let dictionary = propertyList as? [String: Any] else {
            return [:]
        }
        return dictionary
    }

    private func nonEmptyString(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func localizedFileName(_ value: String) -> String? {
        guard let name = nonEmptyString(value) else { return nil }
        guard name.lowercased().hasSuffix(".app") else { return name }
        return String(name.dropLast(4))
    }

    private func readLocalizedInfo(
        resourcesURL: URL,
        bundle: Bundle?
    ) -> [String: Any] {
        let tableURL = resourcesURL.appendingPathComponent("InfoPlist.loctable", isDirectory: false)

        let table = readPropertyList(at: tableURL)
        if !table.isEmpty {
            let localizations = table.compactMap { key, value in
                key != "LocProvenance" && value is [String: Any] ? key : nil
            }
            let preferred = Bundle.preferredLocalizations(
                from: localizations,
                forPreferences: preferredLanguages
            )

            for localization in preferred + ["none"] {
                if let values = table[localization] as? [String: Any] {
                    return values
                }
            }
        }

        // `Bundle.localizedInfoDictionary` follows the hosting process locale,
        // not this scanner's explicitly supplied language preferences. Read
        // conventional InfoPlist.strings resources directly first so tests,
        // command-line clients, and the app all resolve the same localization.
        var localizations = bundle?.localizations ?? []
        if let resourceEntries = try? FileManager.default.contentsOfDirectory(
            at: resourcesURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) {
            for entry in resourceEntries
            where entry.pathExtension.caseInsensitiveCompare("lproj") == .orderedSame {
                let localization = entry.deletingPathExtension().lastPathComponent
                if !localizations.contains(localization) {
                    localizations.append(localization)
                }
            }
        }
        let preferredStringLocalizations = Bundle.preferredLocalizations(
            from: localizations,
            forPreferences: preferredLanguages
        )
        for localization in preferredStringLocalizations {
            let stringsURL = resourcesURL
                .appendingPathComponent("\(localization).lproj", isDirectory: true)
                .appendingPathComponent("InfoPlist.strings", isDirectory: false)
            let values = readPropertyList(at: stringsURL)
            if !values.isEmpty { return values }
        }

        return bundle?.localizedInfoDictionary ?? [:]
    }

    private func uniqueNames(_ values: [String?]) -> [String] {
        var seen = Set<String>()
        return values.compactMap { value in
            guard let value else { return nil }
            let key = normalizedNameKey(value)
            guard !key.isEmpty, seen.insert(key).inserted else { return nil }
            return value
        }
    }

    private func normalizedNameKey(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(
                options: [.diacriticInsensitive, .widthInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
            .lowercased(with: Locale(identifier: "en_US_POSIX"))
    }

    private func resolveIconURL(
        metadata: [String: Any],
        resourcesURL: URL,
        fileManager: FileManager
    ) -> URL? {
        var iconNames: [String] = []

        if let iconFile = nonEmptyString(metadata["CFBundleIconFile"]) {
            iconNames.append(iconFile)
        }

        if let icons = metadata["CFBundleIcons"] as? [String: Any],
           let primaryIcon = icons["CFBundlePrimaryIcon"] as? [String: Any],
           let files = primaryIcon["CFBundleIconFiles"] as? [String] {
            iconNames.append(contentsOf: files.reversed())
        }

        for iconName in iconNames {
            let candidates: [String]
            if URL(fileURLWithPath: iconName).pathExtension.isEmpty {
                // macOS bundles normally use .icns; compatible iOS bundles
                // commonly declare a base name while storing only scaled PNGs.
                candidates = [
                    iconName,
                    iconName + ".icns",
                    iconName + "@3x.png",
                    iconName + "@2x.png",
                    iconName + "@2x~ipad.png",
                    iconName + ".png",
                ]
            } else {
                candidates = [iconName]
            }

            for candidate in candidates {
                let iconURL = resourcesURL.appendingPathComponent(candidate, isDirectory: false)
                if fileManager.fileExists(atPath: iconURL.path) {
                    return iconURL
                }
            }
        }

        return nil
    }

    private static func stableApplicationOrder(
        _ lhs: InstalledApplication,
        _ rhs: InstalledApplication
    ) -> Bool {
        let nameComparison = lhs.name.compare(
            rhs.name,
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            range: nil,
            locale: Locale(identifier: "en_US_POSIX")
        )

        if nameComparison != .orderedSame {
            return nameComparison == .orderedAscending
        }

        if lhs.id != rhs.id {
            return lhs.id < rhs.id
        }

        return lhs.bundleURL.path < rhs.bundleURL.path
    }
}
