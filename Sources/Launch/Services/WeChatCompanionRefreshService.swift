import AppKit
import Foundation

enum WeChatCompanionRefreshServiceError: Error {
    case primaryUnavailable
    case invalidPrimaryBundle
    case unexpectedItemAtDestination
    case companionTerminationRejected
    case companionTerminationTimedOut
    case planRejected(String)
    case copyFailed(String)
    case metadataUpdateFailed(String)
    case iconGenerationFailed(String)
    case signingFailed(String)
    case verificationFailed(String)
    case commitFailed(String)
    case rollbackFailed(recoveryPath: String, reason: String)
    case launchFailed(String)
    case cleanupFailed([String])

    var chineseDescription: String {
        switch self {
        case .primaryUnavailable:
            return "未找到 /Applications/WeChat.app，请先安装最新版微信。"
        case .invalidPrimaryBundle:
            return "当前 /Applications/WeChat.app 不是可识别的官方微信应用。"
        case .unexpectedItemAtDestination:
            return "“微信双开版.app”位置已有其他应用，已停止以免覆盖。"
        case .companionTerminationRejected:
            return "微信双开版未能安全退出，请手动退出后重试。"
        case .companionTerminationTimedOut:
            return "等待微信双开版退出超时；旧副本没有被更改。"
        case let .planRejected(reason):
            return "无法准备微信双开事务：\(reason)"
        case let .copyFailed(reason):
            return "复制微信主应用失败：\(reason)"
        case let .metadataUpdateFailed(reason):
            return "更新微信双开版名称失败：\(reason)"
        case let .iconGenerationFailed(reason):
            return "生成微信双开角标图标失败：\(reason)"
        case let .signingFailed(reason):
            return "为微信双开版签名失败：\(reason)"
        case let .verificationFailed(reason):
            return "微信双开版校验失败：\(reason)"
        case let .commitFailed(reason):
            return "替换微信双开版失败，旧副本已保留：\(reason)"
        case let .rollbackFailed(recoveryPath, reason):
            return "恢复旧微信副本失败；可恢复副本仍在 \(recoveryPath)。\(reason)"
        case let .launchFailed(reason):
            return "微信双开版已恢复到操作前状态，但启动失败：\(reason)"
        case let .cleanupFailed(paths):
            return "微信双开版已重建并启动，但旧备份未能清理：\(paths.joined(separator: "、"))"
        }
    }

    var englishDescription: String {
        switch self {
        case .primaryUnavailable:
            return "WeChat.app was not found in /Applications. Install the current WeChat release first."
        case .invalidPrimaryBundle:
            return "The app at /Applications/WeChat.app is not the recognized primary WeChat bundle."
        case .unexpectedItemAtDestination:
            return "Another app already occupies the WeChat companion destination, so nothing was overwritten."
        case .companionTerminationRejected:
            return "The WeChat companion could not quit safely. Quit it manually and try again."
        case .companionTerminationTimedOut:
            return "Timed out waiting for the WeChat companion to quit. The old copy was not changed."
        case let .planRejected(reason):
            return "Could not prepare the WeChat companion transaction: \(reason)"
        case let .copyFailed(reason):
            return "Could not copy the primary WeChat app: \(reason)"
        case let .metadataUpdateFailed(reason):
            return "Could not update the WeChat companion metadata: \(reason)"
        case let .iconGenerationFailed(reason):
            return "Could not create the companion badge icon: \(reason)"
        case let .signingFailed(reason):
            return "Could not ad-hoc sign the WeChat companion: \(reason)"
        case let .verificationFailed(reason):
            return "The rebuilt WeChat companion did not pass verification: \(reason)"
        case let .commitFailed(reason):
            return "Could not replace the WeChat companion. The previous copy was retained: \(reason)"
        case let .rollbackFailed(recoveryPath, reason):
            return "Could not restore the previous companion automatically. A recoverable copy remains at \(recoveryPath). \(reason)"
        case let .launchFailed(reason):
            return "The previous companion was restored, but the rebuilt copy could not launch: \(reason)"
        case let .cleanupFailed(paths):
            return "The WeChat companion was rebuilt and launched, but old backups could not be removed: \(paths.joined(separator: ", "))"
        }
    }
}

struct WeChatCompanionRefreshOutcome {
    let bundleURL: URL
    let cleanupWarning: WeChatCompanionRefreshServiceError?
}

private struct WeChatCompanionRefreshConfiguration {
    let primaryBundleURL: URL
    let legacyCompanionURL: URL
    let destinationBundleURL: URL
    let displayName: String

    static let `default` = WeChatCompanionRefreshConfiguration(
        primaryBundleURL: URL(fileURLWithPath: "/Applications/WeChat.app", isDirectory: true),
        legacyCompanionURL: URL(fileURLWithPath: "/Applications/微信生活版.app", isDirectory: true),
        destinationBundleURL: URL(fileURLWithPath: "/Applications/微信双开版.app", isDirectory: true),
        displayName: "微信双开版"
    )
}

