import Foundation

/// Every user-visible name field rewritten in a refreshed companion bundle.
/// Keeping these values explicit prevents an old InfoPlist.strings entry from
/// overriding a new top-level Info.plist name after the next scan.
struct WeChatCompanionNamingMetadata: Equatable, Sendable {
    let bundleDisplayName: String
    let bundleName: String
    let localizedBundleDisplayName: String
    let localizedBundleName: String

    init(displayName: String) {
        bundleDisplayName = displayName
        bundleName = displayName
        localizedBundleDisplayName = displayName
        localizedBundleName = displayName
    }

    init(
        bundleDisplayName: String,
        bundleName: String,
        localizedBundleDisplayName: String,
        localizedBundleName: String
    ) {
        self.bundleDisplayName = bundleDisplayName
        self.bundleName = bundleName
        self.localizedBundleDisplayName = localizedBundleDisplayName
        self.localizedBundleName = localizedBundleName
    }

    var isComplete: Bool {
        [
            bundleDisplayName,
            bundleName,
            localizedBundleDisplayName,
            localizedBundleName,
        ].allSatisfy {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }
}

struct WeChatCompanionRefreshInput: Equatable, Sendable {
    let primaryBundleURL: URL
    /// The currently usable companion. It may have a legacy filename different
    /// from `destinationBundleURL`, but remains untouched until commit.
    let existingCompanionURL: URL?
    let stagingBundleURL: URL
    let destinationBundleURL: URL
    let expectedBundleIdentifier: String
    let namingMetadata: WeChatCompanionNamingMetadata

    init(
        primaryBundleURL: URL,
        existingCompanionURL: URL?,
        stagingBundleURL: URL,
        destinationBundleURL: URL,
        expectedBundleIdentifier: String,
        namingMetadata: WeChatCompanionNamingMetadata
    ) {
        self.primaryBundleURL = primaryBundleURL
        self.existingCompanionURL = existingCompanionURL
        self.stagingBundleURL = stagingBundleURL
        self.destinationBundleURL = destinationBundleURL
        self.expectedBundleIdentifier = expectedBundleIdentifier
        self.namingMetadata = namingMetadata
    }
}

enum WeChatCompanionRefreshPhase: Equatable, Sendable {
    case copyPrimaryToStaging(source: URL, staging: URL)
    case rewriteMetadata(
        bundleURL: URL,
        bundleIdentifier: String,
        naming: WeChatCompanionNamingMetadata
    )
    case applyIconBadge(bundleURL: URL)
    case adHocSign(bundleURL: URL)
    case verifyBundleIdentifier(bundleURL: URL, expected: String)
    case verifyCodeSignature(bundleURL: URL)
    /// One logical transaction. An executor may use a rollback rename when the
    /// old and new filenames differ, but it must either install the verified
    /// staging bundle and retire the old companion together, or restore the old
    /// companion. Deleting the old companion before this phase is forbidden.
    case commitVerifiedStaging(
        staging: URL,
        destination: URL,
        previousCompanion: URL?
    )
    case invalidateCachedIconAndRescan(applicationID: String)
}

struct WeChatCompanionRefreshPlan: Equatable, Sendable {
    let input: WeChatCompanionRefreshInput
    let phases: [WeChatCompanionRefreshPhase]

    var commitPhaseIndex: Int {
        phases.firstIndex {
            if case .commitVerifiedStaging = $0 { return true }
            return false
        } ?? phases.endIndex
    }
}

enum WeChatCompanionRefreshPlanError: Error, Equatable, Sendable {
    case invalidApplicationBundle(URL)
    case conflictingPaths(URL, URL)
    case incompleteNamingMetadata
    case emptyBundleIdentifier
    case volumeIdentifierUnavailable(URL)
    case stagingMustShareDestinationVolume
    case existingCompanionMustShareDestinationVolume
}

enum WeChatCompanionRefreshPolicy {
    typealias VolumeIdentifierProvider = (URL) -> String?

