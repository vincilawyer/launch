import AppKit
import Combine
import Foundation

private struct CheckFailure: Error, CustomStringConvertible {
    let description: String
}

private func expect(
    _ condition: @autoclosure () -> Bool,
    _ message: String
) throws {
    guard condition() else { throw CheckFailure(description: message) }
}

private func alphaBounds(in imageData: Data) throws -> NSRect? {
    guard let bitmap = NSBitmapImageRep(data: imageData) else {
        throw CheckFailure(description: "Could not decode rendered icon bitmap")
    }
    var minimumX = bitmap.pixelsWide
    var minimumY = bitmap.pixelsHigh
    var maximumX = -1
    var maximumY = -1
    for y in 0..<bitmap.pixelsHigh {
        for x in 0..<bitmap.pixelsWide
        where (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0 {
            minimumX = min(minimumX, x)
            minimumY = min(minimumY, y)
            maximumX = max(maximumX, x)
            maximumY = max(maximumY, y)
        }
    }
    guard maximumX >= minimumX, maximumY >= minimumY else { return nil }
    return NSRect(
        x: minimumX,
        y: minimumY,
        width: maximumX - minimumX + 1,
        height: maximumY - minimumY + 1
    )
}

private func cornerAlphaValues(in imageData: Data) throws -> [Int] {
    guard let bitmap = NSBitmapImageRep(data: imageData) else {
        throw CheckFailure(description: "Could not decode rendered icon bitmap")
    }
    return [
        (0, 0),
        (bitmap.pixelsWide - 1, 0),
        (0, bitmap.pixelsHigh - 1),
        (bitmap.pixelsWide - 1, bitmap.pixelsHigh - 1),
    ].map { x, y in
        Int(((bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) * 255).rounded())
    }
}

private func solidIconPNG(color: NSColor, size: Int = 32) throws -> Data {
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: size,
        pixelsHigh: size,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else {
        throw CheckFailure(description: "Could not allocate icon fixture bitmap")
    }
    for y in 0..<size {
        for x in 0..<size {
            bitmap.setColor(color, atX: x, y: y)
        }
    }
    guard let png = bitmap.representation(using: .png, properties: [:]) else {
        throw CheckFailure(description: "Could not encode icon fixture PNG")
    }
    return png
}

@main
private enum CoreChecks {
    static func main() async throws {
        try applicationScanning()
        try wrappedApplicationScanning()
        try await unreadableApplicationMetadataDoesNotReconcile()
        try await partialFirstScanUsesMemoryOnlyLayout()
        try collidingLocalizedApplicationNamesStayDistinct()
        try weChatDualLaunchPolicyIsExact()
        try weChatCompanionRefreshPlanIsTransactional()
        try weChatCompanionRefreshFailureRecoveryIsPhaseAware()
        try weChatCompanionExecutorKeepsOldUntilCommit()
        try weChatCompanionExecutorFailureLeavesOldUntouched()
        try await weChatCompanionLaunchFailureRollsBackWithOriginalIcon()
        try weChatRollbackFailureNeverRegistersDuplicate()
        try await weChatBadgeRendererProducesReadableICNS()
        try await applicationIconCacheTracksBundleReplacement()
        try await applicationDirectoryMonitorDebouncesChanges()
        try await incompleteScanDoesNotPersist()
        try layoutReconciliation()
        try await layoutRemovalCompactsPages()
        try await layoutMutationsStayConsistent()
        try await atomicTopLevelFolderInsertion()
        try await folderCreationCompactsAcrossPages()
        try await folderMemberMovesStayAtomic()
        try await layoutStoreRoundTrip()
        try await legacyFilesMigrateTogether()
        try await corruptLegacyFileDoesNotOverwriteSibling()
        try preferenceMigrationDefaults()
        try await shortcutSnapshotMigrationAndRoundTrip()
        try pageInteractionStateMachine()
        try await launcherModelSelectionCancelsInteraction()
        try await unifiedApplicationManagement()
        try errorTokenGuardsDelayedDismissal()
        print("Launch core checks passed (31/31)")
    }

    private static func applicationScanning() throws {
        let fixture = try TemporaryDirectory()
        defer { fixture.remove() }

        let root = fixture.url.appendingPathComponent("Applications", isDirectory: true)
        let utilities = root.appendingPathComponent("Utilities", isDirectory: true)
        try FileManager.default.createDirectory(at: utilities, withIntermediateDirectories: true)

        try makeApplication(named: "Zeta.app", in: root, displayName: "Zeta", bundleIdentifier: "example.zeta")
        let alpha = try makeApplication(
            named: "Alpha.app",
            in: root,
            displayName: "Álpha",
            bundleIdentifier: "example.alpha",
            iconName: "AppIcon"
        )
        let outer = try makeApplication(named: "Outer.app", in: root, displayName: "Outer", bundleIdentifier: "example.outer")
        try makeApplication(
            named: "Nested.app",
            in: outer.appendingPathComponent("Contents/Applications", isDirectory: true),
            displayName: "Nested",
            bundleIdentifier: "example.nested"
        )
        try makeApplication(named: "Utility.app", in: utilities, displayName: "Utility", bundleIdentifier: "example.utility")
        try makeApplication(
            named: "Localized.app",
            in: root,
            displayName: "Calculator",
            bundleIdentifier: "example.localized",
            localizedDisplayNames: ["en": "Calculator", "zh_CN": "计算器"]
        )

        let scanResult = AppScanner(
            searchRoots: [root, utilities],
            preferredLanguages: ["zh-Hans-CN"]
        ).scanApplicationsSynchronously()
        try expect(scanResult.isComplete, "Scanner unexpectedly reported a partial result")
        let applications = scanResult.applications
        try expect(
            applications.filter { $0.id != "example.localized" }.map(\.name) == ["Álpha", "Outer", "Utility", "Zeta"],
            "Scanner ordering changed"
        )
        try expect(Set(applications.map(\.id)).count == applications.count, "Scanner returned duplicate apps")
        try expect(!applications.contains { $0.bundleIdentifier == "example.nested" }, "Scanner included an app nested inside another app")
        try expect(
            applications.first(where: { $0.id == "example.localized" })?.name == "计算器",
            "Scanner did not use the preferred localized application name"
        )

        guard let scannedAlpha = applications.first(where: { $0.id == "example.alpha" }) else {
            throw CheckFailure(description: "Scanner did not find Alpha")
        }
        try expect(scannedAlpha.bundleURL == alpha.resolvingSymlinksInPath().standardizedFileURL, "Scanner changed the bundle URL")
        try expect(scannedAlpha.iconURL?.lastPathComponent == "AppIcon.icns", "Scanner did not resolve the icon")
    }

    private static func unreadableApplicationMetadataDoesNotReconcile() async throws {
        let fixture = try TemporaryDirectory()
        defer { fixture.remove() }

        let applicationsRoot = fixture.url.appendingPathComponent(
            "Applications",
            isDirectory: true
        )
        let bundle = try makeApplication(
            named: "Updating.app",
            in: applicationsRoot,
            displayName: "Updating",
            bundleIdentifier: "example.updating"
        )
        let scanner = AppScanner(searchRoots: [applicationsRoot])
        let complete = scanner.scanApplicationsSynchronously()
        try expect(
            complete.isComplete
                && complete.applications.map(\.id) == ["example.updating"],
            "The metadata fixture did not begin with one complete application"
        )

        let store = LayoutStore(
            directoryURL: fixture.url.appendingPathComponent("Store")
        )
        let savedLayout = LaunchLayout(
            pages: [[.application("example.updating")]]
        )
        try await store.save(layout: savedLayout, preferences: .default)

        // Simulate the short interval in which an installer has replaced or
        // truncated Info.plist but the .app directory is already visible.
        let infoURL = bundle.appendingPathComponent("Contents/Info.plist")
        try Data("{truncated".utf8).write(to: infoURL, options: .atomic)
        let partial = scanner.scanApplicationsSynchronously()
        try expect(
            !partial.isComplete
                && partial.applications.isEmpty
                && partial.issues.contains { $0.affectedURL == infoURL },
            "Unreadable bundle metadata was reported as a complete inventory"
        )

        var rejected = false
        do {
            _ = try await store.reconcileAndSave(
                layout: savedLayout,
                scanResult: partial,
                preferences: .default
            )
        } catch LayoutStoreError.incompleteApplicationScan {
            rejected = true
        }
        let retained = try await store.load()
        try expect(
            rejected && retained.layout == savedLayout,
            "A transient Info.plist failure overwrote the stable saved identity"
        )
    }

    private static func wrappedApplicationScanning() throws {
        let fixture = try TemporaryDirectory()
        defer { fixture.remove() }

        let applicationsRoot = fixture.url.appendingPathComponent(
            "Applications",
            isDirectory: true
        )
        let wrappedBundle = try makeWrappedApplication(
            named: "WrappedMobileApp.app",
            innerBundleName: "WrappedMobileApp.app",
            in: applicationsRoot,
            displayName: "Wrapped Mobile App",
            bundleIdentifier: "example.wrapped.mobile",
            iconName: "AppIcon60x60",
            localizedDisplayNames: ["zh-Hans": "包装移动应用"]
        )

        // A random directory ending in .app is not a standard or wrapped
        // application. It should be ignored without poisoning every scan.
        try FileManager.default.createDirectory(
            at: applicationsRoot.appendingPathComponent(
                "Unrelated.app",
                isDirectory: true
            ),
            withIntermediateDirectories: true
        )

        let result = AppScanner(
            searchRoots: [applicationsRoot],
            preferredLanguages: ["zh-Hans"]
        ).scanApplicationsSynchronously()
        try expect(
            result.isComplete && result.applications.count == 1,
            "A legal flat iOS wrapper made the inventory partial"
        )
        guard let application = result.applications.first else {
            throw CheckFailure(description: "The wrapped application was not scanned")
        }
        try expect(
            application.id == "example.wrapped.mobile"
                && application.name == "包装移动应用"
                && application.bundleURL
                    == wrappedBundle.resolvingSymlinksInPath().standardizedFileURL
                && application.iconURL == nil,
            "Wrapped metadata, localization, or outer IconServices fallback was lost"
        )
    }

    @MainActor
    private static func partialFirstScanUsesMemoryOnlyLayout() async throws {
        let fixture = try TemporaryDirectory()
        defer { fixture.remove() }

        let applicationsRoot = fixture.url.appendingPathComponent(
            "Applications",
            isDirectory: true
        )
        try makeApplication(
            named: "Available.app",
            in: applicationsRoot,
            displayName: "Available",
            bundleIdentifier: "example.available"
        )
        try makeApplication(
            named: "Hidden.app",
            in: applicationsRoot,
            displayName: "Hidden",
            bundleIdentifier: "example.hidden"
        )
        let updatingBundle = try makeApplication(
            named: "Updating.app",
            in: applicationsRoot,
            displayName: "Updating",
            bundleIdentifier: "example.updating"
        )
        let updatingInfoURL = updatingBundle.appendingPathComponent(
            "Contents/Info.plist",
            isDirectory: false
        )
        let completeUpdatingMetadata = try Data(contentsOf: updatingInfoURL)
        try Data("{truncated".utf8).write(to: updatingInfoURL, options: .atomic)

        let store = LayoutStore(
            directoryURL: fixture.url.appendingPathComponent("Store")
        )
        let savedPreferences = LaunchPreferences(
            hiddenApplicationIDs: ["example.hidden"]
        )
        try await store.save(layout: .empty, preferences: savedPreferences)
        let originalSnapshotData = try Data(contentsOf: store.snapshotFileURL)

        let model = LauncherModel(
            scanner: AppScanner(searchRoots: [applicationsRoot]),
            store: store,
            launchAtLoginManager: LaunchAtLoginManager(),
            directoryMonitor: ApplicationDirectoryMonitor(searchRoots: [])
        )
        await model.rescanNow()

        try expect(
            Set(model.applications.keys)
                == ["example.available", "example.hidden"]
                && model.layout.applicationIDs == ["example.available"]
                && model.errorMessage != nil,
            "A partial first scan did not show only confirmed visible apps"
        )
        let snapshotAfterPartialScan = try Data(contentsOf: store.snapshotFileURL)
        try expect(
            snapshotAfterPartialScan == originalSnapshotData,
            "A provisional first-scan layout changed the empty disk snapshot"
        )

        // Even when all confirmed apps become hidden, and then one is restored,
        // ordinary model persistence must remain gated while the inventory is
        // partial. This prevents a later UI action from accidentally committing
        // the provisional subset.
        model.hide("example.available")
        try expect(
            model.layout.applicationIDs.isEmpty,
            "Hiding every confirmed provisional app left a visible tile"
        )
        model.unhide("example.available")
        model.preferences.iconSize = 113
        model.savePreferences()
        await model.flushPersistence()
        let snapshotAfterProvisionalMutations = try Data(
            contentsOf: store.snapshotFileURL
        )
        try expect(
            model.layout.applicationIDs == ["example.available"]
                && snapshotAfterProvisionalMutations == originalSnapshotData,
            "A provisional mutation or flush replaced the stable empty snapshot"
        )

        // Once the same scanner becomes complete, it may safely add the recovered
        // application and atomically commit the coherent layout plus preference
        // changes made during the provisional interval.
        try completeUpdatingMetadata.write(to: updatingInfoURL, options: .atomic)
        await model.rescanNow()
        let stored = try await store.load()
        try expect(
            model.errorMessage == nil
                && model.layout.applicationIDs
                    == ["example.available", "example.updating"]
                && !model.layout.applicationIDs.contains("example.hidden")
                && stored.layout == model.layout
                && stored.preferences == model.preferences
                && stored.preferences.iconSize == 113,
            "A later complete scan did not reconcile and commit the provisional layout"
        )
    }

    private static func weChatDualLaunchPolicyIsExact() throws {
        try expect(
            WeChatDualLaunchPolicy.isPrimaryBundleIdentifier(
                "com.tencent.xinWeChat"
            )
                && !WeChatDualLaunchPolicy.isPrimaryBundleIdentifier(
                    "com.tencent.xinWeChat2"
                )
                && !WeChatDualLaunchPolicy.isPrimaryBundleIdentifier(
                    "COM.TENCENT.XINWECHAT"
                )
                && WeChatDualLaunchPolicy.isCompanionBundleIdentifier(
                    "com.tencent.xinWeChat2"
                )
                && !WeChatDualLaunchPolicy.isCompanionBundleIdentifier(
                    "com.tencent.xinWeChat"
                ),
            "WeChat dual launch recognition expanded beyond the two exact bundle identifiers"
        )
    }

    private static func weChatCompanionRefreshPlanIsTransactional() throws {
        let primary = URL(fileURLWithPath: "/Applications/WeChat.app", isDirectory: true)
        let previous = URL(fileURLWithPath: "/Applications/微信生活版.app", isDirectory: true)
        let staging = URL(
            fileURLWithPath: "/Applications/.Launch-WeChat-Staging.app",
            isDirectory: true
        )
        let destination = URL(
            fileURLWithPath: "/Applications/微信双开版.app",
            isDirectory: true
        )
        let naming = WeChatCompanionNamingMetadata(displayName: "微信双开版")
        let input = WeChatCompanionRefreshInput(
            primaryBundleURL: primary,
            existingCompanionURL: previous,
            stagingBundleURL: staging,
            destinationBundleURL: destination,
            expectedBundleIdentifier: WeChatDualLaunchPolicy.companionBundleIdentifier,
            namingMetadata: naming
        )
        let result = WeChatCompanionRefreshPolicy.makePlan(
            input: input,
            volumeIdentifier: { _ in "Applications-volume" }
        )
        guard case let .success(plan) = result else {
            throw CheckFailure(description: "A valid companion refresh plan was rejected")
        }

        let normalizedPrimary = plan.input.primaryBundleURL
        let normalizedPrevious = plan.input.existingCompanionURL
        let normalizedStaging = plan.input.stagingBundleURL
        let normalizedDestination = plan.input.destinationBundleURL
        let normalizedBundleIdentifier = plan.input.expectedBundleIdentifier

        try expect(
            normalizedPrimary.path == primary.path
                && normalizedPrevious?.path == previous.path
                && normalizedStaging.path == staging.path
                && normalizedDestination.path == destination.path,
            "The refresh plan canonicalized an application to a different path"
        )

        try expect(
            naming.isComplete
                && naming.bundleDisplayName == "微信双开版"
                && naming.bundleName == "微信双开版"
                && naming.localizedBundleDisplayName == "微信双开版"
                && naming.localizedBundleName == "微信双开版",
            "The refresh plan did not rewrite every name source used by the scanner"
        )
        try expect(
            plan.phases == [
                .copyPrimaryToStaging(
                    source: normalizedPrimary,
                    staging: normalizedStaging
                ),
                .rewriteMetadata(
                    bundleURL: normalizedStaging,
                    bundleIdentifier: normalizedBundleIdentifier,
                    naming: naming
                ),
                .applyIconBadge(bundleURL: normalizedStaging),
                .adHocSign(bundleURL: normalizedStaging),
                .verifyBundleIdentifier(
                    bundleURL: normalizedStaging,
                    expected: normalizedBundleIdentifier
                ),
                .verifyCodeSignature(bundleURL: normalizedStaging),
                .commitVerifiedStaging(
                    staging: normalizedStaging,
                    destination: normalizedDestination,
                    previousCompanion: normalizedPrevious
                ),
                .invalidateCachedIconAndRescan(
                    applicationID: normalizedBundleIdentifier
                ),
            ],
            "The companion refresh plan can replace the old copy before verification"
        )
        try expect(
            plan.commitPhaseIndex == 6,
            "The companion refresh plan did not isolate its commit phase"
        )

        let crossVolume = WeChatCompanionRefreshPolicy.makePlan(
            input: input,
            volumeIdentifier: { url in
                url.lastPathComponent == staging.lastPathComponent
                    ? "temporary-volume"
                    : "Applications-volume"
            }
        )
        try expect(
            crossVolume == .failure(.stagingMustShareDestinationVolume),
            "A cross-volume staging path was accepted for atomic replacement"
        )

        let conflictingInput = WeChatCompanionRefreshInput(
            primaryBundleURL: primary,
            existingCompanionURL: previous,
            stagingBundleURL: destination,
            destinationBundleURL: destination,
            expectedBundleIdentifier: WeChatDualLaunchPolicy.companionBundleIdentifier,
            namingMetadata: naming
        )
        let conflicting = WeChatCompanionRefreshPolicy.makePlan(
            input: conflictingInput,
            volumeIdentifier: { _ in "Applications-volume" }
        )
        guard case .failure(.conflictingPaths) = conflicting else {
            throw CheckFailure(
                description: "A staging path that could overwrite the destination was accepted"
            )
        }
    }

    private static func weChatCompanionRefreshFailureRecoveryIsPhaseAware() throws {
        let input = WeChatCompanionRefreshInput(
            primaryBundleURL: URL(fileURLWithPath: "/Applications/WeChat.app"),
            existingCompanionURL: URL(fileURLWithPath: "/Applications/微信生活版.app"),
            stagingBundleURL: URL(fileURLWithPath: "/Applications/.Launch-WeChat-Staging.app"),
            destinationBundleURL: URL(fileURLWithPath: "/Applications/微信双开版.app"),
            expectedBundleIdentifier: WeChatDualLaunchPolicy.companionBundleIdentifier,
            namingMetadata: .init(displayName: "微信双开版")
        )
        guard case let .success(plan) = WeChatCompanionRefreshPolicy.makePlan(
            input: input,
            volumeIdentifier: { _ in "Applications-volume" }
        ) else {
            throw CheckFailure(description: "Could not create the transaction fixture")
        }

        func transactionRunning(
            at target: WeChatCompanionRefreshPhase
        ) throws -> WeChatCompanionRefreshTransaction {
            var transaction = WeChatCompanionRefreshTransaction(plan: plan)
            guard case let .success(first) = transaction.start() else {
                throw CheckFailure(description: "A new refresh transaction did not start")
            }
            var current = first
            while current != target {
                guard case let .success(next) = transaction.complete(current),
                      let next else {
                    throw CheckFailure(
                        description: "The refresh transaction could not reach its requested phase"
                    )
                }
                current = next
            }
            return transaction
        }

        var concurrent = WeChatCompanionRefreshTransaction(plan: plan)
        _ = concurrent.start()
        try expect(
            concurrent.start() == .failure(.alreadyInProgress),
            "A second refresh was allowed to start inside one active transaction"
        )

        let verificationPhase = plan.phases[5]
        var verificationFailure = try transactionRunning(at: verificationPhase)
        guard case let .success(preCommitFailure) = verificationFailure.fail(
            verificationPhase,
            message: "signature rejected"
        ) else {
            throw CheckFailure(description: "A verification failure was not recorded")
        }
        try expect(
            preCommitFailure.recovery == .discardStagingKeepingExisting
                && !preCommitFailure.destinationWasCommitted,
            "A pre-commit failure did not preserve the existing companion"
        )

        let commitPhase = plan.phases[plan.commitPhaseIndex]
        var commitFailure = try transactionRunning(at: commitPhase)
        guard case let .success(failedCommit) = commitFailure.fail(
            commitPhase,
            message: "replace failed"
        ) else {
            throw CheckFailure(description: "A commit failure was not recorded")
        }
        try expect(
            failedCommit.recovery == .ensurePreviousCompanionRestored
                && !failedCommit.destinationWasCommitted,
            "A failed logical replacement did not require restoring the old companion"
        )

        let refreshPhase = plan.phases[plan.commitPhaseIndex + 1]
        var refreshFailure = try transactionRunning(at: refreshPhase)
        guard case let .success(postCommitFailure) = refreshFailure.fail(
            refreshPhase,
            message: "rescan failed"
        ) else {
            throw CheckFailure(description: "A post-commit refresh failure was not recorded")
        }
        try expect(
            postCommitFailure.recovery == .keepCommittedCompanionAndRetryRefresh
                && postCommitFailure.destinationWasCommitted,
            "A UI refresh failure attempted to roll back a verified committed companion"
        )
    }

    private static func weChatCompanionExecutorKeepsOldUntilCommit() throws {
        let fixture = try TemporaryDirectory()
        defer { fixture.remove() }
        let applications = fixture.url.appendingPathComponent(
            "Applications",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: applications,
            withIntermediateDirectories: true
        )
        let primary = try makeApplication(
            named: "WeChat.app",
            in: applications,
            displayName: "WeChat",
            bundleIdentifier: WeChatDualLaunchPolicy.primaryBundleIdentifier,
            bundleName: "WeChat",
            iconName: "AppIcon",
            localizedStringDisplayNames: ["zh-Hans": "微信"]
        )
        let openStepStrings = primary.appendingPathComponent(
            "Contents/Resources/zh-Hans.lproj/InfoPlist.strings"
        )
        try Data(
            """
            "CFBundleDisplayName" = "微信";
            "CFBundleName" = "微信";
            "NSCameraUsageDescription" = "保留相机说明";
            """.utf8
        ).write(to: openStepStrings)

        let legacy = try makeApplication(
            named: "微信生活版.app",
            in: applications,
            displayName: "微信生活版",
            bundleIdentifier: WeChatDualLaunchPolicy.companionBundleIdentifier
        )
        let oldMarker = legacy.appendingPathComponent("Contents/old-marker")
        try Data("old".utf8).write(to: oldMarker)
        let staging = applications.appendingPathComponent(".staging.app")
        let destination = applications.appendingPathComponent("微信双开版.app")
        let input = WeChatCompanionRefreshInput(
            primaryBundleURL: primary,
            existingCompanionURL: legacy,
            stagingBundleURL: staging,
            destinationBundleURL: destination,
            expectedBundleIdentifier:
                WeChatDualLaunchPolicy.companionBundleIdentifier,
            namingMetadata: .init(displayName: "微信双开版")
        )
        guard case let .success(plan) = WeChatCompanionRefreshPolicy.makePlan(
            input: input,
            volumeIdentifier: { _ in "fixture-volume" }
        ) else {
            throw CheckFailure(description: "Could not create executor fixture plan")
        }

        var signerRan = false
        var verifierRan = false
        let executor = WeChatCompanionRefreshExecutor(
            copyBundle: { source, destination in
                try FileManager.default.copyItem(at: source, to: destination)
            },
            signBundle: { _ in signerRan = true },
            verifySignature: { _ in verifierRan = true }
        )
        let badge = Data("badged-icon".utf8)
        try executor.prepare(plan: plan, badgedIconData: badge)

        try expect(
            FileManager.default.fileExists(atPath: oldMarker.path)
                && !FileManager.default.fileExists(atPath: destination.path),
            "Preparing a verified staging bundle changed the old companion"
        )
        let stagedInfo = try readPropertyList(
            at: staging.appendingPathComponent("Contents/Info.plist")
        )
        let stagedLocalized = try readPropertyList(
            at: staging.appendingPathComponent(
                "Contents/Resources/zh-Hans.lproj/InfoPlist.strings"
            )
        )
        try expect(
            stagedInfo["CFBundleIdentifier"] as? String
                == WeChatDualLaunchPolicy.companionBundleIdentifier
                && stagedInfo["CFBundleDisplayName"] as? String == "微信双开版"
                && stagedInfo["CFBundleName"] as? String == "微信双开版"
                && stagedLocalized["CFBundleDisplayName"] as? String == "微信双开版"
                && stagedLocalized["CFBundleName"] as? String == "微信双开版"
                && stagedLocalized["NSCameraUsageDescription"] as? String
                    == "保留相机说明",
            "The executor did not convert OpenStep localized metadata without losing privacy text"
        )
        let stagedIcon = try Data(contentsOf: staging.appendingPathComponent(
            "Contents/Resources/AppIcon.icns"
        ))
        try expect(
            stagedIcon == badge && signerRan && verifierRan,
            "The staged companion did not receive its badge/signature verification"
        )

        let receipt = try executor.commit(
            plan: plan,
            legacyCompanionURL: legacy
        )
        try expect(
            FileManager.default.fileExists(atPath: destination.path)
                && !FileManager.default.fileExists(atPath: legacy.path)
                && receipt.legacyBackupURL?.pathExtension != "app"
                && receipt.destinationBackupURL?.pathExtension != "app",
            "A successful commit left a registered legacy companion or an .app backup"
        )
        try executor.finalize(receipt)
        try expect(
            receipt.legacyBackupURL.map {
                !FileManager.default.fileExists(atPath: $0.path)
            } ?? true,
            "A successful companion transaction silently retained its old backup"
        )
    }

    private static func weChatCompanionExecutorFailureLeavesOldUntouched() throws {
        let fixture = try TemporaryDirectory()
        defer { fixture.remove() }
        let applications = fixture.url.appendingPathComponent(
            "Applications",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: applications,
            withIntermediateDirectories: true
        )
        let primary = try makeApplication(
            named: "WeChat.app",
            in: applications,
            displayName: "WeChat",
            bundleIdentifier: WeChatDualLaunchPolicy.primaryBundleIdentifier,
            iconName: "AppIcon"
        )
        let legacy = try makeApplication(
            named: "微信生活版.app",
            in: applications,
            displayName: "微信生活版",
            bundleIdentifier: WeChatDualLaunchPolicy.companionBundleIdentifier
        )
        let oldMarker = legacy.appendingPathComponent("Contents/old-marker")
        try Data("old".utf8).write(to: oldMarker)
        let staging = applications.appendingPathComponent(".staging.app")
        let destination = applications.appendingPathComponent("微信双开版.app")
        let input = WeChatCompanionRefreshInput(
            primaryBundleURL: primary,
            existingCompanionURL: legacy,
            stagingBundleURL: staging,
            destinationBundleURL: destination,
            expectedBundleIdentifier:
                WeChatDualLaunchPolicy.companionBundleIdentifier,
            namingMetadata: .init(displayName: "微信双开版")
        )
        guard case let .success(plan) = WeChatCompanionRefreshPolicy.makePlan(
            input: input,
            volumeIdentifier: { _ in "fixture-volume" }
        ) else {
            throw CheckFailure(description: "Could not create failure fixture plan")
        }
        let executor = WeChatCompanionRefreshExecutor(
            copyBundle: { source, destination in
                try FileManager.default.copyItem(at: source, to: destination)
            },
            signBundle: { _ in
                throw CheckFailure(description: "injected signing failure")
            },
            verifySignature: { _ in }
        )
        var failedDuringSigning = false
        do {
            try executor.prepare(plan: plan, badgedIconData: nil)
        } catch WeChatCompanionRefreshServiceError.signingFailed {
            failedDuringSigning = true
        }
        try expect(
            failedDuringSigning
                && FileManager.default.fileExists(atPath: oldMarker.path)
                && !FileManager.default.fileExists(atPath: staging.path)
                && !FileManager.default.fileExists(atPath: destination.path),
            "A pre-commit signing failure changed the old companion or leaked staging"
        )
    }

    private static func weChatCompanionLaunchFailureRollsBackWithOriginalIcon() async throws {
        let fixture = try TemporaryDirectory()
        defer { fixture.remove() }
        let applications = fixture.url.appendingPathComponent(
            "Applications",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: applications,
            withIntermediateDirectories: true
        )
        let primary = try makeApplication(
            named: "WeChat.app",
            in: applications,
            displayName: "WeChat",
            bundleIdentifier: WeChatDualLaunchPolicy.primaryBundleIdentifier,
            iconName: "AppIcon"
        )
        let legacy = try makeApplication(
            named: "微信生活版.app",
            in: applications,
            displayName: "微信生活版",
            bundleIdentifier: WeChatDualLaunchPolicy.companionBundleIdentifier
        )
        let oldMarker = legacy.appendingPathComponent("Contents/old-marker")
        try Data("old".utf8).write(to: oldMarker)
        let destination = applications.appendingPathComponent("微信双开版.app")
        let executor = WeChatCompanionRefreshExecutor(
            copyBundle: { source, destination in
                try FileManager.default.copyItem(at: source, to: destination)
            },
            signBundle: { _ in },
            verifySignature: { _ in }
        )
        let openerCounter = LockedCounter()
        let service = await MainActor.run {
            WeChatCompanionRefreshService(
                primaryBundleURL: primary,
                legacyCompanionURL: legacy,
                destinationBundleURL: destination,
                executor: executor,
                runningApplications: { _ in [] },
                openApplication: { _, configuration, completion in
                    if !configuration.createsNewApplicationInstance {
                        openerCounter.increment()
                    }
                    completion(NSError(
                        domain: "LaunchCoreChecks",
                        code: 91,
                        userInfo: [NSLocalizedDescriptionKey: "injected open failure"]
                    ))
                },
                noteFileSystemChanged: { _ in },
                renderBadgedIcon: { _ in
                    throw CheckFailure(description: "injected optional badge failure")
                }
            )
        }
        var rolledBackLaunch = false
        do {
            _ = try await service.rebuildAndLaunch()
        } catch WeChatCompanionRefreshServiceError.launchFailed {
            rolledBackLaunch = true
        }
        let leftovers = try FileManager.default.contentsOfDirectory(
            at: applications,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasPrefix(".Launch-WeChat-") }
        try expect(
            rolledBackLaunch
                && openerCounter.value == 1
                && FileManager.default.fileExists(atPath: oldMarker.path)
                && !FileManager.default.fileExists(atPath: destination.path)
                && leftovers.isEmpty,
            "An optional badge/open failure did not restore the exact old companion"
        )
    }

    private static func weChatRollbackFailureNeverRegistersDuplicate() throws {
        let fixture = try TemporaryDirectory()
        defer { fixture.remove() }
        let applications = fixture.url.appendingPathComponent(
            "Applications",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: applications,
            withIntermediateDirectories: true
        )
        let destination = try makeApplication(
            named: "微信双开版.app",
            in: applications,
            displayName: "微信双开版",
            bundleIdentifier: WeChatDualLaunchPolicy.companionBundleIdentifier
        )
        let legacyBackup = try makeApplication(
            named: ".Launch-WeChat-legacy-fixture.backup",
            in: applications,
            displayName: "微信生活版",
            bundleIdentifier: WeChatDualLaunchPolicy.companionBundleIdentifier
        )
        let legacyOriginal = applications.appendingPathComponent("微信生活版.app")
        let executor = WeChatCompanionRefreshExecutor(
            copyBundle: { _, _ in },
            signBundle: { _ in },
            verifySignature: { _ in },
            moveItem: { source, target in
                if source.standardizedFileURL == destination.standardizedFileURL {
                    throw CheckFailure(
                        description: "injected destination quarantine failure"
                    )
                }
                try FileManager.default.moveItem(at: source, to: target)
            }
        )
        let receipt = WeChatCompanionRefreshCommitReceipt(
            destinationBundleURL: destination,
            destinationBackupURL: nil,
            legacyOriginalURL: legacyOriginal,
            legacyBackupURL: legacyBackup,
            destinationWasCreated: true
        )
        var rollbackReportedFailure = false
        do {
            try executor.rollback(receipt)
        } catch WeChatCompanionRefreshServiceError.rollbackFailed {
            rollbackReportedFailure = true
        }
        let registeredCompanions = try FileManager.default.contentsOfDirectory(
            at: applications,
            includingPropertiesForKeys: nil
        ).filter { candidate in
            guard candidate.pathExtension.caseInsensitiveCompare("app")
                    == .orderedSame,
                  let propertyList = try? readPropertyList(
                    at: candidate.appendingPathComponent("Contents/Info.plist")
                  ),
                  let identifier = propertyList["CFBundleIdentifier"] as? String else {
                return false
            }
            return identifier
                == WeChatDualLaunchPolicy.companionBundleIdentifier
        }
        try expect(
            rollbackReportedFailure
                && registeredCompanions.count == 1
                && registeredCompanions.first?.lastPathComponent
                    == destination.lastPathComponent
                && !FileManager.default.fileExists(atPath: legacyOriginal.path)
                && FileManager.default.fileExists(atPath: legacyBackup.path),
            "A rollback move failure restored a second registered companion "
                + "(reported=\(rollbackReportedFailure), apps=\(registeredCompanions.map(\.lastPathComponent)), "
                + "legacy=\(FileManager.default.fileExists(atPath: legacyOriginal.path)), "
                + "backup=\(FileManager.default.fileExists(atPath: legacyBackup.path)))"
        )
    }

    private static func weChatBadgeRendererProducesReadableICNS() async throws {
        let fixture = try TemporaryDirectory()
        defer { fixture.remove() }
        let primary = try makeApplication(
            named: "WeChat.app",
            in: fixture.url,
            displayName: "WeChat",
            bundleIdentifier: WeChatDualLaunchPolicy.primaryBundleIdentifier,
            iconName: "AppIcon"
        )
        let sourcePNG = try await MainActor.run { () throws -> Data in
            guard let bitmap = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: 128,
                pixelsHigh: 128,
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
            ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
                throw CheckFailure(description: "Could not create icon fixture bitmap")
            }
            bitmap.size = NSSize(width: 128, height: 128)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            defer { NSGraphicsContext.restoreGraphicsState() }
            NSColor(calibratedRed: 0.12, green: 0.72, blue: 0.35, alpha: 1)
                .setFill()
            NSBezierPath(
                roundedRect: NSRect(x: 4, y: 4, width: 120, height: 120),
                xRadius: 28,
                yRadius: 28
            ).fill()
            context.flushGraphics()
            guard let png = bitmap.representation(using: .png, properties: [:]) else {
                throw CheckFailure(description: "Could not create icon fixture PNG")
            }
            return png
        }
        try sourcePNG.write(to: primary.appendingPathComponent(
            "Contents/Resources/AppIcon.icns"
        ))
        let output = try await MainActor.run {
            try WeChatCompanionBadgeIconRenderer.render(
                primaryBundleURL: primary
            )
        }
        let decodedMetrics = await MainActor.run { () -> (Bool, [Int]) in
            guard let image = NSImage(data: output) else {
                return (false, [])
            }
            return (true, image.representations.map(\.pixelsWide))
        }
        let geometry = WeChatCompanionBadgeGeometry.layout(canvasSize: 1024)
        let markerStyle = await MainActor.run {
            WeChatCompanionBadgeIconRenderer.markerStyle
        }
        let expectedPixelWidths = Set([16, 32, 64, 128, 256, 512, 1024])
        try expect(
            output.starts(with: Data("icns".utf8))
                && decodedMetrics.0
                && expectedPixelWidths.isSubset(of: Set(decodedMetrics.1))
                && !decodedMetrics.1.contains(48),
            "The generated companion badge was not a standard iconutil multi-resolution ICNS"
        )
        try expect(
            markerStyle == .miuiGoldenInfinityLinkBadge
                && geometry.sourceRect
                    == NSRect(x: 0, y: 0, width: 1024, height: 1024)
                && geometry.sourceRect.contains(geometry.badgeCircle)
                && geometry.badgeCircle.contains(geometry.backRing)
                && geometry.badgeCircle.contains(geometry.frontRing)
                && geometry.sourceRect.contains(geometry.backRing)
                && geometry.sourceRect.contains(geometry.frontRing)
                && geometry.backRing.intersects(geometry.frontRing)
                && geometry.backRing != geometry.frontRing
                && geometry.markerBounds.width >= 1024 * 0.195
                && geometry.markerBounds.width <= 1024 * 0.21
                && geometry.markerBounds.height >= 1024 * 0.195
                && geometry.markerBounds.height <= 1024 * 0.21,
            "The companion marker is not the small, text-free MIUI-style dual-ring design"
        )

        let alphaMasks = try await MainActor.run {
            guard let sourceImage = NSImage(data: sourcePNG) else {
                throw CheckFailure(description: "Could not decode source icon fixture")
            }
            let base = try WeChatCompanionBadgeIconRenderer.renderPNG(
                source: sourceImage,
                pixelSize: 256,
                includeMarker: false
            )
            let marked = try WeChatCompanionBadgeIconRenderer.renderPNG(
                source: sourceImage,
                pixelSize: 256
            )
            return (
                try alphaBounds(in: base),
                try alphaBounds(in: marked),
                try cornerAlphaValues(in: marked)
            )
        }
        try expect(
            alphaMasks.0 == alphaMasks.1
                && alphaMasks.2.allSatisfy { $0 == 0 },
            "The companion marker changed the primary icon's visual size or transparent padding"
        )
    }

    @MainActor
    private static func applicationIconCacheTracksBundleReplacement() async throws {
        let fixture = try TemporaryDirectory()
        defer { fixture.remove() }

        let applicationsRoot = fixture.url.appendingPathComponent(
            "Applications",
            isDirectory: true
        )
        let firstBundle = try makeApplication(
            named: "Original.app",
            in: applicationsRoot,
            displayName: "Original",
            bundleIdentifier: "example.cached-icon",
            iconName: "AppIcon"
        )
        try solidIconPNG(
            color: NSColor(calibratedRed: 0.85, green: 0.12, blue: 0.10, alpha: 1)
        ).write(
            to: firstBundle.appendingPathComponent(
                "Contents/Resources/AppIcon.icns"
            ),
            options: .atomic
        )

        let model = LauncherModel(
            scanner: AppScanner(searchRoots: [applicationsRoot]),
            store: LayoutStore(
                directoryURL: fixture.url.appendingPathComponent("Store")
            ),
            launchAtLoginManager: LaunchAtLoginManager(),
            directoryMonitor: ApplicationDirectoryMonitor(searchRoots: [])
        )
        await model.rescanNow()
        guard let firstIcon = model.icon(for: "example.cached-icon") else {
            throw CheckFailure(description: "Could not load the initial cached icon")
        }

        try FileManager.default.removeItem(at: firstBundle)
        let replacementBundle = try makeApplication(
            named: "Replacement.app",
            in: applicationsRoot,
            displayName: "Replacement",
            bundleIdentifier: "example.cached-icon",
            iconName: "AppIcon"
        )
        try solidIconPNG(
            color: NSColor(calibratedRed: 0.10, green: 0.32, blue: 0.88, alpha: 1)
        ).write(
            to: replacementBundle.appendingPathComponent(
                "Contents/Resources/AppIcon.icns"
            ),
            options: .atomic
        )

        await model.rescanNow()
        guard let replacementIcon = model.icon(for: "example.cached-icon") else {
            throw CheckFailure(description: "Could not load the replacement icon")
        }
        try expect(
            firstIcon !== replacementIcon
                && model.applications["example.cached-icon"]?.bundleURL
                    == replacementBundle.standardizedFileURL,
            "A same-identifier bundle replacement retained its stale cached icon"
        )

        try solidIconPNG(
            color: NSColor(calibratedRed: 0.10, green: 0.72, blue: 0.26, alpha: 1)
        ).write(
            to: replacementBundle.appendingPathComponent(
                "Contents/Resources/AppIcon.icns"
            ),
            options: .atomic
        )
        model.applicationBundleDidRefresh("example.cached-icon")
        guard let explicitlyRefreshedIcon = model.icon(
            for: "example.cached-icon"
        ) else {
            throw CheckFailure(description: "Could not reload an explicitly refreshed icon")
        }
        try expect(
            replacementIcon !== explicitlyRefreshedIcon,
            "Explicit bundle refresh did not evict the stable-path icon cache"
        )
    }

    private static func collidingLocalizedApplicationNamesStayDistinct() throws {
        let fixture = try TemporaryDirectory()
        defer { fixture.remove() }

        let root = fixture.url.appendingPathComponent("Applications", isDirectory: true)
        try makeApplication(
            named: "WeChat.app",
            in: root,
            displayName: "WeChat",
            bundleIdentifier: "example.wechat",
            bundleName: "WeChat",
            localizedStringDisplayNames: ["zh-Hans": "微信"]
        )
        try makeApplication(
            named: "微信双开版.app",
            in: root,
            displayName: "WeChat",
            bundleIdentifier: "example.wechat.lifestyle",
            bundleName: "微信双开版",
            localizedStringDisplayNames: ["zh-Hans": "微信"]
        )

        let result = AppScanner(
            searchRoots: [root],
            preferredLanguages: ["zh-Hans-CN"]
        ).scanApplicationsSynchronously()
        let namesByID = Dictionary(
            uniqueKeysWithValues: result.applications.map { ($0.id, $0.name) }
        )
        try expect(result.isComplete, "Localized-name fixture scan was incomplete")
        try expect(result.applications.count == 2, "Distinct application identifiers were de-duplicated")
        try expect(
            namesByID["example.wechat"] == "微信",
            "The primary app lost its localized display name"
        )
        try expect(
            namesByID["example.wechat.lifestyle"] == "微信双开版",
            "A localized-name collision ignored the variant's own bundle name"
        )
        try expect(
            Set(result.applications.map(\.name)).count == 2,
            "Two installable variants remained indistinguishable"
        )
    }

    private static func incompleteScanDoesNotPersist() async throws {
        let fixture = try TemporaryDirectory()
        defer { fixture.remove() }

        let store = LayoutStore(directoryURL: fixture.url.appendingPathComponent("Store"))
        let appA = application(id: "app.a", name: "A")
        let appB = application(id: "app.b", name: "B")
        let original = LaunchLayout(pages: [[.application(appA.id), .application(appB.id)]])
        try await store.save(layout: original, preferences: .default)
        let before = try Data(contentsOf: store.snapshotFileURL)

        let failedRoot = fixture.url.appendingPathComponent("Not A Directory")
        try Data("not a directory".utf8).write(to: failedRoot)
        let partial = AppScanner(searchRoots: [failedRoot]).scanApplicationsSynchronously()
        try expect(!partial.isComplete, "Scanner did not report an unreadable configured root")
        let missingRoot = fixture.url.appendingPathComponent("Temporarily Missing Applications")
        let missingResult = AppScanner(searchRoots: [missingRoot]).scanApplicationsSynchronously()
        try expect(!missingResult.isComplete, "Scanner treated a missing configured root as complete")

        var rejected = false
        do {
            _ = try await store.reconcileAndSave(
                layout: original,
                scanResult: partial,
                preferences: .default
            )
        } catch LayoutStoreError.incompleteApplicationScan(_) {
            rejected = true
        }

        try expect(rejected, "Store accepted a partial application inventory")
        let after = try Data(contentsOf: store.snapshotFileURL)
        try expect(after == before, "Partial scan changed the persisted snapshot")
        let loaded = try await store.load()
        try expect(loaded.layout == original, "Partial scan removed an application from disk")
    }

    private static func applicationDirectoryMonitorDebouncesChanges() async throws {
        let fixture = try TemporaryDirectory()
        defer { fixture.remove() }

        let watchedRoot = fixture.url.appendingPathComponent("Applications", isDirectory: true)
        try FileManager.default.createDirectory(at: watchedRoot, withIntermediateDirectories: true)
        let stagingRoot = fixture.url.appendingPathComponent("Staging", isDirectory: true)
        let stagedApplication = try makeApplication(
            named: "Just Installed.app",
            in: stagingRoot,
            displayName: "Just Installed",
            bundleIdentifier: "example.just-installed"
        )
        let callbackCount = LockedCounter()
        let monitor = ApplicationDirectoryMonitor(
            searchRoots: [watchedRoot],
            debounceInterval: 0.05,
            eventLatency: 0.01
        )
        defer { monitor.stop() }

        try expect(
            monitor.start { callbackCount.increment() },
            "Application directory monitor could not start"
        )
        try await Task.sleep(nanoseconds: 150_000_000)

        try FileManager.default.moveItem(
            at: stagedApplication,
            to: watchedRoot.appendingPathComponent("Just Installed.app", isDirectory: true)
        )
        let observedRealEvent = await waitForCount(callbackCount, atLeast: 1, timeout: 4)
        try expect(observedRealEvent, "Monitor did not observe an application added to a watched root")
        try await Task.sleep(nanoseconds: 180_000_000)
        let countAfterRealEvent = callbackCount.value

        monitor.simulateFileSystemEventForTesting()
        monitor.simulateFileSystemEventForTesting()
        monitor.simulateFileSystemEventForTesting()
        try await Task.sleep(nanoseconds: 250_000_000)
        try expect(
            callbackCount.value == countAfterRealEvent + 1,
            "Monitor did not debounce an event burst"
        )

        monitor.simulateFileSystemEventForTesting()
        monitor.stop()
        try await Task.sleep(nanoseconds: 120_000_000)
        try expect(
            callbackCount.value == countAfterRealEvent + 1,
            "Monitor delivered a callback after stop"
        )
    }

    private static func waitForCount(
        _ counter: LockedCounter,
        atLeast expectedCount: Int,
        timeout: TimeInterval
    ) async -> Bool {
        let attempts = max(1, Int(timeout / 0.05))
        for _ in 0..<attempts {
            if counter.value >= expectedCount { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return counter.value >= expectedCount
    }

    private static func layoutReconciliation() throws {
        let appA = application(id: "app.a", name: "A")
        let appB = application(id: "app.b", name: "B")
        let appC = application(id: "app.c", name: "C")
        let appD = application(id: "app.d", name: "D")
        let folderID = UUID()
        let folderEntryID = UUID()
        let folder = LaunchFolder(id: folderID, name: "Work", applicationIDs: [appB.id, "app.removed", appB.id])
        let original = LaunchLayout(pages: [
            [.application(appA.id), .folder(folder, id: folderEntryID), .application("app.removed")],
            [.application(appA.id)]
        ])
        let preferences = LaunchPreferences(rows: 1, columns: 2, hiddenApplicationIDs: [appC.id])
        let reconciled = original.reconciled(with: [appA, appB, appC, appD], preferences: preferences)

        try expect(reconciled.pages.count == 2, "Reconciliation created the wrong page count")
        try expect(reconciled.applicationIDs == [appA.id, appB.id, appD.id], "Reconciliation lost ordering")
        try expect(reconciled.pages[0][0].applicationID == appA.id, "First app moved unexpectedly")
        try expect(
            reconciled.pages[0][1].applicationID == appB.id,
            "A one-member folder was not dissolved during reconciliation"
        )
        try expect(
            reconciled.pages[0][1].id == folderEntryID,
            "Dissolving a reconciled folder changed its entry identity"
        )
        try expect(reconciled.pages[1].compactMap(\.applicationID) == [appD.id], "New app was not appended")
    }

    private static func layoutRemovalCompactsPages() async throws {
        let appA = application(id: "app.a", name: "A")
        let appB = application(id: "app.b", name: "B")
        let appC = application(id: "app.c", name: "C")
        let appD = application(id: "app.d", name: "D")
        let appE = application(id: "app.e", name: "E")
        let appF = application(id: "app.f", name: "F")
        let appG = application(id: "app.g", name: "G")
        let folder = LaunchFolder(
            id: UUID(),
            name: "Keep Together",
            applicationIDs: [appB.id, appC.id]
        )
        let folderEntryID = UUID()
        let original = LaunchLayout(pages: [
            [.application(appA.id), .application(appD.id)],
            [.folder(folder, id: folderEntryID), .application(appE.id)],
            [.application(appF.id), .application(appG.id)],
        ])

        let hiddenPreferences = LaunchPreferences(
            rows: 1,
            columns: 2,
            hiddenApplicationIDs: [appD.id]
        )
        let hidden = original.reconciled(
            with: [appA, appB, appC, appD, appE, appF, appG],
            preferences: hiddenPreferences
        )
        try expect(
            hidden.pages.map { $0.map { $0.applicationID ?? "folder" } }
                == [[appA.id, "folder"], [appE.id, appF.id], [appG.id]],
            "Hiding an app did not pull later entries forward across every page"
        )
        try expect(
            hidden.pages[0][1].id == folderEntryID,
            "Compaction replaced the folder entry identity"
        )
        try expect(
            hidden.pages[0][1].folder == folder,
            "Compaction changed folder metadata or member ordering"
        )
        try expect(
            hidden.pages.dropLast().allSatisfy { $0.count == 2 },
            "Compaction left an avoidable gap before the final page"
        )

        let deleted = original.reconciled(
            with: [appA, appB, appC, appE, appF, appG],
            pageCapacity: 2
        )
        try expect(
            deleted.pages == hidden.pages,
            "Deleting and hiding the same app used different compaction semantics"
        )

        let hiddenWholeFolder = original.reconciled(
            with: [appA, appB, appC, appD, appE, appF, appG],
            preferences: LaunchPreferences(
                rows: 1,
                columns: 2,
                hiddenApplicationIDs: [appB.id, appC.id, appD.id]
            )
        )
        try expect(
            hiddenWholeFolder.pages.map { $0.compactMap(\.applicationID) }
                == [[appA.id, appE.id], [appF.id, appG.id]],
            "Removing a whole folder left an empty slot or page"
        )

        let fixture = try TemporaryDirectory()
        defer { fixture.remove() }
        let store = LayoutStore(directoryURL: fixture.url.appendingPathComponent("Store"))
        try await store.save(layout: hidden, preferences: hiddenPreferences)
        let restored = try await store.load()
        try expect(restored.layout == hidden, "Compacted pages did not persist exactly")
        try expect(
            restored.preferences == hiddenPreferences,
            "Compacted layout was persisted with mismatched preferences"
        )
    }

    private static func layoutMutationsStayConsistent() async throws {
        let appA = application(id: "app.a", name: "A")
        let appB = application(id: "app.b", name: "B")
        let appC = application(id: "app.c", name: "C")
        let appD = application(id: "app.d", name: "D")
        let appE = application(id: "app.e", name: "E")

        // Folder drag identities are folder IDs, which are not guaranteed to be
        // equal to the containing entry ID in migrated layouts.
        let migratedFolder = LaunchFolder(
            id: UUID(),
            name: "Migrated",
            applicationIDs: [appB.id, appC.id]
        )
        let migratedEntryID = UUID()
        var ordered = LaunchLayout(pages: [[
            .application(appA.id),
            .folder(migratedFolder, id: migratedEntryID),
            .application(appD.id),
        ]])

        try expect(
            ordered.reorderEntry(
                matching: appD.id,
                before: appA.id,
                destinationPage: 0,
                pageCapacity: 3
            ) == LaunchEntryLocation(page: 0, index: 0),
            "Same-page drag did not report the moved entry location"
        )
        try expect(
            ordered.pages[0].compactMap(\.applicationID) == [appD.id, appA.id],
            "Same-page drag produced the wrong order"
        )

        try expect(
            ordered.reorderEntry(
                matching: migratedFolder.id.uuidString,
                before: appD.id,
                destinationPage: 0,
                pageCapacity: 3
            ) == LaunchEntryLocation(page: 0, index: 0),
            "A folder could not be dragged by its folder identity"
        )
        try expect(
            ordered.pages[0][0].id == migratedEntryID,
            "Folder dragging replaced its persisted entry identity"
        )

        let beforeRejectedDrop = ordered
        try expect(
            ordered.reorderEntry(
                matching: appA.id,
                before: "stale.drop.target",
                destinationPage: 0,
                pageCapacity: 3
            ) == nil && ordered == beforeRejectedDrop,
            "A stale drop target moved an entry"
        )
        try expect(
            ordered.reorderEntry(
                matching: appA.id,
                before: appA.id,
                destinationPage: 0,
                pageCapacity: 3
            ) == nil && ordered == beforeRejectedDrop,
            "Dropping an entry onto itself changed the layout"
        )

        var crossPage = LaunchLayout(pages: [
            [.application(appA.id)],
            [.application(appB.id)],
            [.application(appC.id)],
        ])
        let crossPageLocation = crossPage.reorderEntry(
            matching: appA.id,
            before: appB.id,
            destinationPage: 1,
            pageCapacity: 2
        )
        try expect(
            crossPage.pages.map { $0.compactMap(\.applicationID) }
                == [[appA.id, appB.id], [appC.id]],
            "Cross-page drag produced the wrong page ordering"
        )
        try expect(
            crossPageLocation == LaunchEntryLocation(page: 0, index: 0),
            "Cross-page drag returned a page index from before empty-page cleanup"
        )

        var fullPages = LaunchLayout(pages: [
            [.application(appA.id), .application(appB.id)],
            [.application(appC.id), .application(appD.id)],
            [.application(appE.id)],
        ])
        let overflowLocation = fullPages.reorderEntry(
            matching: appA.id,
            before: appD.id,
            destinationPage: 1,
            pageCapacity: 2
        )
        try expect(
            fullPages.pages.allSatisfy { $0.count <= 2 },
            "Cross-page drag overflowed the configured page capacity"
        )
        try expect(
            fullPages.pages.map { $0.compactMap(\.applicationID) }
                == [[appB.id], [appC.id, appA.id], [appD.id, appE.id]],
            "Cross-page overflow did not preserve global entry order"
        )
        try expect(
            overflowLocation == LaunchEntryLocation(page: 1, index: 1),
            "Cross-page overflow returned the wrong final location"
        )

        var folders = LaunchLayout(pages: [
            [.application(appA.id), .application(appB.id), .application(appC.id)],
            [.application(appD.id)],
        ])
        guard let createdFolder = folders.createFolder(
            from: appC.id,
            onto: appA.id,
            name: "New Folder",
            pageCapacity: 3
        ) else {
            throw CheckFailure(description: "Dragging an app onto an app did not create a folder")
        }
        try expect(
            createdFolder.applicationIDs == [appA.id, appC.id],
            "A newly created folder did not preserve target/source order"
        )
        try expect(
            folders.pages[0].first?.folder?.id == createdFolder.id,
            "The new folder was not inserted at the target location"
        )

        guard folders.addApplication(
            appB.id,
            toFolder: createdFolder.id,
            pageCapacity: 3
        ) != nil else {
            throw CheckFailure(description: "Dragging an app into a folder was rejected")
        }
        try expect(
            folders.applicationIDs == [appA.id, appC.id, appB.id, appD.id],
            "Dragging into a folder duplicated or reordered applications"
        )
        try expect(
            folders.addApplication(
                appB.id,
                toFolder: createdFolder.id,
                pageCapacity: 3
            ) == nil,
            "Adding an existing folder member reported a mutation"
        )

        // A malformed duplicate is canonicalized by the next folder drop and by
        // reconciliation, without losing the user's folder or member order.
        folders.pages[0].append(.application(appB.id))
        guard folders.addApplication(
            appB.id,
            toFolder: createdFolder.id,
            pageCapacity: 3
        ) != nil else {
            throw CheckFailure(description: "Folder drop did not remove an external duplicate")
        }
        try expect(
            folders.applicationIDs.filter { $0 == appB.id }.count == 1,
            "Folder drop left a duplicate application"
        )
        try expect(
            folders.reorderApplication(
                inFolder: createdFolder.id,
                draggedID: appB.id,
                before: appA.id
            ),
            "Folder member reorder was rejected"
        )
        let beforeStaleFolderDrop = folders
        try expect(
            !folders.reorderApplication(
                inFolder: createdFolder.id,
                draggedID: appA.id,
                before: "stale.folder.target"
            ) && folders == beforeStaleFolderDrop,
            "A stale folder target moved a member to the end"
        )

        let hiddenPreferences = LaunchPreferences(
            rows: 1,
            columns: 2,
            hiddenApplicationIDs: [appB.id]
        )
        let rescanned = folders.reconciled(
            with: [appA, appB, appC, appD, appE],
            preferences: hiddenPreferences
        )
        try expect(!rescanned.applicationIDs.contains(appB.id), "A hidden app returned after rescan")
        try expect(
            Set(rescanned.applicationIDs).count == rescanned.applicationIDs.count,
            "Reconciliation retained duplicate application IDs"
        )
        try expect(
            rescanned.pages.joined().compactMap(\.folder).first?.id == createdFolder.id,
            "Reconciliation replaced the created folder identity"
        )

        let fixture = try TemporaryDirectory()
        defer { fixture.remove() }
        let store = LayoutStore(directoryURL: fixture.url.appendingPathComponent("Store"))
        try await store.save(layout: rescanned, preferences: hiddenPreferences)
        let restored = try await store.load()
        try expect(restored.layout == rescanned, "Mutated layout did not persist exactly")
        try expect(
            restored.preferences.hiddenApplicationIDs == [appB.id],
            "Hidden IDs did not persist with the mutated layout"
        )

        // Removing an ID from the hidden set appends only that app; it must not
        // flatten the user's deliberately under-filled earlier page.
        let grouped = LaunchLayout(pages: [
            [.application(appA.id)],
            [.application(appC.id)],
        ])
        let unhidden = grouped.reconciled(
            with: [appA, appB, appC],
            preferences: LaunchPreferences(rows: 1, columns: 2)
        )
        try expect(
            unhidden.pages.map { $0.compactMap(\.applicationID) }
                == [[appA.id], [appC.id, appB.id]],
            "Unhiding an app flattened existing manual page groups"
        )
    }

    @MainActor
    private static func atomicTopLevelFolderInsertion() async throws {
        let fixture = try TemporaryDirectory()
        defer { fixture.remove() }

        let applicationsRoot = fixture.url.appendingPathComponent(
            "Applications",
            isDirectory: true
        )
        let ids = ["app.a", "app.b", "app.c", "app.d", "app.e", "app.f"]
        for id in ids {
            try makeApplication(
                named: "\(id).app",
                in: applicationsRoot,
                displayName: id,
                bundleIdentifier: id
            )
        }

        let destinationFolder = LaunchFolder(
            id: UUID(),
            name: "Destination",
            applicationIDs: [ids[1], ids[2]]
        )
        let destinationEntryID = UUID()
        let otherFolder = LaunchFolder(
            id: UUID(),
            name: "Other",
            applicationIDs: [ids[4], ids[5]]
        )
        let otherEntryID = UUID()
        let initialLayout = LaunchLayout(pages: [
            [
                .application(ids[0]),
                .folder(destinationFolder, id: destinationEntryID),
            ],
            [
                .application(ids[3]),
                .folder(otherFolder, id: otherEntryID),
            ],
        ])
        let preferences = LaunchPreferences(rows: 1, columns: 2)
        let store = LayoutStore(
            directoryURL: fixture.url.appendingPathComponent("Store")
        )
        try await store.save(layout: initialLayout, preferences: preferences)

        let model = LauncherModel(
            scanner: AppScanner(searchRoots: [applicationsRoot]),
            store: store,
            launchAtLoginManager: LaunchAtLoginManager(),
            directoryMonitor: ApplicationDirectoryMonitor(searchRoots: [])
        )
        await model.rescanNow()
        model.selectPage(1)
        model.openFolder(otherFolder.id)

        let beforeRejectedDrops = model.layout
        let originalPage = model.currentPage
        let originalOpenFolderID = model.openFolderID
        try expect(
            !model.addToFolder(
                appID: ids[0],
                folderID: destinationFolder.id,
                before: "stale.member"
            )
                && !model.addToFolder(
                    appID: ids[0],
                    folderID: destinationFolder.id,
                    before: ids[0]
                )
                && !model.addToFolder(
                    appID: ids[0],
                    folderID: destinationFolder.id,
                    before: ids[4]
                )
                && !model.addToFolder(
                    appID: ids[0],
                    folderID: UUID(),
                    before: nil
                )
                && !model.addToFolder(
                    appID: ids[1],
                    folderID: destinationFolder.id,
                    before: nil
                ),
            "A stale, self, cross-folder, or non-top-level drop was accepted"
        )
        try expect(
            model.layout == beforeRejectedDrops
                && model.currentPage == originalPage
                && model.openFolderID == originalOpenFolderID,
            "A rejected exact folder drop changed persistent or interaction state"
        )

        try expect(
            model.addToFolder(
                appID: ids[0],
                folderID: destinationFolder.id,
                before: ids[2]
            ),
            "A valid exact folder insertion was rejected"
        )
        try expect(
            model.layout.pages.map { $0.map { $0.applicationID ?? "folder" } }
                == [["folder", ids[3]], ["folder"]]
                && model.layout.pages[0][0].id == destinationEntryID
                && model.layout.pages[0][0].folder?.applicationIDs
                    == [ids[1], ids[0], ids[2]]
                && model.layout.pages[1][0].id == otherEntryID,
            "Exact folder insertion changed identity, member order, or page compaction"
        )
        try expect(
            model.currentPage == 0
                && model.openFolderID == originalOpenFolderID,
            "Exact folder insertion opened or closed a folder implicitly"
        )

        try expect(
            model.addToFolder(
                appID: ids[3],
                folderID: destinationFolder.id,
                before: nil
            ),
            "Appending a top-level application to a folder was rejected"
        )
        try expect(
            model.layout.pages.count == 1
                && model.layout.pages[0].map(\.id)
                    == [destinationEntryID, otherEntryID]
                && model.layout.pages[0][0].folder?.applicationIDs
                    == [ids[1], ids[0], ids[2], ids[3]]
                && Set(model.layout.applicationIDs).count
                    == model.layout.applicationIDs.count,
            "Nil-target folder insertion did not append exactly once"
        )
        try expect(
            model.openFolderID == originalOpenFolderID,
            "A second exact folder insertion changed openFolderID"
        )

        await model.flushPersistence()
        let restored = try await store.load()
        try expect(
            restored.layout == model.layout
                && restored.preferences == model.preferences,
            "The atomic folder insertion did not persist one coherent snapshot"
        )
    }

    private static func layoutStoreRoundTrip() async throws {
        let fixture = try TemporaryDirectory()
        defer { fixture.remove() }

        let store = LayoutStore(directoryURL: fixture.url.appendingPathComponent("Store"))
        let appA = application(id: "app.a", name: "A")
        let appB = application(id: "app.b", name: "B")
        let preferences = LaunchPreferences(
            rows: 2,
            columns: 1,
            iconSize: 84,
            showLabels: false,
            launchAtLogin: true,
            hiddenApplicationIDs: [appB.id]
        )

        try await store.savePreferences(preferences)
        let firstLoad = try await store.loadAndReconcile(
            scanResult: AppScanResult(applications: [appA, appB])
        )
        try expect(firstLoad.preferences == preferences, "Preferences did not round-trip")
        try expect(firstLoad.layout.applicationIDs == [appA.id], "Hidden app was added to the layout")

        let replacement = LaunchLayout(pages: [[.application(appA.id)]])
        try await store.save(layout: replacement, preferences: .default)
        let loaded = try await store.load()
        try expect(loaded.layout == replacement, "Layout did not round-trip")
        try expect(loaded.preferences == .default, "Default preferences did not round-trip")

        let storedNames = try FileManager.default.contentsOfDirectory(atPath: store.directoryURL.path)
        try expect(Set(storedNames) == ["snapshot.json"], "Atomic save left extra or temporary files behind")

        let snapshotData = try Data(contentsOf: store.snapshotFileURL)
        let snapshot = try JSONDecoder().decode(LaunchSnapshot.self, from: snapshotData)
        try expect(snapshot.layout == replacement, "Snapshot did not contain the latest layout")
        try expect(snapshot.preferences == .default, "Snapshot did not contain matching preferences")
    }

    private static func folderCreationCompactsAcrossPages() async throws {
        let applicationIDs = ["app.a", "app.b", "app.c", "app.d", "app.e", "app.f"]
        var layout = LaunchLayout(pages: [
            applicationIDs[0...1].map { .application($0) },
            applicationIDs[2...3].map { .application($0) },
            applicationIDs[4...5].map { .application($0) },
        ])

        guard let folder = layout.createFolder(
            from: applicationIDs[1],
            onto: applicationIDs[0],
            name: "Compacted",
            pageCapacity: 2
        ) else {
            throw CheckFailure(description: "Cross-page folder creation was rejected")
        }

        try expect(
            layout.pages.map { $0.map { $0.applicationID ?? "folder" } }
                == [["folder", applicationIDs[2]], [applicationIDs[3], applicationIDs[4]], [applicationIDs[5]]],
            "Folder creation did not pull the complete later-page sequence forward"
        )
        try expect(
            layout.pages.dropLast().allSatisfy { $0.count == 2 },
            "Folder creation left a preventable gap before the final page"
        )
        guard let persistedFolderEntry = layout.pages.first?.first,
              let persistedFolder = persistedFolderEntry.folder else {
            throw CheckFailure(description: "Compaction removed the newly created folder")
        }
        try expect(persistedFolder.id == folder.id, "Compaction replaced the folder identity")
        try expect(
            persistedFolder.applicationIDs == Array(applicationIDs[0...1]),
            "Compaction changed the target/source member order"
        )

        guard layout.addApplication(
            applicationIDs[2],
            toFolder: folder.id,
            pageCapacity: 2
        ) != nil else {
            throw CheckFailure(description: "Moving a later-page app into the folder was rejected")
        }
        try expect(
            layout.pages.map { $0.map { $0.applicationID ?? "folder" } }
                == [["folder", applicationIDs[3]], [applicationIDs[4], applicationIDs[5]]],
            "Moving an app into a folder did not compact all later pages"
        )
        try expect(
            layout.pages[0][0].folder?.applicationIDs == Array(applicationIDs[0...2]),
            "Moving an app into a folder changed existing member order"
        )

        let fixture = try TemporaryDirectory()
        defer { fixture.remove() }
        let preferences = LaunchPreferences(rows: 1, columns: 2)
        let store = LayoutStore(directoryURL: fixture.url.appendingPathComponent("Store"))
        try await store.save(layout: layout, preferences: preferences)
        let restored = try await store.load()
        try expect(restored.layout == layout, "Compacted folder layout did not persist exactly")
        try expect(restored.preferences == preferences, "Folder compaction persisted mismatched preferences")
    }

    private static func folderMemberMovesStayAtomic() async throws {
        let ids = ["app.a", "app.b", "app.c", "app.d", "app.e", "app.f", "app.g", "app.h"]
        let sourceFolder = LaunchFolder(
            id: UUID(),
            name: "Source",
            applicationIDs: Array(ids[0...2])
        )
        let sourceEntryID = UUID()
        let destinationFolder = LaunchFolder(
            id: UUID(),
            name: "Destination",
            applicationIDs: Array(ids[3...4])
        )
        let destinationEntryID = UUID()

        var betweenFolders = LaunchLayout(pages: [
            [.folder(sourceFolder, id: sourceEntryID), .application(ids[5])],
            [.application(ids[6]), .folder(destinationFolder, id: destinationEntryID)],
            [.application(ids[7])],
        ])

        let beforeSelfDrop = betweenFolders
        try expect(
            betweenFolders.moveApplication(
                ids[0],
                fromFolder: sourceFolder.id,
                toFolder: sourceFolder.id,
                pageCapacity: 2
            ) == nil && betweenFolders == beforeSelfDrop,
            "A same-folder member drop changed the layout"
        )
        try expect(
            betweenFolders.moveApplication(
                ids[0],
                fromFolder: UUID(),
                toFolder: destinationFolder.id,
                pageCapacity: 2
            ) == nil && betweenFolders == beforeSelfDrop,
            "A stale source folder changed the layout"
        )

        guard betweenFolders.moveApplication(
            ids[0],
            fromFolder: sourceFolder.id,
            toFolder: destinationFolder.id,
            pageCapacity: 2
        ) != nil else {
            throw CheckFailure(description: "Moving a member to another folder was rejected")
        }
        try expect(
            betweenFolders.pages[0][0].id == sourceEntryID
                && betweenFolders.pages[0][0].folder?.applicationIDs == Array(ids[1...2]),
            "Moving between folders changed the source identity or member order"
        )
        try expect(
            betweenFolders.pages[1][1].id == destinationEntryID
                && betweenFolders.pages[1][1].folder?.applicationIDs == [ids[3], ids[4], ids[0]],
            "Moving between folders changed the destination identity or append order"
        )
        try expect(
            Set(betweenFolders.applicationIDs).count == betweenFolders.applicationIDs.count,
            "Moving between folders duplicated an application"
        )

        // A two-member source must dissolve in place when one member is moved
        // directly into another folder.
        var dissolvingTransfer = LaunchLayout(pages: [[
            .folder(
                LaunchFolder(id: sourceFolder.id, name: "Two", applicationIDs: [ids[0], ids[1]]),
                id: sourceEntryID
            ),
            .folder(destinationFolder, id: destinationEntryID),
        ]])
        try expect(
            dissolvingTransfer.moveApplication(
                ids[0],
                fromFolder: sourceFolder.id,
                toFolder: destinationFolder.id,
                pageCapacity: 2
            ) != nil,
            "A transfer that dissolves its source folder was rejected"
        )
        try expect(
            dissolvingTransfer.pages[0][0].id == sourceEntryID
                && dissolvingTransfer.pages[0][0].applicationID == ids[1],
            "A one-member source did not dissolve with stable entry identity"
        )
        try expect(
            dissolvingTransfer.pages[0][1].folder?.applicationIDs == [ids[3], ids[4], ids[0]],
            "The moved member did not reach the destination folder exactly once"
        )

        var legacyAddPath = LaunchLayout(pages: [[
            .folder(
                LaunchFolder(id: sourceFolder.id, name: "Two", applicationIDs: [ids[0], ids[1]]),
                id: sourceEntryID
            ),
            .folder(destinationFolder, id: destinationEntryID),
        ]])
        try expect(
            legacyAddPath.addApplication(
                ids[0],
                toFolder: destinationFolder.id,
                pageCapacity: 2
            ) != nil,
            "The existing add-to-folder path rejected a folder member"
        )
        try expect(
            legacyAddPath.pages[0][0].id == sourceEntryID
                && legacyAddPath.pages[0][0].applicationID == ids[1],
            "The add-to-folder path left a one-member source container"
        )
        try expect(
            legacyAddPath.pages[0][1].folder?.applicationIDs == [ids[3], ids[4], ids[0]],
            "The add-to-folder path lost or reordered the moved member"
        )

        // Moving a member to a full later page inserts at the requested anchor,
        // carries overflow forward, and preserves both folder entry identities.
        var movedOut = LaunchLayout(pages: [
            [
                .folder(
                    LaunchFolder(id: sourceFolder.id, name: "Two", applicationIDs: [ids[0], ids[1]]),
                    id: sourceEntryID
                ),
                .application(ids[2]),
            ],
            [.application(ids[5]), .folder(destinationFolder, id: destinationEntryID)],
            [.application(ids[6])],
        ])
        let beforeStaleTarget = movedOut
        try expect(
            movedOut.moveApplicationOutOfFolder(
                ids[0],
                fromFolder: sourceFolder.id,
                destinationPage: 1,
                before: "stale.target",
                pageCapacity: 2
            ) == nil && movedOut == beforeStaleTarget,
            "A stale top-level target partially removed a folder member"
        )
        try expect(
            movedOut.moveApplicationOutOfFolder(
                ids[0],
                fromFolder: sourceFolder.id,
                destinationPage: 0,
                before: destinationEntryID.uuidString,
                pageCapacity: 2
            ) == nil && movedOut == beforeStaleTarget,
            "A target on a different page bypassed destination validation"
        )

        guard let movedLocation = movedOut.moveApplicationOutOfFolder(
            ids[0],
            fromFolder: sourceFolder.id,
            destinationPage: 1,
            before: destinationEntryID.uuidString,
            pageCapacity: 2
        ) else {
            throw CheckFailure(description: "Moving a folder member to the main grid was rejected")
        }
        try expect(
            movedLocation == LaunchEntryLocation(page: 1, index: 1),
            "The moved-out application reported the wrong final location"
        )
        try expect(
            movedOut.pages.map { $0.map { $0.applicationID ?? "folder" } }
                == [[ids[1], ids[2]], [ids[5], ids[0]], ["folder", ids[6]]],
            "Moving out did not preserve the requested cross-page global order"
        )
        try expect(
            movedOut.pages[0][0].id == sourceEntryID,
            "Moving out changed the dissolved source entry identity"
        )
        try expect(
            movedOut.pages[2][0].id == destinationEntryID
                && movedOut.pages[2][0].folder == destinationFolder,
            "Overflow changed the untouched destination folder identity"
        )
        try expect(
            movedOut.pages.allSatisfy { $0.count <= 2 },
            "Moving a member out overflowed page capacity"
        )
        try expect(
            Set(movedOut.applicationIDs).count == movedOut.applicationIDs.count,
            "Moving a member out duplicated or lost an application"
        )

        let fixture = try TemporaryDirectory()
        defer { fixture.remove() }
        let preferences = LaunchPreferences(rows: 1, columns: 2)
        let store = LayoutStore(directoryURL: fixture.url.appendingPathComponent("Store"))
        try await store.save(layout: movedOut, preferences: preferences)
        let restored = try await store.load()
        try expect(restored.layout == movedOut, "Folder-member movement did not persist exactly")
        try expect(restored.preferences == preferences, "Folder-member movement persisted mismatched preferences")
    }

    private static func legacyFilesMigrateTogether() async throws {
        let fixture = try TemporaryDirectory()
        defer { fixture.remove() }

        let store = LayoutStore(directoryURL: fixture.url.appendingPathComponent("Store"))
        try FileManager.default.createDirectory(
            at: store.directoryURL,
            withIntermediateDirectories: true
        )
        let legacyLayout = LaunchLayout(pages: [[.application("legacy.app")]])
        let legacyPreferences = LaunchPreferences(
            rows: 4,
            columns: 6,
            hiddenApplicationIDs: ["hidden.app"]
        )
        let layoutData = try JSONEncoder().encode(legacyLayout)
        let preferencesData = try JSONEncoder().encode(legacyPreferences)
        try layoutData.write(to: store.layoutFileURL)
        try preferencesData.write(to: store.preferencesFileURL)

        let migrated = try await store.load()
        try expect(migrated.layout == legacyLayout, "Legacy layout was not migrated")
        try expect(migrated.preferences == legacyPreferences, "Legacy preferences were not migrated")
        try expect(FileManager.default.fileExists(atPath: store.snapshotFileURL.path), "Migration did not create a snapshot")
        let retainedLayoutData = try Data(contentsOf: store.layoutFileURL)
        let retainedPreferencesData = try Data(contentsOf: store.preferencesFileURL)
        try expect(retainedLayoutData == layoutData, "Migration modified the legacy layout recovery copy")
        try expect(retainedPreferencesData == preferencesData, "Migration modified the legacy preferences recovery copy")
    }

    private static func corruptLegacyFileDoesNotOverwriteSibling() async throws {
        let fixture = try TemporaryDirectory()
        defer { fixture.remove() }

        let store = LayoutStore(directoryURL: fixture.url.appendingPathComponent("Store"))
        try FileManager.default.createDirectory(
            at: store.directoryURL,
            withIntermediateDirectories: true
        )
        let validLayoutData = try JSONEncoder().encode(
            LaunchLayout(pages: [[.application("keep.me")]])
        )
        let corruptPreferencesData = Data("{not valid json".utf8)
        try validLayoutData.write(to: store.layoutFileURL)
        try corruptPreferencesData.write(to: store.preferencesFileURL)

        var failed = false
        do {
            _ = try await store.load()
        } catch {
            failed = true
        }

        try expect(failed, "Corrupt legacy preferences were silently accepted")
        try expect(!FileManager.default.fileExists(atPath: store.snapshotFileURL.path), "Failed migration created a shadowing snapshot")
        let retainedLayoutData = try Data(contentsOf: store.layoutFileURL)
        let retainedPreferencesData = try Data(contentsOf: store.preferencesFileURL)
        try expect(retainedLayoutData == validLayoutData, "Valid legacy layout was overwritten")
        try expect(retainedPreferencesData == corruptPreferencesData, "Corrupt file was unexpectedly replaced")
    }

    private static func preferenceMigrationDefaults() throws {
        try expect(LaunchPreferences.default.iconSize == 100, "New preferences did not use the 100pt icon default")

        let missingIconSizeData = Data(#"{"rows":4,"columns":6,"showLabels":true,"launchAtLogin":false}"#.utf8)
        let missingIconSizePreferences = try JSONDecoder().decode(
            LaunchPreferences.self,
            from: missingIconSizeData
        )
        try expect(
            missingIconSizePreferences.iconSize == 100,
            "Preferences missing iconSize did not migrate to the 100pt default"
        )

        let data = Data(#"{"rows":4,"columns":6,"iconSize":64,"showLabels":true,"launchAtLogin":false}"#.utf8)
        let preferences = try JSONDecoder().decode(LaunchPreferences.self, from: data)
        try expect(preferences.iconSize == 64, "An explicitly saved icon size was overwritten during migration")
        try expect(preferences.hiddenApplicationIDs.isEmpty, "Migration default for hidden apps failed")
        try expect(preferences.pageCapacity == 24, "Page capacity migration failed")
        try expect(preferences.showMenuBarIcon, "Migration default for the menu-bar icon failed")
        try expect(
            preferences.globalShortcut == .optionSpace,
            "Migration default for the global shortcut failed"
        )
    }

    private static func shortcutSnapshotMigrationAndRoundTrip() async throws {
        let fixture = try TemporaryDirectory()
        defer { fixture.remove() }
        let store = LayoutStore(directoryURL: fixture.url.appendingPathComponent("Store"))
        try FileManager.default.createDirectory(
            at: store.directoryURL,
            withIntermediateDirectories: true
        )

        // Snapshot format 1 predates both shell preferences. Missing keys must
        // decode to the historical Option-Space behavior without a version bump.
        let oldSnapshot = Data(
            #"{"formatVersion":1,"layout":{"version":1,"pages":[[]]},"preferences":{"rows":4,"columns":6,"iconSize":64,"showLabels":true,"launchAtLogin":false,"hiddenApplicationIDs":[]}}"#.utf8
        )
        try oldSnapshot.write(to: store.snapshotFileURL)
        let migrated = try await store.load()
        try expect(migrated.preferences.showMenuBarIcon, "Old snapshot hid the menu-bar icon after migration")
        try expect(
            migrated.preferences.globalShortcut == .optionSpace,
            "Old snapshot did not retain the historical Option-Space shortcut"
        )

        let customShortcut = LaunchShortcutDescriptor(
            keyCode: 12,
            modifiers: LaunchShortcutDescriptor.commandModifier
                | LaunchShortcutDescriptor.shiftModifier,
            display: "⇧⌘Q"
        )
        var customPreferences = migrated.preferences
        customPreferences.showMenuBarIcon = false
        customPreferences.globalShortcut = customShortcut
        try await store.save(layout: migrated.layout, preferences: customPreferences)

        let customRestored = try await store.load()
        try expect(
            customRestored.preferences == customPreferences,
            "Custom menu-bar or shortcut preferences did not round-trip"
        )
        try expect(
            customRestored.preferences.globalShortcut.displayName == "⇧⌘Q",
            "Stored shortcut display text changed"
        )

        customPreferences.globalShortcut = .disabled
        try await store.save(layout: migrated.layout, preferences: customPreferences)
        let disabledRestored = try await store.load()
        try expect(
            !disabledRestored.preferences.globalShortcut.enabled,
            "Disabled shortcut was silently re-enabled after loading"
        )
        try expect(
            disabledRestored.preferences.globalShortcut.keyCode == LaunchShortcutDescriptor.optionSpace.keyCode,
            "Disabling a shortcut lost the descriptor needed to restore it"
        )
    }

    private static func pageInteractionStateMachine() throws {
        var interaction = LauncherPageInteractionState()
        try expect(interaction.begin(at: 1, pageCount: 3), "Page interaction did not begin")
        interaction.update(
            translation: -40,
            velocity: -200,
            pageExtent: 100,
            pageCount: 3
        )
        try expect(interaction.phase == .tracking, "Page interaction left tracking too early")
        try expect(interaction.progress == -0.4, "Page progress was not normalized by width")
        try expect(interaction.position == 1.4, "Interactive page position used the wrong sign")
        try expect(
            interaction.end(
                predictedTranslation: -40,
                pageExtent: 100,
                pageCount: 3
            ) == 2,
            "Leftward interaction did not resolve to the next page"
        )
        try expect(
            interaction.phase == .settling
                && interaction.targetPage == 2
                && interaction.position == 2,
            "Resolved page interaction exposed inconsistent settling state"
        )
        try expect(
            interaction.end(pageExtent: 100, pageCount: 3) == nil,
            "A gesture tail committed the same interaction twice"
        )
        interaction.complete()
        try expect(interaction == .idle, "Completing a page interaction did not clear it")

        interaction.begin(at: 0, pageCount: 3)
        interaction.update(translation: 80, pageExtent: 100, pageCount: 3)
        try expect(
            interaction.progress > 0 && interaction.progress < 0.8,
            "First-page overscroll did not apply rubber-band resistance"
        )
        try expect(
            interaction.end(
                predictedTranslation: 80,
                pageExtent: 100,
                pageCount: 3
            ) == 0,
            "First-page overscroll escaped the page boundary"
        )

        interaction.complete()
        interaction.begin(at: 2, pageCount: 3)
        interaction.update(translation: -80, pageExtent: 100, pageCount: 3)
        try expect(
            interaction.progress < 0 && interaction.progress > -0.8,
            "Last-page overscroll did not apply rubber-band resistance"
        )
        try expect(
            interaction.end(
                predictedTranslation: -80,
                pageExtent: 100,
                pageCount: 3
            ) == 2,
            "Last-page overscroll escaped the page boundary"
        )

        interaction.complete()
        interaction.begin(at: 1, pageCount: 3)
        interaction.update(translation: -5, pageExtent: 100, pageCount: 3)
        try expect(
            interaction.end(
                velocity: -300,
                pageExtent: 100,
                pageCount: 3
            ) == 2,
            "A decisive release velocity did not commit the adjacent page"
        )
        interaction.cancel()
        try expect(interaction == .idle, "Cancelling a page interaction did not clear it")

        // A visibly displaced page wins over a noisy opposite-direction lift
        // velocity. Exercise both directions so sign changes cannot regress.
        interaction.begin(at: 1, pageCount: 3)
        interaction.update(
            translation: -40,
            velocity: 110,
            pageExtent: 100,
            pageCount: 3
        )
        try expect(
            interaction.end(
                velocity: 110,
                pageExtent: 100,
                pageCount: 3
            ) == 2,
            "A clearly moved next page rebounded because of opposite lift velocity"
        )

        interaction.complete()
        interaction.begin(at: 1, pageCount: 3)
        interaction.update(
            translation: 40,
            velocity: -110,
            pageExtent: 100,
            pageCount: 3
        )
        try expect(
            interaction.end(
                velocity: -110,
                pageExtent: 100,
                pageCount: 3
            ) == 0,
            "A clearly moved previous page rebounded because of opposite lift velocity"
        )

        // Below the distance threshold, a same-direction fast flick may still
        // commit, but reverse velocity noise cannot flip to the other page.
        interaction.complete()
        interaction.begin(at: 1, pageCount: 3)
        interaction.update(translation: -8, pageExtent: 100, pageCount: 3)
        try expect(
            interaction.end(
                velocity: -180,
                pageExtent: 100,
                pageCount: 3
            ) == 2,
            "A short same-direction next-page flick did not commit"
        )

        interaction.complete()
        interaction.begin(at: 1, pageCount: 3)
        interaction.update(translation: 8, pageExtent: 100, pageCount: 3)
        try expect(
            interaction.end(
                velocity: 180,
                pageExtent: 100,
                pageCount: 3
            ) == 0,
            "A short same-direction previous-page flick did not commit"
        )

        interaction.complete()
        interaction.begin(at: 1, pageCount: 3)
        interaction.update(translation: -10, pageExtent: 100, pageCount: 3)
        try expect(
            interaction.end(
                velocity: 400,
                pageExtent: 100,
                pageCount: 3
            ) == 1,
            "Opposite lift noise reversed a sub-threshold next-page drag"
        )

        interaction.complete()
        interaction.begin(at: 1, pageCount: 3)
        interaction.update(translation: 10, pageExtent: 100, pageCount: 3)
        try expect(
            interaction.end(
                velocity: -400,
                pageExtent: 100,
                pageCount: 3
            ) == 1,
            "Opposite lift noise reversed a sub-threshold previous-page drag"
        )
    }

    private static func launcherModelSelectionCancelsInteraction() async throws {
        let fixture = try TemporaryDirectory()
        defer { fixture.remove() }

        try await MainActor.run {
            let model = LauncherModel(
                scanner: AppScanner(searchRoots: []),
                store: LayoutStore(directoryURL: fixture.url.appendingPathComponent("Store")),
                launchAtLoginManager: LaunchAtLoginManager(),
                directoryMonitor: ApplicationDirectoryMonitor(searchRoots: [])
            )
            try expect(model.beginPageInteraction(), "Launcher model rejected page tracking")
            model.updatePageInteraction(translation: 40, pageExtent: 100)
            try expect(model.pageInteraction.phase == .tracking, "Launcher model lost its tracking state")
            model.selectPage(0)
            try expect(
                model.pageInteraction == .idle,
                "External page selection did not cancel an active interaction"
            )

            let openFolderID = UUID()
            model.openFolderID = openFolderID
            try expect(
                !model.beginPageInteraction(),
                "Launcher model began page tracking behind an open folder"
            )
            model.selectPageKeepingFolderOpen(999)
            try expect(
                model.currentPage == 0,
                "Folder-drag page selection did not clamp its destination"
            )
            try expect(
                model.openFolderID == openFolderID,
                "Folder-drag page selection destroyed the recognizer-owning folder"
            )
            model.selectPage(0)
            try expect(
                model.openFolderID == nil,
                "Ordinary page selection stopped closing an open folder"
            )
        }
    }

    @MainActor
    private static func unifiedApplicationManagement() async throws {
        let fixture = try TemporaryDirectory()
        defer { fixture.remove() }

        let applicationsRoot = fixture.url.appendingPathComponent("Applications", isDirectory: true)
        try FileManager.default.createDirectory(
            at: applicationsRoot,
            withIntermediateDirectories: true
        )
        for (id, name) in [("app.a", "A"), ("app.b", "B"), ("app.c", "计算器")] {
            try makeApplication(
                named: "\(name).app",
                in: applicationsRoot,
                displayName: name,
                bundleIdentifier: id
            )
        }

        let store = LayoutStore(directoryURL: fixture.url.appendingPathComponent("Store"))
        let initialPreferences = LaunchPreferences(
            rows: 1,
            columns: 2,
            hiddenApplicationIDs: ["app.b"]
        )
        try await store.save(
            layout: LaunchLayout(pages: [[.application("app.a"), .application("app.c")]]),
            preferences: initialPreferences
        )

        let model = LauncherModel(
            scanner: AppScanner(searchRoots: [applicationsRoot]),
            store: store,
            launchAtLoginManager: LaunchAtLoginManager(),
            directoryMonitor: ApplicationDirectoryMonitor(searchRoots: [])
        )
        await model.rescanNow()

        let initialRows = model.managedApplications
        let firstHiddenIndex = initialRows.firstIndex { !$0.isVisible }
            ?? initialRows.endIndex
        try expect(
            initialRows[..<firstHiddenIndex].allSatisfy(\.isVisible)
                && initialRows[firstHiddenIndex...].allSatisfy { !$0.isVisible },
            "The unified management list did not group visible rows before hidden rows"
        )
        for group in [
            Array(initialRows[..<firstHiddenIndex]),
            Array(initialRows[firstHiddenIndex...]),
        ] {
            try expect(
                zip(group, group.dropFirst()).allSatisfy { lhs, rhs in
                    let order = lhs.application.name.localizedStandardCompare(
                        rhs.application.name
                    )
                    return order != .orderedDescending
                        && (order != .orderedSame || lhs.id <= rhs.id)
                },
                "An application-management visibility group was not locally sorted"
            )
        }
        try expect(
            initialRows.first(where: { $0.id == "app.c" })?.application.name == "计算器",
            "The unified management list replaced a localized Chinese application name"
        )
        try expect(
            initialRows.map(\.isVisible) == [true, true, false],
            "The unified management list did not derive grouped hidden state"
        )
        try expect(
            !model.setApplicationVisibility("missing.app", isVisible: false),
            "An unknown management row reported a visibility mutation"
        )
        try expect(
            !model.setApplicationVisibility("app.a", isVisible: true),
            "An unchanged visibility toggle reported a mutation"
        )
        try expect(
            model.setApplicationVisibility("app.a", isVisible: false),
            "A visible application could not be hidden from the unified list"
        )
        try expect(
            model.preferences.hiddenApplicationIDs == ["app.a", "app.b"],
            "Hiding one management row changed the wrong hidden IDs"
        )
        try expect(
            model.layout.applicationIDs == ["app.c"],
            "Hiding one management row left the app in the layout"
        )

        try expect(
            model.setApplicationVisibility("app.b", isVisible: true),
            "A hidden application could not be restored from the unified list"
        )
        try expect(
            model.managedApplications.first(where: { $0.id == "app.b" })?.isVisible == true,
            "The unified row did not reflect a restored application"
        )
        try expect(
            model.preferences.hiddenApplicationIDs == ["app.a"],
            "Restoring one row removed unrelated hidden state"
        )
        try expect(
            model.layout.applicationIDs == ["app.c", "app.b"],
            "Restoring a row did not append it once to the visible layout"
        )

        let managerState = LauncherApplicationManagerState(model: model)
        managerState.searchText = "app.a"
        let hiddenFilteredRows = managerState.filteredRows
        try expect(
            hiddenFilteredRows.count == 1
                && hiddenFilteredRows[0].id == "app.a"
                && !hiddenFilteredRows[0].isVisible
                && !model.isApplicationVisible("app.a"),
            "A management search did not derive the current hidden state"
        )
        try expect(
            managerState.requestVisibility("app.a", isVisible: true),
            "A filtered hidden application did not accept its presentation mutation"
        )
        try expect(
            managerState.visualVisibility(for: "app.a")
                && managerState.hiddenRows.map(\.id) == ["app.a"]
                && !model.isApplicationVisible("app.a"),
            "The filtered switch did not redraw before its native action completed"
        )

        await managerState.waitForPendingVisibilityChanges()
        let visibleFilteredRows = managerState.filteredRows
        try expect(
            visibleFilteredRows.count == 1
                && visibleFilteredRows[0].id == hiddenFilteredRows[0].id
                && visibleFilteredRows[0].isVisible
                && managerState.visibleRows.map(\.id) == ["app.a"]
                && managerState.hiddenRows.isEmpty
                && model.isApplicationVisible("app.a"),
            "A filtered management row did not migrate once after its switch action"
        )

        // Two changes inside one control turn must coalesce to the last visual
        // value instead of applying an obsolete task after the row has moved.
        try expect(
            managerState.requestVisibility("app.a", isVisible: false)
                && managerState.requestVisibility("app.a", isVisible: true),
            "A rapid visibility reversal was not accepted"
        )
        try expect(
            managerState.visualVisibility(for: "app.a"),
            "A cancelled visibility task left the switch showing its old request"
        )
        await managerState.waitForPendingVisibilityChanges()
        try expect(
            model.isApplicationVisible("app.a")
                && managerState.visibleRows.map(\.id) == ["app.a"]
                && managerState.hiddenRows.isEmpty,
            "A stale deferred visibility task won after a rapid reversal"
        )
        try expect(
            Set(model.layout.applicationIDs).count == model.layout.applicationIDs.count,
            "Visibility toggles introduced duplicate layout membership"
        )

        await model.flushPersistence()
        let restored = try await store.load()
        try expect(
            restored.preferences.hiddenApplicationIDs.isEmpty,
            "Unified visibility state did not persist"
        )
        try expect(
            restored.layout.applicationIDs == ["app.c", "app.b", "app.a"],
            "The unified management mutation persisted a mismatched layout"
        )
    }

    @MainActor
    private static func errorTokenGuardsDelayedDismissal() throws {
        let model = LauncherModel(
            launchAtLoginManager: LaunchAtLoginManager(),
            directoryMonitor: ApplicationDirectoryMonitor(searchRoots: [])
        )

        guard let oldToken = model.reportShellError("Older error") else {
            throw CheckFailure(description: "A nonempty error did not produce a token")
        }
        guard let currentToken = model.reportShellError("Current error") else {
            throw CheckFailure(description: "A replacement error did not produce a token")
        }
        try expect(oldToken != currentToken, "Replacing an error reused its dismissal token")
        try expect(
            !model.clearError(ifCurrent: oldToken)
                && model.errorMessage == "Current error"
                && model.errorToken == currentToken,
            "A delayed dismissal for an older error cleared the current message"
        )
        try expect(
            model.clearError(ifCurrent: currentToken)
                && model.errorMessage == nil
                && model.errorToken == nil,
            "The current error token could not dismiss its own message"
        )

        guard let manuallyClearedToken = model.reportShellError("Manual error") else {
            throw CheckFailure(description: "A manual error did not produce a token")
        }
        model.clearError()
        try expect(
            !model.clearError(ifCurrent: manuallyClearedToken),
            "Manual dismissal left its old automatic-clear token valid"
        )
        try expect(
            model.reportShellError("   ") == nil
                && model.errorMessage == nil
                && model.errorToken == nil,
            "An empty shell error created a visible error lifecycle"
        )
    }
}

private struct TemporaryDirectory {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("LaunchCoreChecks-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func remove() {
        try? FileManager.default.removeItem(at: url)
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }
}

private func readPropertyList(at url: URL) throws -> [String: Any] {
    let data = try Data(contentsOf: url)
    guard let propertyList = try PropertyListSerialization.propertyList(
        from: data,
        options: [],
        format: nil
    ) as? [String: Any] else {
        throw CheckFailure(
            description: "Could not decode property-list fixture at \(url.path)"
        )
    }
    return propertyList
}

@discardableResult
private func makeApplication(
    named bundleName: String,
    in directory: URL,
    displayName: String,
    bundleIdentifier: String,
    bundleName metadataBundleName: String? = nil,
    iconName: String? = nil,
    localizedDisplayNames: [String: String] = [:],
    localizedStringDisplayNames: [String: String] = [:]
) throws -> URL {
    let bundleURL = directory.appendingPathComponent(bundleName, isDirectory: true)
    let contentsURL = bundleURL.appendingPathComponent("Contents", isDirectory: true)
    let resourcesURL = contentsURL.appendingPathComponent("Resources", isDirectory: true)
    try FileManager.default.createDirectory(at: resourcesURL, withIntermediateDirectories: true)

    var propertyList: [String: Any] = [
        "CFBundleDisplayName": displayName,
        "CFBundleIdentifier": bundleIdentifier,
        "CFBundleName": metadataBundleName ?? displayName,
        "CFBundlePackageType": "APPL"
    ]
    if let iconName {
        propertyList["CFBundleIconFile"] = iconName
        try Data("icon".utf8).write(to: resourcesURL.appendingPathComponent(iconName + ".icns"))
    }

    let propertyListData = try PropertyListSerialization.data(
        fromPropertyList: propertyList,
        format: .xml,
        options: 0
    )
    try propertyListData.write(to: contentsURL.appendingPathComponent("Info.plist"))

    if !localizedDisplayNames.isEmpty {
        let localizationTable = localizedDisplayNames.reduce(into: [String: [String: String]]()) {
            $0[$1.key] = [
                "CFBundleDisplayName": $1.value,
                "CFBundleName": $1.value,
            ]
        }
        let localizationData = try PropertyListSerialization.data(
            fromPropertyList: localizationTable,
            format: .binary,
            options: 0
        )
        try localizationData.write(
            to: resourcesURL.appendingPathComponent("InfoPlist.loctable")
        )
    }
    for (localization, localizedName) in localizedStringDisplayNames {
        let localizationURL = resourcesURL.appendingPathComponent(
            "\(localization).lproj",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: localizationURL,
            withIntermediateDirectories: true
        )
        let stringsData = try PropertyListSerialization.data(
            fromPropertyList: [
                "CFBundleDisplayName": localizedName,
                "CFBundleName": localizedName,
            ],
            format: .binary,
            options: 0
        )
        try stringsData.write(
            to: localizationURL.appendingPathComponent("InfoPlist.strings")
        )
    }
    return bundleURL
}

/// Builds the flat inner bundle used when compatible iOS applications are
/// installed on Apple-Silicon macOS. The outer URL is what NSWorkspace opens;
/// metadata, localized resources, and scaled PNG icons live in Wrapper/*.app.
@discardableResult
private func makeWrappedApplication(
    named outerBundleName: String,
    innerBundleName: String,
    in directory: URL,
    displayName: String,
    bundleIdentifier: String,
    iconName: String,
    localizedDisplayNames: [String: String] = [:]
) throws -> URL {
    let outerBundleURL = directory.appendingPathComponent(
        outerBundleName,
        isDirectory: true
    )
    let wrapperURL = outerBundleURL.appendingPathComponent(
        "Wrapper",
        isDirectory: true
    )
    let innerBundleURL = wrapperURL.appendingPathComponent(
        innerBundleName,
        isDirectory: true
    )
    try FileManager.default.createDirectory(
        at: innerBundleURL,
        withIntermediateDirectories: true
    )

    let propertyList: [String: Any] = [
        "CFBundleDisplayName": displayName,
        "CFBundleIdentifier": bundleIdentifier,
        "CFBundleName": displayName,
        "CFBundlePackageType": "APPL",
        "CFBundleSupportedPlatforms": ["iPhoneOS"],
        "CFBundleIcons": [
            "CFBundlePrimaryIcon": [
                "CFBundleIconFiles": [iconName],
            ],
        ],
    ]
    let propertyListData = try PropertyListSerialization.data(
        fromPropertyList: propertyList,
        format: .xml,
        options: 0
    )
    try propertyListData.write(
        to: innerBundleURL.appendingPathComponent("Info.plist")
    )
    try Data("wrapped-icon".utf8).write(
        to: innerBundleURL.appendingPathComponent(iconName + "@2x.png")
    )

    for (localization, localizedName) in localizedDisplayNames {
        let localizationURL = innerBundleURL.appendingPathComponent(
            "\(localization).lproj",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: localizationURL,
            withIntermediateDirectories: true
        )
        let stringsData = try PropertyListSerialization.data(
            fromPropertyList: [
                "CFBundleDisplayName": localizedName,
                "CFBundleName": localizedName,
            ],
            format: .binary,
            options: 0
        )
        try stringsData.write(
            to: localizationURL.appendingPathComponent("InfoPlist.strings")
        )
    }

    // Match the public layout created for App Store iOS applications. Scanner
    // discovery intentionally validates Wrapper rather than trusting this link.
    try FileManager.default.createSymbolicLink(
        at: outerBundleURL.appendingPathComponent("WrappedBundle"),
        withDestinationURL: URL(
            fileURLWithPath: "Wrapper/\(innerBundleName)",
            relativeTo: outerBundleURL
        )
    )
    return outerBundleURL
}

private func application(id: String, name: String) -> InstalledApplication {
    InstalledApplication(
        id: id,
        name: name,
        bundleIdentifier: id,
        bundleURL: URL(fileURLWithPath: "/Applications/\(name).app", isDirectory: true)
    )
}