struct WeChatCompanionRefreshCommitReceipt {
    let destinationBundleURL: URL
    let destinationBackupURL: URL?
    let legacyOriginalURL: URL?
    let legacyBackupURL: URL?
    let destinationWasCreated: Bool
}

/// Performs only filesystem-local work. The caller stops running companion
/// processes before `prepare` and again immediately before `commit`.
final class WeChatCompanionRefreshExecutor: @unchecked Sendable {
    typealias BundleCopier = (URL, URL) throws -> Void
    typealias BundleSigner = (URL) throws -> Void
    typealias SignatureVerifier = (URL) throws -> Void
    typealias ItemMover = (URL, URL) throws -> Void

    private let fileManager: FileManager
    private let copyBundle: BundleCopier
    private let signBundle: BundleSigner
    private let verifySignature: SignatureVerifier
    private let moveItem: ItemMover

    init(
        fileManager: FileManager = .default,
        copyBundle: @escaping BundleCopier = WeChatCompanionRefreshExecutor.cloneBundle,
        signBundle: @escaping BundleSigner = WeChatCompanionRefreshExecutor.adHocSign,
        verifySignature: @escaping SignatureVerifier = WeChatCompanionRefreshExecutor.verifyCodeSignature,
        moveItem: ItemMover? = nil
    ) {
        self.fileManager = fileManager
        self.copyBundle = copyBundle
        self.signBundle = signBundle
        self.verifySignature = verifySignature
        self.moveItem = moveItem ?? { source, destination in
            try fileManager.moveItem(at: source, to: destination)
        }
    }

    func existingCompanionURL(
        destination: URL,
        legacy: URL
    ) throws -> URL? {
        if itemExists(destination) {
            guard try validatedBundleIdentifier(at: destination)
                == WeChatDualLaunchPolicy.companionBundleIdentifier else {
                throw WeChatCompanionRefreshServiceError.unexpectedItemAtDestination
            }
            return destination
        }
        if itemExists(legacy),
           try validatedBundleIdentifier(at: legacy)
                == WeChatDualLaunchPolicy.companionBundleIdentifier {
            return legacy
        }
        return nil
    }

    func validatePrimaryBundle(_ url: URL) throws {
        guard itemExists(url) else {
            throw WeChatCompanionRefreshServiceError.primaryUnavailable
        }
        guard try validatedBundleIdentifier(at: url)
            == WeChatDualLaunchPolicy.primaryBundleIdentifier else {
            throw WeChatCompanionRefreshServiceError.invalidPrimaryBundle
        }
    }

    func prepare(
        plan: WeChatCompanionRefreshPlan,
        badgedIconData: Data?
    ) throws {
        let input = plan.input
        discardStaging(at: input.stagingBundleURL)
        do {
            try copyBundle(input.primaryBundleURL, input.stagingBundleURL)
        } catch {
            discardStaging(at: input.stagingBundleURL)
            throw WeChatCompanionRefreshServiceError.copyFailed(
                concise(error)
            )
        }

        do {
            try rewriteMetadata(
                in: input.stagingBundleURL,
                bundleIdentifier: input.expectedBundleIdentifier,
                naming: input.namingMetadata
            )
        } catch {
            discardStaging(at: input.stagingBundleURL)
            throw WeChatCompanionRefreshServiceError.metadataUpdateFailed(
                concise(error)
            )
        }

        if let badgedIconData {
            do {
                try writeBadgedIcon(
                    badgedIconData,
                    to: input.stagingBundleURL
                )
            } catch {
                discardStaging(at: input.stagingBundleURL)
                throw WeChatCompanionRefreshServiceError.iconGenerationFailed(
                    concise(error)
                )
            }
        }

        do {
            try signBundle(input.stagingBundleURL)
        } catch {
            discardStaging(at: input.stagingBundleURL)
            throw WeChatCompanionRefreshServiceError.signingFailed(
                concise(error)
            )
        }

        do {
            try verifyPreparedBundle(
                input.stagingBundleURL,
                expectedIdentifier: input.expectedBundleIdentifier,
                naming: input.namingMetadata
            )
        } catch {
            discardStaging(at: input.stagingBundleURL)
            throw WeChatCompanionRefreshServiceError.verificationFailed(
                concise(error)
            )
        }
    }