    static func makePlan(
        input: WeChatCompanionRefreshInput,
        volumeIdentifier: VolumeIdentifierProvider
    ) -> Result<WeChatCompanionRefreshPlan, WeChatCompanionRefreshPlanError> {
        let primary = canonical(input.primaryBundleURL)
        let existing = input.existingCompanionURL.map(canonical)
        let staging = canonical(input.stagingBundleURL)
        let destination = canonical(input.destinationBundleURL)

        for url in [primary, staging, destination] + (existing.map { [$0] } ?? []) {
            guard url.pathExtension.caseInsensitiveCompare("app") == .orderedSame else {
                return .failure(.invalidApplicationBundle(url))
            }
        }
        guard input.namingMetadata.isComplete else {
            return .failure(.incompleteNamingMetadata)
        }
        let bundleIdentifier = input.expectedBundleIdentifier
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !bundleIdentifier.isEmpty else {
            return .failure(.emptyBundleIdentifier)
        }

        let forbiddenStagingPeers = [primary, destination] + (existing.map { [$0] } ?? [])
        for peer in forbiddenStagingPeers where pathsOverlap(staging, peer) {
            return .failure(.conflictingPaths(staging, peer))
        }
        if pathsOverlap(primary, destination) {
            return .failure(.conflictingPaths(primary, destination))
        }

        guard let stagingVolume = volumeIdentifier(staging) else {
            return .failure(.volumeIdentifierUnavailable(staging))
        }
        guard let destinationVolume = volumeIdentifier(destination) else {
            return .failure(.volumeIdentifierUnavailable(destination))
        }
        guard stagingVolume == destinationVolume else {
            return .failure(.stagingMustShareDestinationVolume)
        }
        if let existing {
            guard let existingVolume = volumeIdentifier(existing) else {
                return .failure(.volumeIdentifierUnavailable(existing))
            }
            guard existingVolume == destinationVolume else {
                return .failure(.existingCompanionMustShareDestinationVolume)
            }
        }

        let normalizedInput = WeChatCompanionRefreshInput(
            primaryBundleURL: primary,
            existingCompanionURL: existing,
            stagingBundleURL: staging,
            destinationBundleURL: destination,
            expectedBundleIdentifier: bundleIdentifier,
            namingMetadata: input.namingMetadata
        )
        return .success(
            WeChatCompanionRefreshPlan(
                input: normalizedInput,
                phases: [
                    .copyPrimaryToStaging(source: primary, staging: staging),
                    .rewriteMetadata(
                        bundleURL: staging,
                        bundleIdentifier: bundleIdentifier,
                        naming: input.namingMetadata
                    ),
                    .applyIconBadge(bundleURL: staging),
                    .adHocSign(bundleURL: staging),
                    .verifyBundleIdentifier(
                        bundleURL: staging,
                        expected: bundleIdentifier
                    ),
                    .verifyCodeSignature(bundleURL: staging),
                    .commitVerifiedStaging(
                        staging: staging,
                        destination: destination,
                        previousCompanion: existing
                    ),
                    .invalidateCachedIconAndRescan(
                        applicationID: bundleIdentifier
                    ),
                ]
            )
        )
    }

    private static func canonical(_ url: URL) -> URL {
        url.resolvingSymlinksInPath().standardizedFileURL
    }