    func commit(
        plan: WeChatCompanionRefreshPlan,
        legacyCompanionURL: URL
    ) throws -> WeChatCompanionRefreshCommitReceipt {
        let input = plan.input
        let destination = input.destinationBundleURL
        let staging = input.stagingBundleURL
        let parent = destination.deletingLastPathComponent()
        let token = UUID().uuidString
        let destinationBackup = parent.appendingPathComponent(
            ".Launch-WeChat-previous-\(token).backup",
            isDirectory: true
        )
        let legacyBackup = parent.appendingPathComponent(
            ".Launch-WeChat-legacy-\(token).backup",
            isDirectory: true
        )

        var installedDestinationBackup: URL?
        var installedLegacyBackup: URL?
        var destinationWasCreated = false

        do {
            if itemExists(destination) {
                guard try validatedBundleIdentifier(at: destination)
                    == input.expectedBundleIdentifier else {
                    throw WeChatCompanionRefreshServiceError.unexpectedItemAtDestination
                }
                // Record the recovery location before invoking Foundation's
                // safe-save primitive. If the call reports an error after
                // creating its backup, the catch path can still restore it.
                installedDestinationBackup = destinationBackup
                _ = try fileManager.replaceItemAt(
                    destination,
                    withItemAt: staging,
                    backupItemName: destinationBackup.lastPathComponent,
                    options: [.usingNewMetadataOnly, .withoutDeletingBackupItem]
                )
            } else {
                try moveItem(staging, destination)
                destinationWasCreated = true
            }

            try verifyPreparedBundle(
                destination,
                expectedIdentifier: input.expectedBundleIdentifier,
                naming: input.namingMetadata
            )

            if legacyCompanionURL.standardizedFileURL != destination.standardizedFileURL,
               itemExists(legacyCompanionURL),
               try validatedBundleIdentifier(at: legacyCompanionURL)
                    == input.expectedBundleIdentifier {
                installedLegacyBackup = legacyBackup
                try moveItem(legacyCompanionURL, legacyBackup)
            }

            return WeChatCompanionRefreshCommitReceipt(
                destinationBundleURL: destination,
                destinationBackupURL: installedDestinationBackup,
                legacyOriginalURL: installedLegacyBackup == nil
                    ? nil
                    : legacyCompanionURL,
                legacyBackupURL: installedLegacyBackup,
                destinationWasCreated: destinationWasCreated
            )
        } catch {
            let receipt = WeChatCompanionRefreshCommitReceipt(
                destinationBundleURL: destination,
                destinationBackupURL: installedDestinationBackup,
                legacyOriginalURL: installedLegacyBackup == nil
                    ? nil
                    : legacyCompanionURL,
                legacyBackupURL: installedLegacyBackup,
                destinationWasCreated: destinationWasCreated
            )
            do {
                try rollback(receipt)
            } catch let rollbackError as WeChatCompanionRefreshServiceError {
                throw rollbackError
            } catch {
                let recovery = installedDestinationBackup
                    ?? installedLegacyBackup
                    ?? destination
                throw WeChatCompanionRefreshServiceError.rollbackFailed(
                    recoveryPath: recovery.path,
                    reason: concise(error)
                )
            }
            throw WeChatCompanionRefreshServiceError.commitFailed(
                concise(error)
            )
        }
    }

    func finalize(_ receipt: WeChatCompanionRefreshCommitReceipt) throws {
        var retainedPaths: [String] = []
        for backup in [
            receipt.destinationBackupURL,
            receipt.legacyBackupURL,
        ].compactMap({ $0 }) where itemExists(backup) {
            do {
                try fileManager.removeItem(at: backup)
            } catch {
                retainedPaths.append(backup.path)
                continue
            }
            if itemExists(backup) {
                retainedPaths.append(backup.path)
            }
        }
        if !retainedPaths.isEmpty {
            throw WeChatCompanionRefreshServiceError.cleanupFailed(
                retainedPaths
            )
        }
    }

    func rollback(_ receipt: WeChatCompanionRefreshCommitReceipt) throws {
        let failedNew = receipt.destinationBundleURL
            .deletingLastPathComponent()
            .appendingPathComponent(
                ".Launch-WeChat-failed-\(UUID().uuidString).discard",
                isDirectory: true
            )

        let previous = receipt.destinationBackupURL
        let hasPreviousBackup = previous.map(itemExists) ?? false
        let shouldIsolateInstalledDestination = receipt.destinationWasCreated
            || hasPreviousBackup

        // Isolate the failed new bundle first. It becomes a non-.app directory,
        // so every later failure still leaves at most one registered companion.
        if shouldIsolateInstalledDestination,
           itemExists(receipt.destinationBundleURL) {
            do {
                try moveItem(receipt.destinationBundleURL, failedNew)
            } catch {
                let recovery = (hasPreviousBackup ? previous : nil)
                    ?? receipt.legacyBackupURL
                    ?? receipt.destinationBundleURL
                throw WeChatCompanionRefreshServiceError.rollbackFailed(
                    recoveryPath: recovery.path,
                    reason: concise(error)
                )
            }
        }

        // Restore an old bundle that already occupied the final destination.
        if let previous, itemExists(previous) {
            do {
                try moveItem(previous, receipt.destinationBundleURL)
            } catch {
                throw WeChatCompanionRefreshServiceError.rollbackFailed(
                    recoveryPath: previous.path,
                    reason: concise(error)
                )
            }
        }

        // In the common legacy-only path the destination is now empty, so the
        // old filename can be restored last. If an old final destination was
        // restored above, retain the legacy copy under its non-.app backup name
        // instead of recreating two registered bundles with the same ID.
        if let legacyBackup = receipt.legacyBackupURL,
           let legacyOriginal = receipt.legacyOriginalURL,
           itemExists(legacyBackup),
           !itemExists(receipt.destinationBundleURL) {
            guard !itemExists(legacyOriginal) else {
                throw WeChatCompanionRefreshServiceError.rollbackFailed(
                    recoveryPath: legacyBackup.path,
                    reason: "The legacy destination is no longer empty."
                )
            }
            do {
                try moveItem(legacyBackup, legacyOriginal)
            } catch {
                throw WeChatCompanionRefreshServiceError.rollbackFailed(
                    recoveryPath: legacyBackup.path,
                    reason: concise(error)
                )
            }
        }

        if itemExists(failedNew) {
            try? fileManager.removeItem(at: failedNew)
        }
    }

    func discardStaging(at url: URL) {
        guard itemExists(url) else { return }
        try? fileManager.removeItem(at: url)
    }

    func volumeIdentifier(for url: URL) -> String? {
        var probe = url.standardizedFileURL
        while !itemExists(probe) {
            let parent = probe.deletingLastPathComponent()
            guard parent.path != probe.path else { return nil }
            probe = parent
        }
        guard let identifier = try? probe.resourceValues(
            forKeys: [.volumeIdentifierKey]
        ).volumeIdentifier else {
            return nil
        }
        return String(reflecting: identifier)
    }

    private func rewriteMetadata(
        in bundleURL: URL,
        bundleIdentifier: String,
        naming: WeChatCompanionNamingMetadata
    ) throws {
        let infoURL = bundleURL.appendingPathComponent(
            "Contents/Info.plist",
            isDirectory: false
        )
        try updatePropertyList(at: infoURL) { propertyList in
            propertyList["CFBundleIdentifier"] = bundleIdentifier
            propertyList["CFBundleDisplayName"] = naming.bundleDisplayName
            propertyList["CFBundleName"] = naming.bundleName
            propertyList["CFBundleGetInfoString"] = naming.bundleDisplayName
            if var URLTypes = propertyList["CFBundleURLTypes"]
                as? [[String: Any]] {
                for index in URLTypes.indices {
                    URLTypes[index]["CFBundleURLName"] = bundleIdentifier
                }
                propertyList["CFBundleURLTypes"] = URLTypes
            }
        }

        let resources = bundleURL.appendingPathComponent(
            "Contents/Resources",
            isDirectory: true
        )
        let children = try fileManager.contentsOfDirectory(
            at: resources,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        for localization in children where
            localization.pathExtension.caseInsensitiveCompare("lproj")
                == .orderedSame {
            let stringsURL = localization.appendingPathComponent(
                "InfoPlist.strings",
                isDirectory: false
            )
            guard itemExists(stringsURL) else { continue }
            try updatePropertyList(at: stringsURL) { propertyList in
                // Do not touch privacy explanations or any other localized key.
                propertyList["CFBundleDisplayName"] =
                    naming.localizedBundleDisplayName
                propertyList["CFBundleName"] = naming.localizedBundleName
            }
        }
    }

    private func updatePropertyList(
        at url: URL,
        mutate: (inout [String: Any]) -> Void
    ) throws {
        let data = try Data(contentsOf: url)
        var format = PropertyListSerialization.PropertyListFormat.xml
        guard var propertyList = try PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: &format
        ) as? [String: Any] else {
            throw CocoaError(.propertyListReadCorrupt)
        }
        mutate(&propertyList)
        // InfoPlist.strings commonly uses the legacy OpenStep syntax. Core
        // Foundation can read that format but deliberately cannot serialize it;
        // emit an equivalent binary plist while preserving every untouched key.
        let outputFormat: PropertyListSerialization.PropertyListFormat =
            format == .openStep ? .binary : format
        let output = try PropertyListSerialization.data(
            fromPropertyList: propertyList,
            format: outputFormat,
            options: 0
        )
        try output.write(to: url, options: .atomic)
    }

    private func writeBadgedIcon(
        _ data: Data,
        to bundleURL: URL
    ) throws {
        let info = try propertyList(
            at: bundleURL.appendingPathComponent("Contents/Info.plist")
        )
        var iconName = (info["CFBundleIconFile"] as? String) ?? "AppIcon"
        if URL(fileURLWithPath: iconName).pathExtension.isEmpty {
            iconName += ".icns"
        }
        let iconURL = bundleURL.appendingPathComponent(
            "Contents/Resources/\(iconName)",
            isDirectory: false
        )
        try data.write(to: iconURL, options: .atomic)
    }