    private static func pathsOverlap(_ lhs: URL, _ rhs: URL) -> Bool {
        let left = lhs.path
        let right = rhs.path
        return left == right
            || left.hasPrefix(right + "/")
            || right.hasPrefix(left + "/")
    }
}

enum WeChatCompanionRefreshRecovery: Equatable, Sendable {
    /// Remove only staging artifacts. The existing companion must be unchanged.
    case discardStagingKeepingExisting
    /// The logical commit failed; restore/retain the previous companion and do
    /// not leave a partially installed destination.
    case ensurePreviousCompanionRestored
    /// The new companion is already committed. Do not roll it back merely
    /// because UI cache invalidation or a follow-up scan failed.
    case keepCommittedCompanionAndRetryRefresh
}

struct WeChatCompanionRefreshFailure: Error, Equatable, Sendable {
    let phase: WeChatCompanionRefreshPhase
    let message: String
    let recovery: WeChatCompanionRefreshRecovery
    let destinationWasCommitted: Bool
}

enum WeChatCompanionRefreshTransactionError: Error, Equatable, Sendable {
    case alreadyInProgress
    case notStarted
    case alreadyFinished
    case unexpectedPhase(
        expected: WeChatCompanionRefreshPhase,
        received: WeChatCompanionRefreshPhase
    )
}

struct WeChatCompanionRefreshTransaction: Equatable, Sendable {
    enum State: Equatable, Sendable {
        case ready
        case running(phaseIndex: Int)
        case completed
        case failed(WeChatCompanionRefreshFailure)
    }

    let plan: WeChatCompanionRefreshPlan
    private(set) var state: State = .ready

    var currentPhase: WeChatCompanionRefreshPhase? {
        guard case let .running(index) = state,
              plan.phases.indices.contains(index) else {
            return nil
        }
        return plan.phases[index]
    }

    init(plan: WeChatCompanionRefreshPlan) {
        self.plan = plan
    }

    mutating func start() -> Result<WeChatCompanionRefreshPhase, WeChatCompanionRefreshTransactionError> {
        switch state {
        case .ready:
            guard let first = plan.phases.first else {
                state = .completed
                return .failure(.alreadyFinished)
            }
            state = .running(phaseIndex: 0)
            return .success(first)
        case .running:
            return .failure(.alreadyInProgress)
        case .completed, .failed:
            return .failure(.alreadyFinished)
        }
    }

    /// Records one successful phase and returns the next phase, or nil after
    /// the final rescan/cache-invalidation phase has completed.
    mutating func complete(
        _ phase: WeChatCompanionRefreshPhase
    ) -> Result<WeChatCompanionRefreshPhase?, WeChatCompanionRefreshTransactionError> {
        guard case let .running(index) = state else {
            return .failure(state == .ready ? .notStarted : .alreadyFinished)
        }
        let expected = plan.phases[index]
        guard expected == phase else {
            return .failure(.unexpectedPhase(expected: expected, received: phase))
        }

        let nextIndex = index + 1
        guard plan.phases.indices.contains(nextIndex) else {
            state = .completed
            return .success(nil)
        }
        state = .running(phaseIndex: nextIndex)
        return .success(plan.phases[nextIndex])
    }

    @discardableResult
    mutating func fail(
        _ phase: WeChatCompanionRefreshPhase,
        message: String
    ) -> Result<WeChatCompanionRefreshFailure, WeChatCompanionRefreshTransactionError> {
        guard case let .running(index) = state else {
            return .failure(state == .ready ? .notStarted : .alreadyFinished)
        }
        let expected = plan.phases[index]
        guard expected == phase else {
            return .failure(.unexpectedPhase(expected: expected, received: phase))
        }

        let commitIndex = plan.commitPhaseIndex
        let recovery: WeChatCompanionRefreshRecovery
        let destinationWasCommitted: Bool
        if index < commitIndex {
            recovery = .discardStagingKeepingExisting
            destinationWasCommitted = false
        } else if index == commitIndex {
            recovery = .ensurePreviousCompanionRestored
            destinationWasCommitted = false
        } else {
            recovery = .keepCommittedCompanionAndRetryRefresh
            destinationWasCommitted = true
        }
        let failure = WeChatCompanionRefreshFailure(
            phase: phase,
            message: message,
            recovery: recovery,
            destinationWasCommitted: destinationWasCommitted
        )
        state = .failed(failure)
        return .success(failure)
    }
}