    private func verifyPreparedBundle(
        _ bundleURL: URL,
        expectedIdentifier: String,
        naming: WeChatCompanionNamingMetadata
    ) throws {
        let info = try propertyList(
            at: bundleURL.appendingPathComponent("Contents/Info.plist")
        )
        guard info["CFBundleIdentifier"] as? String == expectedIdentifier,
              info["CFBundleDisplayName"] as? String
                == naming.bundleDisplayName,
              info["CFBundleName"] as? String == naming.bundleName else {
            throw CocoaError(.propertyListReadCorrupt)
        }

        let resources = bundleURL.appendingPathComponent("Contents/Resources")
        let children = try fileManager.contentsOfDirectory(
            at: resources,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        for localization in children where
            localization.pathExtension.caseInsensitiveCompare("lproj")
                == .orderedSame {
            let stringsURL = localization.appendingPathComponent(
                "InfoPlist.strings"
            )
            guard itemExists(stringsURL) else { continue }
            let localized = try propertyList(at: stringsURL)
            guard localized["CFBundleDisplayName"] as? String
                    == naming.localizedBundleDisplayName,
                  localized["CFBundleName"] as? String
                    == naming.localizedBundleName else {
                throw CocoaError(.propertyListReadCorrupt)
            }
        }
        try verifySignature(bundleURL)
    }

    private func validatedBundleIdentifier(at url: URL) throws -> String? {
        let values = try url.resourceValues(
            forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        )
        guard values.isDirectory == true,
              values.isSymbolicLink != true,
              url.pathExtension.caseInsensitiveCompare("app") == .orderedSame else {
            return nil
        }
        return try propertyList(
            at: url.appendingPathComponent("Contents/Info.plist")
        )["CFBundleIdentifier"] as? String
    }

    private func propertyList(at url: URL) throws -> [String: Any] {
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

    private func itemExists(_ url: URL) -> Bool {
        fileManager.fileExists(atPath: url.path)
    }

    private func concise(_ error: Error) -> String {
        let description = error.localizedDescription
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String(description.prefix(500))
    }

    private static func cloneBundle(source: URL, destination: URL) throws {
        try runCommand(
            executable: URL(fileURLWithPath: "/usr/bin/ditto"),
            arguments: [
                "--clone",
                "--noqtn",
                source.path,
                destination.path,
            ]
        )
    }

    private static func adHocSign(bundleURL: URL) throws {
        // This intentionally matches the user's known-working companion setup.
        // Arguments are passed directly to Process; no shell or interpolated
        // command string is involved.
        try runCommand(
            executable: URL(fileURLWithPath: "/usr/bin/codesign"),
            arguments: [
                "--force",
                "--deep",
                "--sign",
                "-",
                bundleURL.path,
            ]
        )
    }

    private static func verifyCodeSignature(bundleURL: URL) throws {
        try runCommand(
            executable: URL(fileURLWithPath: "/usr/bin/codesign"),
            arguments: [
                "--verify",
                "--deep",
                "--strict",
                "--verbose=2",
                bundleURL.path,
            ]
        )
    }

    private static func runCommand(
        executable: URL,
        arguments: [String]
    ) throws {
        let process = Process()
        let output = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = output
        try process.run()
        // Drain while the child is running. Waiting first can deadlock when a
        // future ditto/codesign version writes more than the pipe capacity.
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw NSError(
                domain: "WeChatCompanionRefreshCommand",
                code: Int(process.terminationStatus),
                userInfo: [
                    NSLocalizedDescriptionKey: String(
                        (message?.isEmpty == false
                            ? message!
                            : "Command exited with status \(process.terminationStatus)")
                            .prefix(500)
                    ),
                ]
            )
        }
    }
}

@MainActor
final class WeChatCompanionRefreshService {
    typealias RunningApplicationsProvider = (String) -> [NSRunningApplication]
    typealias ApplicationOpener = (
        URL,
        NSWorkspace.OpenConfiguration,
        @escaping (Error?) -> Void
    ) -> Void
    typealias FileSystemNotifier = (String) -> Void
    typealias IconRenderer = @MainActor (URL) throws -> Data

    private let configuration: WeChatCompanionRefreshConfiguration
    private let executor: WeChatCompanionRefreshExecutor
    private let runningApplications: RunningApplicationsProvider
    private let openApplication: ApplicationOpener
    private let noteFileSystemChanged: FileSystemNotifier
    private let renderBadgedIcon: IconRenderer

    init(
        primaryBundleURL: URL = WeChatCompanionRefreshConfiguration.default.primaryBundleURL,
        legacyCompanionURL: URL = WeChatCompanionRefreshConfiguration.default.legacyCompanionURL,
        destinationBundleURL: URL = WeChatCompanionRefreshConfiguration.default.destinationBundleURL,
        displayName: String = WeChatCompanionRefreshConfiguration.default.displayName,
        executor: WeChatCompanionRefreshExecutor = WeChatCompanionRefreshExecutor(),
        runningApplications: @escaping RunningApplicationsProvider = {
            NSRunningApplication.runningApplications(withBundleIdentifier: $0)
        },
        openApplication: @escaping ApplicationOpener = { url, configuration, completion in
            NSWorkspace.shared.openApplication(
                at: url,
                configuration: configuration
            ) { _, error in
                completion(error)
            }
        },
        noteFileSystemChanged: @escaping FileSystemNotifier = {
            NSWorkspace.shared.noteFileSystemChanged($0)
        },
        renderBadgedIcon: IconRenderer? = nil
    ) {
        configuration = WeChatCompanionRefreshConfiguration(
            primaryBundleURL: primaryBundleURL,
            legacyCompanionURL: legacyCompanionURL,
            destinationBundleURL: destinationBundleURL,
            displayName: displayName
        )
        self.executor = executor
        self.runningApplications = runningApplications
        self.openApplication = openApplication
        self.noteFileSystemChanged = noteFileSystemChanged
        self.renderBadgedIcon = renderBadgedIcon ?? { primaryBundleURL in
            try WeChatCompanionBadgeIconRenderer.render(
                primaryBundleURL: primaryBundleURL
            )
        }
    }

    func rebuildAndLaunch() async throws -> WeChatCompanionRefreshOutcome {
        try executor.validatePrimaryBundle(configuration.primaryBundleURL)

        let existing = try executor.existingCompanionURL(
            destination: configuration.destinationBundleURL,
            legacy: configuration.legacyCompanionURL
        )
        let staging = configuration.destinationBundleURL
            .deletingLastPathComponent()
            .appendingPathComponent(
                ".Launch-WeChat-staging-\(UUID().uuidString).app",
                isDirectory: true
            )
        let input = WeChatCompanionRefreshInput(
            primaryBundleURL: configuration.primaryBundleURL,
            existingCompanionURL: existing,
            stagingBundleURL: staging,
            destinationBundleURL: configuration.destinationBundleURL,
            expectedBundleIdentifier:
                WeChatDualLaunchPolicy.companionBundleIdentifier,
            namingMetadata: WeChatCompanionNamingMetadata(
                displayName: configuration.displayName
            )
        )
        let plan: WeChatCompanionRefreshPlan
        switch WeChatCompanionRefreshPolicy.makePlan(
            input: input,
            volumeIdentifier: executor.volumeIdentifier
        ) {
        case let .success(value):
            plan = value
        case let .failure(error):
            throw WeChatCompanionRefreshServiceError.planRejected(
                String(describing: error)
            )
        }

        // The badge is cosmetic. If a future WeChat release changes or omits
        // its icon resource, keep the copied original icon and continue.
        let iconData = try? renderBadgedIcon(configuration.primaryBundleURL)

        let executor = self.executor
        do {
            try await Task.detached(priority: .userInitiated) {
                try executor.prepare(
                    plan: plan,
                    badgedIconData: iconData
                )
            }.value
        } catch {
            executor.discardStaging(at: staging)
            throw error
        }

        do {
            // The 1.3 GB staging/signing operation can take long enough for a
            // user to reopen the old companion. Recheck before the only phase
            // that changes its installed path.
            try await terminateRunningCompanion()
        } catch {
            executor.discardStaging(at: staging)
            throw error
        }

        let receipt: WeChatCompanionRefreshCommitReceipt
        let legacyCompanionURL = configuration.legacyCompanionURL
        do {
            receipt = try await Task.detached(priority: .userInitiated) {
                try executor.commit(
                    plan: plan,
                    legacyCompanionURL: legacyCompanionURL
                )
            }.value
        } catch {
            executor.discardStaging(at: staging)
            throw error
        }

        noteFileSystemChanged(receipt.destinationBundleURL.path)
        do {
            try await open(receipt.destinationBundleURL)
        } catch {
            // NSWorkspace can fail after partially starting an app. Ask it to
            // quit before restoring the on-disk bundle; never force-terminate.
            // If it refuses, retain the non-.app backup for manual recovery
            // rather than replacing files under a process that is still live.
            do {
                try await terminateRunningCompanion()
            } catch {
                let recovery = receipt.destinationBackupURL
                    ?? receipt.legacyBackupURL
                    ?? receipt.destinationBundleURL
                throw WeChatCompanionRefreshServiceError.rollbackFailed(
                    recoveryPath: recovery.path,
                    reason: error.localizedDescription
                )
            }
            do {
                try await Task.detached(priority: .userInitiated) {
                    try executor.rollback(receipt)
                }.value
            } catch let rollbackError as WeChatCompanionRefreshServiceError {
                throw rollbackError
            } catch {
                let recovery = receipt.destinationBackupURL
                    ?? receipt.legacyBackupURL
                    ?? receipt.destinationBundleURL
                throw WeChatCompanionRefreshServiceError.rollbackFailed(
                    recoveryPath: recovery.path,
                    reason: error.localizedDescription
                )
            }
            noteFileSystemChanged(receipt.destinationBundleURL.path)
            if let legacy = receipt.legacyOriginalURL {
                noteFileSystemChanged(legacy.path)
            }
            throw WeChatCompanionRefreshServiceError.launchFailed(
                error.localizedDescription
            )
        }

        let cleanupWarning: WeChatCompanionRefreshServiceError?
        do {
            try executor.finalize(receipt)
            cleanupWarning = nil
        } catch let error as WeChatCompanionRefreshServiceError {
            cleanupWarning = error
        } catch {
            cleanupWarning = .cleanupFailed(
                [error.localizedDescription]
            )
        }
        noteFileSystemChanged(receipt.destinationBundleURL.path)
        return WeChatCompanionRefreshOutcome(
            bundleURL: receipt.destinationBundleURL,
            cleanupWarning: cleanupWarning
        )
    }

    private func terminateRunningCompanion() async throws {
        var applications = runningApplications(
            WeChatDualLaunchPolicy.companionBundleIdentifier
        ).filter { !$0.isTerminated }
        guard !applications.isEmpty else { return }
        for application in applications where !application.terminate() {
            throw WeChatCompanionRefreshServiceError
                .companionTerminationRejected
        }

        let deadline = ProcessInfo.processInfo.systemUptime + 8
        while ProcessInfo.processInfo.systemUptime < deadline {
            try Task.checkCancellation()
            applications = runningApplications(
                WeChatDualLaunchPolicy.companionBundleIdentifier
            ).filter { !$0.isTerminated }
            if applications.isEmpty { return }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw WeChatCompanionRefreshServiceError.companionTerminationTimedOut
    }

    private func open(_ url: URL) async throws {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.createsNewApplicationInstance = false
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            openApplication(url, configuration) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
    }
}

enum WeChatCompanionBadgeMarkerStyle: Equatable {
    case miuiGoldenInfinityLinkBadge
}

struct WeChatCompanionBadgeGeometry: Equatable {
    let sourceRect: NSRect
    let badgeCircle: NSRect
    let backRing: NSRect
    let frontRing: NSRect
    let ringWidth: CGFloat

    var markerBounds: NSRect {
        badgeCircle
    }

    static func layout(canvasSize: CGFloat) -> Self {
        let size = max(1, canvasSize)
        let badgeDiameter = size * 0.20
        let badgeCircle = NSRect(
            x: size * 0.16,
            y: size * 0.12,
            width: badgeDiameter,
            height: badgeDiameter
        )
        let ringDiameter = badgeDiameter * 0.36
        let frontRing = NSRect(
            x: badgeCircle.minX + badgeDiameter * 0.43,
            y: badgeCircle.minY + badgeDiameter * 0.18,
            width: ringDiameter,
            height: ringDiameter
        )
        return Self(
            sourceRect: NSRect(x: 0, y: 0, width: size, height: size),
            badgeCircle: badgeCircle,
            backRing: NSRect(
                x: badgeCircle.minX + badgeDiameter * 0.21,
                y: badgeCircle.minY + badgeDiameter * 0.40,
                width: ringDiameter,
                height: ringDiameter
            ),
            frontRing: frontRing,
            ringWidth: max(0.7, badgeDiameter * 0.075)
        )
    }
}

@MainActor
enum WeChatCompanionBadgeIconRenderer {
    static let markerStyle: WeChatCompanionBadgeMarkerStyle =
        .miuiGoldenInfinityLinkBadge

    // Supplying every standard 1x/2x iconset slot lets iconutil encode the
    // scale metadata expected by IconServices. The old hand-written chunks
    // contained only one representation per pixel size and were interpreted
    // as legacy/mismatched slots on current macOS releases.
    private static let iconsetVariants: [(String, Int)] = [
        ("icon_16x16.png", 16),
        ("icon_16x16@2x.png", 32),
        ("icon_32x32.png", 32),
        ("icon_32x32@2x.png", 64),
        ("icon_128x128.png", 128),
        ("icon_128x128@2x.png", 256),
        ("icon_256x256.png", 256),
        ("icon_256x256@2x.png", 512),
        ("icon_512x512.png", 512),
        ("icon_512x512@2x.png", 1024),
    ]

    static func render(primaryBundleURL: URL) throws -> Data {
        let infoURL = primaryBundleURL.appendingPathComponent(
            "Contents/Info.plist"
        )
        let infoData = try Data(contentsOf: infoURL)
        guard let info = try PropertyListSerialization.propertyList(
            from: infoData,
            options: [],
            format: nil
        ) as? [String: Any] else {
            throw CocoaError(.propertyListReadCorrupt)
        }
        var iconName = (info["CFBundleIconFile"] as? String) ?? "AppIcon"
        if URL(fileURLWithPath: iconName).pathExtension.isEmpty {
            iconName += ".icns"
        }
        let iconURL = primaryBundleURL.appendingPathComponent(
            "Contents/Resources/\(iconName)"
        )
        guard let source = NSImage(contentsOf: iconURL) else {
            throw CocoaError(.fileReadCorruptFile)
        }

        let fileManager = FileManager.default
        let temporaryRoot = fileManager.temporaryDirectory
            .appendingPathComponent(
                "Launch-WeChat-Icon-\(UUID().uuidString)",
                isDirectory: true
            )
        let iconsetURL = temporaryRoot.appendingPathComponent(
            "AppIcon.iconset",
            isDirectory: true
        )
        let outputURL = temporaryRoot.appendingPathComponent(
            "AppIcon.icns",
            isDirectory: false
        )
        try fileManager.createDirectory(
            at: iconsetURL,
            withIntermediateDirectories: true
        )
        defer { try? fileManager.removeItem(at: temporaryRoot) }

        for (filename, pixelSize) in iconsetVariants {
            let png = try renderPNG(source: source, pixelSize: pixelSize)
            try png.write(
                to: iconsetURL.appendingPathComponent(filename),
                options: .atomic
            )
        }
        try compileIconset(iconsetURL, outputURL: outputURL)
        let icon = try Data(contentsOf: outputURL)
        guard NSImage(data: icon) != nil else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return icon
    }

    static func renderPNG(
        source: NSImage,
        pixelSize: Int,
        includeMarker: Bool = true
    ) throws -> Data {
        let size = CGFloat(pixelSize)
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixelSize,
            pixelsHigh: pixelSize,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
            throw CocoaError(.fileWriteUnknown)
        }
        bitmap.size = NSSize(width: size, height: size)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current?.imageInterpolation = .high
        NSColor.clear.setFill()
        NSRect(x: 0, y: 0, width: size, height: size).fill()
        let geometry = WeChatCompanionBadgeGeometry.layout(canvasSize: size)
        source.draw(
            in: geometry.sourceRect,
            from: .zero,
            operation: .sourceOver,
            fraction: 1
        )

        if includeMarker {
            drawMarker(geometry, in: context)
        }
        context.flushGraphics()

        guard let png = bitmap.representation(
                using: .png,
                properties: [:]
              ) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return png
    }

    private static func drawMarker(
        _ geometry: WeChatCompanionBadgeGeometry,
        in context: NSGraphicsContext
    ) {
        context.cgContext.saveGState()
        defer { context.cgContext.restoreGState() }

        // Source-atop makes the marker incapable of adding opaque pixels
        // outside the primary icon. Its transparent padding and visual scale
        // therefore remain byte-for-byte equivalent at the alpha-mask level.
        context.cgContext.setBlendMode(.sourceAtop)
        let badge = NSBezierPath(ovalIn: geometry.badgeCircle)
        let badgeGradient = NSGradient(colorsAndLocations:
            (
                NSColor(
                    calibratedRed: 1.00,
                    green: 0.82,
                    blue: 0.28,
                    alpha: 1
                ),
                0
            ),
            (
                NSColor(
                    calibratedRed: 1.00,
                    green: 0.56,
                    blue: 0.02,
                    alpha: 1
                ),
                1
            )
        )
        badgeGradient?.draw(in: badge, angle: -48)

        // A restrained inner highlight keeps the badge crisp at Dock scale
        // without introducing another plate around the primary app icon.
        NSColor.white.withAlphaComponent(0.24).setStroke()
        badge.lineWidth = max(0.55, geometry.badgeCircle.width * 0.018)
        badge.stroke()

        drawInfinityLink(in: geometry.badgeCircle, context: context.cgContext)
    }

    private static func drawInfinityLink(
        in badgeCircle: NSRect,
        context: CGContext
    ) {
        let diameter = badgeCircle.width
        let center = CGPoint(x: badgeCircle.midX, y: badgeCircle.midY)
        let path = CGMutablePath()
        path.move(to: center)
        path.addCurve(
            to: CGPoint(
                x: badgeCircle.minX + diameter * 0.20,
                y: badgeCircle.minY + diameter * 0.50
            ),
            control1: CGPoint(
                x: badgeCircle.minX + diameter * 0.39,
                y: badgeCircle.minY + diameter * 0.68
            ),
            control2: CGPoint(
                x: badgeCircle.minX + diameter * 0.20,
                y: badgeCircle.minY + diameter * 0.70
            )
        )
        path.addCurve(
            to: center,
            control1: CGPoint(
                x: badgeCircle.minX + diameter * 0.20,
                y: badgeCircle.minY + diameter * 0.30
            ),
            control2: CGPoint(
                x: badgeCircle.minX + diameter * 0.39,
                y: badgeCircle.minY + diameter * 0.32
            )
        )
        path.addCurve(
            to: CGPoint(
                x: badgeCircle.minX + diameter * 0.80,
                y: badgeCircle.minY + diameter * 0.50
            ),
            control1: CGPoint(
                x: badgeCircle.minX + diameter * 0.61,
                y: badgeCircle.minY + diameter * 0.68
            ),
            control2: CGPoint(
                x: badgeCircle.minX + diameter * 0.80,
                y: badgeCircle.minY + diameter * 0.70
            )
        )
        path.addCurve(
            to: center,
            control1: CGPoint(
                x: badgeCircle.minX + diameter * 0.80,
                y: badgeCircle.minY + diameter * 0.30
            ),
            control2: CGPoint(
                x: badgeCircle.minX + diameter * 0.61,
                y: badgeCircle.minY + diameter * 0.32
            )
        )

        context.saveGState()
        defer { context.restoreGState() }
        context.addPath(path)
        context.setStrokeColor(NSColor.white.cgColor)
        context.setLineWidth(diameter * 0.072)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.strokePath()
    }

    private static func compileIconset(
        _ iconsetURL: URL,
        outputURL: URL
    ) throws {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
        process.arguments = [
            "--convert",
            "icns",
            "--output",
            outputURL.path,
            iconsetURL.path,
        ]
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw NSError(
                domain: "WeChatCompanionIconutil",
                code: Int(process.terminationStatus),
                userInfo: [
                    NSLocalizedDescriptionKey: String(
                        (message?.isEmpty == false
                            ? message!
                            : "iconutil exited with status \(process.terminationStatus)")
                            .prefix(500)
                    ),
                ]
            )
        }
    }
}
