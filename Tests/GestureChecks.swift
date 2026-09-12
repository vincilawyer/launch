import AppKit
import Foundation

private struct GestureCheckFailure: Error, CustomStringConvertible {
    let description: String
}

private func requireGesture(
    _ condition: @autoclosure () -> Bool,
    _ message: String
) throws {
    guard condition() else { throw GestureCheckFailure(description: message) }
}

@main
private enum GestureChecks {
    static func main() throws {
        try threeFingerSwipeNeverPaginates()
        try rawThreeFingerFramesNeverPaginate()
        try primaryButtonBlocksLocalSequenceUntilAllUp()
        try primaryButtonBlocksRawSequenceUntilAllUp()
        try primaryButtonDeliveryRaceQuarantinesRawTail()
        try cancelledPrimaryButtonSequenceRearmsLocalPaging()
        try pageWatchdogNeverCommitsAfterPointerDown()
        try smallTwoFingerSwipeTracksContinuously()
        try fastShortTwoFingerSwipeCarriesCommitVelocity()
        try pageCommitPolicyHasPredictableDistanceAndFlickRules()
        try internalCancellationPolicySettlesCommittedMotionOnly()
        try sequentialOneTwoLandingPaginates()
        try diagonalLandingJitterCanRecoverHorizontally()
        try verticalSwipeWithHorizontalLandingWobbleNeverMoves()
        try ambiguousDiagonalSwipeNeverBeginsPaging()
        try rapidIndependentSequencesAreNotThrottled()
        try transientRawContactDropoutDoesNotCancel()
        try droppedFingerEndingKeepsLastReliableProgress()
        try rawLiftTailCannotUndoVisibleTwoFingerMotion()
        try committedIdentityChurnSettlesUsingReliableMotion()
        try committedSpanTailSettlesUsingReliableMotion()
        try thirdFingerStillCancelsCommittedMotion()
        try rawOwnerSurvivesCompetingLocalCancelAndLiftTail()
        try rawOwnerQuarantinesTheDelayedLocalTail()
        try missingRawAllUpDoesNotPoisonNextSequence()
        try rawMotionFramesAreCoalescedWithoutLosingBoundaries()
        try shortRawGestureBoundariesAreNotCoalesced()
        try silentRawBridgeCannotDisableLocalPaging()
        try duplicateRawAndLocalSequencesDeliverOnlyOneSource()
        try rawGraceWinsBeforeLocalSystemCancellation()
        try stalledSourceReleasesForTheNextSequence()
        try thirdFingerBlocksTheWholeSequence()
        try twoFingerPinchDoesNotPaginate()
        try twoFingerVerticalSwipeDoesNotPaginate()
        try directThreeFingerTailDoesNotPaginate()
        try replacingOneOfTwoIdentitiesBlocksTheSequence()
        try rawByteBufferUsesTheVerifiedIdentifierOffset()
        try rawContactDecoderFiltersGhostContacts()
        try uncertainRawFrameDoesNotEndGesture()
        try rawContactDecoderRejectsDuplicateFingerIDs()
        try malformedRawFrameBlocksUntilAllContactsLeave()
        try fiveFingerPinchRequiresFiveStableContacts()
        try fiveFingerPinchSurvivesOneDroppedContactFrame()
        try partiallyContractedFiveFingerBaselineStillTriggers()
        try fiveFingerPinchUsesPreLandingPairHistory()
        try fiveFingerPinchRearmsAfterAllUp()
        try publicFiveFingerFallbackRequiresExactFive()
        try publicUnavailableCountFallbackActivatesWithoutRawHealth()
        try publicUnavailableCountFallbackRejectsTwoFingerSequence()
        try rawFiveFingerHealthExpires()
        try rawPinchOwnershipCannotBeCancelledByPublicTail()
        try recognizedPinchRequestsImmediatePresentation()
        try deferredPinchActivatesOnceAfterRelease()
        try deferredPinchFallsBackAfterMissingAllUp()
        try deferredPinchCancellationPreventsLateActivation()
        try inactiveGestureEndsWithLatestMotion()
        try inactiveGestureCancelsWhenInteractivityIsLost()
        try inactivityTrackerRejectsStaleSequences()
        print("Launch gesture checks passed (58/58)")
    }

    private static func threeFingerSwipeNeverPaginates() throws {
        var pager = LocalTouchPager()
        let start = samples([
            (1, 0.72, 0.50), (2, 0.52, 0.48), (3, 0.62, 0.68),
        ])
        let moved = samples([
            (1, 0.66, 0.50), (2, 0.46, 0.48), (3, 0.56, 0.68),
        ])
        let trailingTwo = samples([(1, 0.42, 0.50), (2, 0.22, 0.48)])
        let beganEvents = pager.consume(start, phase: .began, timestamp: 1.00)
        let movedEvents = pager.consume(moved, phase: .changed, timestamp: 1.07)
        let fartherEvents = pager.consume(trailingTwo, phase: .changed, timestamp: 1.10)
        let endedEvents = pager.consume([], phase: .ended, timestamp: 1.11)
        try requireGesture(
            beganEvents.isEmpty
                && movedEvents.isEmpty
                && fartherEvents.isEmpty
                && endedEvents.isEmpty,
            "A three-finger sequence or its two-finger tail emitted a page gesture"
        )
    }

    private static func rawThreeFingerFramesNeverPaginate() throws {
        var reducer = RawGestureFrameReducer()
        let start = rawContacts([
            (1, 0.72, 0.50), (2, 0.52, 0.48), (3, 0.62, 0.68),
        ])
        let moved = rawContacts([
            (1, 0.42, 0.50), (2, 0.22, 0.48), (3, 0.32, 0.68),
        ])
        let trailingTwo = rawContacts([(1, 0.38, 0.50), (2, 0.18, 0.48)])
        try requireGesture(
            reducer.consume(contacts: start, timestamp: 1.20) == nil
                && reducer.consume(contacts: moved, timestamp: 1.24) == nil
                && reducer.consume(contacts: trailingTwo, timestamp: 1.245) == nil
                && reducer.consume(contacts: [], timestamp: 1.25) == nil,
            "Raw three-finger input or its tail reached the page gesture delivery path"
        )
    }

    private static func primaryButtonBlocksLocalSequenceUntilAllUp() throws {
        var pager = LocalTouchPager()
        var latch = PrimaryButtonTouchSequenceLatch()
        let start = samples([(1, 0.72, 0.48), (2, 0.52, 0.50)])
        let moved = samples([(1, 0.66, 0.48), (2, 0.46, 0.50)])
        let farther = samples([(1, 0.60, 0.48), (2, 0.40, 0.50)])

        try requireGesture(
            pager.consume(
                start,
                phase: .began,
                timestamp: 1.30,
                blocksPageGesture: latch.blocksPageGesture(
                    touchCount: start.count,
                    primaryButtonIsDown: true
                )
            ).isEmpty,
            "Primary-button contact unexpectedly began local paging"
        )
        // UI delivery may be cancelled for unrelated lifecycle reasons while
        // the physical drag and contacts remain. The independent latch must
        // still protect the residual fingers after this reducer reset.
        pager.reset()
        try requireGesture(
            pager.consume(
                moved,
                phase: .changed,
                timestamp: 1.36,
                blocksPageGesture: latch.blocksPageGesture(
                    touchCount: moved.count,
                    primaryButtonIsDown: false
                )
            ).isEmpty,
            "Mouse-up rearmed residual local contacts before all-up"
        )
        _ = pager.consume(
            [],
            phase: .ended,
            timestamp: 1.38,
            blocksPageGesture: latch.blocksPageGesture(
                touchCount: 0,
                primaryButtonIsDown: false
            )
        )
        _ = pager.consume(start, phase: .began, timestamp: 1.50)
        try requireGesture(
            pager.consume(farther, phase: .changed, timestamp: 1.56)
                .first?.phase == .began,
            "All-up did not rearm a later normal two-finger local swipe"
        )
    }

    private static func primaryButtonBlocksRawSequenceUntilAllUp() throws {
        var reducer = RawGestureFrameReducer()
        let start = rawContacts([(1, 0.72, 0.48), (2, 0.52, 0.50)])
        let moved = rawContacts([(1, 0.62, 0.48), (2, 0.42, 0.50)])

        try requireGesture(
            reducer.consume(
                contacts: start,
                timestamp: 1.60,
                blocksPageGesture: true
            ) == nil
                && reducer.consume(
                    contacts: moved,
                    timestamp: 1.66,
                    blocksPageGesture: false
                ) == nil,
            "Raw residual contacts escaped the primary-button sequence lock"
        )
        _ = reducer.consume(contacts: [], timestamp: 1.68)
        _ = reducer.consume(contacts: start, timestamp: 1.80)
        try requireGesture(
            reducer.consume(contacts: moved, timestamp: 1.86)?
                .pageEvents.first?.phase == .began,
            "All-up did not rearm a later normal two-finger raw swipe"
        )
    }

    private static func primaryButtonDeliveryRaceQuarantinesRawTail() throws {
        var quarantine = PrimaryButtonPageDeliveryQuarantine()
        quarantine.beginPhysicalSequence()
        let began = quarantine.filter(
            [rawPageAction(phase: .began, progress: -0.08).pageEvents[0]],
            primaryButtonIsDown: false
        )
        let changed = quarantine.filter(
            [rawPageAction(phase: .changed, progress: -0.40).pageEvents[0]],
            primaryButtonIsDown: false
        )
        let ended = quarantine.filter(
            [rawPageAction(phase: .ended, progress: -0.40).pageEvents[0]],
            primaryButtonIsDown: false
        )
        let next = quarantine.filter(
            [rawPageAction(phase: .began, progress: 0.10).pageEvents[0]],
            primaryButtonIsDown: false
        )
        try requireGesture(
            began.didSuppress && began.acceptedEvents.isEmpty
                && changed.didSuppress && changed.acceptedEvents.isEmpty
                && ended.didSuppress && ended.acceptedEvents.isEmpty
                && !quarantine.isActive
                && !next.didSuppress && next.acceptedEvents.count == 1,
            "A queued raw begin or its tail escaped primary-button delivery quarantine"
        )
    }

    private static func cancelledPrimaryButtonSequenceRearmsLocalPaging() throws {
        var latch = PrimaryButtonTouchSequenceLatch()
        try requireGesture(
            latch.blocksPageGesture(
                touchCount: 2,
                primaryButtonIsDown: true,
                phase: .began
            ),
            "A primary-button touch sequence did not engage its local latch"
        )
        try requireGesture(
            latch.blocksPageGesture(
                touchCount: 2,
                primaryButtonIsDown: false,
                phase: .cancelled
            ) && !latch.isActive,
            "A nonempty AppKit cancellation permanently poisoned the local latch"
        )
        try requireGesture(
            !latch.blocksPageGesture(
                touchCount: 2,
                primaryButtonIsDown: false,
                phase: .began
            ),
            "A fresh sequence remained blocked after an authoritative cancellation"
        )
    }

    private static func pageWatchdogNeverCommitsAfterPointerDown() throws {
        try requireGesture(
            PageGestureWatchdogTerminalPolicy.terminalPhase(
                isInteractive: true,
                primaryButtonIsDown: false,
                primaryButtonSequenceIsLatched: false
            ) == .ended,
            "An ordinary inactive page gesture no longer settles normally"
        )
        try requireGesture(
            PageGestureWatchdogTerminalPolicy.terminalPhase(
                isInteractive: true,
                primaryButtonIsDown: true,
                primaryButtonSequenceIsLatched: false
            ) == .cancelled,
            "A mouse-down without a later touch frame let the watchdog commit"
        )
        try requireGesture(
            PageGestureWatchdogTerminalPolicy.terminalPhase(
                isInteractive: true,
                primaryButtonIsDown: false,
                primaryButtonSequenceIsLatched: true
            ) == .cancelled,
            "Mouse-up rearmed a latched physical drag before all-up"
        )
    }

    private static func smallTwoFingerSwipeTracksContinuously() throws {
        var pager = LocalTouchPager()
        let start = samples([(1, 0.72, 0.48), (2, 0.52, 0.50)])
        let finish = samples([(1, 0.66, 0.48), (2, 0.46, 0.50)])
        _ = pager.consume(start, phase: .began, timestamp: 2.00)
        let began = pager.consume(finish, phase: .changed, timestamp: 2.04)
        try requireGesture(
            began.count == 1
                && began[0].phase == .began
                && began[0].touchCount == 2
                && began[0].progress < 0,
            "A small stable two-finger left swipe did not begin paging"
        )
        let trailingOne = samples([(1, 0.40, 0.48)])
        let ended = pager.consume(trailingOne, phase: .ended, timestamp: 2.12)
        try requireGesture(
            ended.last?.phase == .ended
                && ended.last?.sequenceID == began[0].sequenceID,
            "The two-finger gesture did not end before its one-finger tail"
        )
        let replacementTwo = samples([(1, 0.34, 0.48), (4, 0.14, 0.50)])
        try requireGesture(
            pager.consume(replacementTwo, phase: .changed, timestamp: 2.18).isEmpty,
            "A replacement second finger rearmed the same physical sequence"
        )
    }

    private static func fastShortTwoFingerSwipeCarriesCommitVelocity() throws {
        var pager = LocalTouchPager()
        let start = samples([(1, 0.72, 0.48), (2, 0.52, 0.50)])
        let firstFastFrame = samples([(1, 0.709, 0.48), (2, 0.509, 0.50)])
        let secondFastFrame = samples([(1, 0.704, 0.48), (2, 0.504, 0.50)])
        _ = pager.consume(start, phase: .began, timestamp: 2.20)
        let first = pager.consume(
            firstFastFrame,
            phase: .changed,
            timestamp: 2.222
        )
        let began = pager.consume(
            secondFastFrame,
            phase: .changed,
            timestamp: 2.226
        )
        let ended = pager.consume([], phase: .ended, timestamp: 2.228)
        let predictedProgress = (ended.first?.progress ?? 0)
            + (ended.first?.velocity ?? 0) * 0.18
        try requireGesture(
            first.isEmpty
                && began.first?.phase == .began
                && began.first?.touchCount == 2
                && abs(began.first?.velocity ?? 0) >= 1
                && ended.first?.phase == .ended
                && ended.first?.sequenceID == began.first?.sequenceID
                && predictedProgress < -0.22,
            "A fast short exact-two swipe lacked enough velocity to commit a page"
        )
    }

    private static func pageCommitPolicyHasPredictableDistanceAndFlickRules() throws {
        let distanceCommit = TrackpadPageCommitPolicy.predictedTranslation(
            progress: -0.24,
            velocity: 1.8
        )
        let deliberateFlick = TrackpadPageCommitPolicy.predictedTranslation(
            progress: -0.10,
            velocity: -1.0
        )
        let tooShort = TrackpadPageCommitPolicy.predictedTranslation(
            progress: -0.04,
            velocity: -8
        )
        let tooSlow = TrackpadPageCommitPolicy.predictedTranslation(
            progress: -0.18,
            velocity: -0.3
        )
        let reverseLift = TrackpadPageCommitPolicy.predictedTranslation(
            progress: -0.18,
            velocity: 2
        )
        try requireGesture(
            distanceCommit == -0.24
                && deliberateFlick <= -TrackpadPageCommitPolicy.distanceThreshold
                && tooShort == -0.04
                && tooSlow == -0.18
                && reverseLift == -0.18,
            "Page release did not follow the documented distance/same-direction flick rules"
        )
    }

    private static func internalCancellationPolicySettlesCommittedMotionOnly() throws {
        let reliable = pageEvent(
            sequenceID: 31,
            phase: .changed,
            touchCount: 2,
            progress: 0.53,
            velocity: 6.2
        )
        let systemCancelled = pageEvent(
            sequenceID: 31,
            phase: .cancelled,
            touchCount: 2,
            progress: 0.53,
            velocity: 6.2
        )
        let tooManyCancelled = TrackpadPageGestureEvent(
            sequenceID: 31,
            phase: .cancelled,
            touchCount: 2,
            progress: 0.53,
            velocity: 6.2,
            blockReason: .tooManyTouches
        )
        let pointerCancelled = TrackpadPageGestureEvent(
            sequenceID: 31,
            phase: .cancelled,
            touchCount: 2,
            progress: 0.53,
            velocity: 6.2,
            blockReason: .primaryPointerButtonDown
        )
        let rawOwner = TrackpadPageInputIdentity(source: .raw, sequenceID: 31)
        let localOwner = TrackpadPageInputIdentity(source: .local, sequenceID: 31)

        let rawSettled = TrackpadPageTerminalPolicy.normalized(
            event: systemCancelled,
            source: .raw,
            activeIdentity: rawOwner,
            reliableEvent: reliable,
            isInteractive: true
        )
        let localSettled = TrackpadPageTerminalPolicy.normalized(
            event: systemCancelled,
            source: .local,
            activeIdentity: localOwner,
            reliableEvent: reliable,
            isInteractive: true
        )
        let fourStayedCancelled = TrackpadPageTerminalPolicy.normalized(
            event: tooManyCancelled,
            source: .raw,
            activeIdentity: rawOwner,
            reliableEvent: reliable,
            isInteractive: true
        )
        let pointerStayedCancelled = TrackpadPageTerminalPolicy.normalized(
            event: pointerCancelled,
            source: .raw,
            activeIdentity: rawOwner,
            reliableEvent: reliable,
            isInteractive: true
        )
        let lifecycleStayedCancelled = TrackpadPageTerminalPolicy.normalized(
            event: systemCancelled,
            source: .raw,
            activeIdentity: rawOwner,
            reliableEvent: reliable,
            isInteractive: false
        )
        try requireGesture(
            rawSettled.phase == .ended
                && localSettled.phase == .ended
                && rawSettled.progress == reliable.progress
                && fourStayedCancelled.phase == .cancelled
                && pointerStayedCancelled.phase == .cancelled
                && lifecycleStayedCancelled.phase == .cancelled,
            "Internal cancellation policy confused lift cancellation with three-finger/lifecycle cancellation"
        )
    }

    private static func sequentialOneTwoLandingPaginates() throws {
        var pager = LocalTouchPager()
        let one = samples([(1, 0.72, 0.50)])
        let two = samples([(1, 0.72, 0.50), (2, 0.52, 0.48)])
        let movedTwo = samples([(1, 0.66, 0.50), (2, 0.46, 0.48)])
        try requireGesture(
            pager.consume(one, phase: .began, timestamp: 2.40).isEmpty
                && pager.consume(two, phase: .changed, timestamp: 2.41).isEmpty,
            "One/two landing fingers unexpectedly began paging"
        )
        let began = pager.consume(
            movedTwo,
            phase: .changed,
            timestamp: 2.44,
            toleratesTransientDropout: true
        )
        try requireGesture(
            began.first?.phase == .began
                && began.first?.touchCount == 2,
            "A sequential one-to-two landing did not begin exact-two paging"
        )
    }

    private static func diagonalLandingJitterCanRecoverHorizontally() throws {
        var pager = LocalTouchPager()
        let start = samples([(1, 0.72, 0.48), (2, 0.52, 0.50)])
        let diagonalJitter = samples([(1, 0.708, 0.492), (2, 0.508, 0.512)])
        let horizontal = samples([(1, 0.66, 0.492), (2, 0.46, 0.512)])
        _ = pager.consume(start, phase: .began, timestamp: 2.70)
        try requireGesture(
            pager.consume(diagonalJitter, phase: .changed, timestamp: 2.73).isEmpty,
            "Small diagonal landing jitter unexpectedly began paging"
        )
        try requireGesture(
            pager.consume(horizontal, phase: .changed, timestamp: 2.76)
                .first?.phase == .began,
            "Small diagonal landing jitter permanently blocked a later horizontal swipe"
        )
    }

    private static func verticalSwipeWithHorizontalLandingWobbleNeverMoves() throws {
        var pager = LocalTouchPager()
        let start = samples([(1, 0.72, 0.42), (2, 0.52, 0.44)])
        let horizontalWobble = samples([(1, 0.708, 0.42), (2, 0.508, 0.44)])
        let vertical = samples([(1, 0.707, 0.50), (2, 0.507, 0.52)])
        let laterHorizontalTail = samples([(1, 0.55, 0.50), (2, 0.35, 0.52)])
        _ = pager.consume(start, phase: .began, timestamp: 2.80)
        let wobble = pager.consume(
            horizontalWobble,
            phase: .changed,
            timestamp: 2.82
        )
        let upward = pager.consume(vertical, phase: .changed, timestamp: 2.85)
        let tail = pager.consume(
            laterHorizontalTail,
            phase: .changed,
            timestamp: 2.90
        )
        try requireGesture(
            wobble.isEmpty && upward.isEmpty && tail.isEmpty,
            "A vertical swipe moved the page after horizontal landing wobble"
        )
    }

    private static func ambiguousDiagonalSwipeNeverBeginsPaging() throws {
        var pager = LocalTouchPager()
        let start = samples([(1, 0.72, 0.42), (2, 0.52, 0.44)])
        let firstDiagonal = samples([(1, 0.70, 0.437), (2, 0.50, 0.457)])
        let fartherDiagonal = samples([(1, 0.685, 0.45), (2, 0.485, 0.47)])
        _ = pager.consume(start, phase: .began, timestamp: 2.95)
        try requireGesture(
            pager.consume(firstDiagonal, phase: .changed, timestamp: 2.98).isEmpty
                && pager.consume(
                    fartherDiagonal,
                    phase: .changed,
                    timestamp: 3.02
                ).isEmpty
                && pager.consume([], phase: .ended, timestamp: 3.04).isEmpty,
            "An ambiguous non-horizontal diagonal swipe moved or committed a page"
        )
    }

    private static func rapidIndependentSequencesAreNotThrottled() throws {
        var pager = LocalTouchPager()
        func runSequence(
            ids: (Int, Int),
            startTime: TimeInterval
        ) -> UInt64? {
            let start = samples([(ids.0, 0.70, 0.48), (ids.1, 0.50, 0.50)])
            let moved = samples([(ids.0, 0.64, 0.48), (ids.1, 0.44, 0.50)])
            _ = pager.consume(start, phase: .began, timestamp: startTime)
            let events = pager.consume(
                moved,
                phase: .changed,
                timestamp: startTime + 0.07
            )
            _ = pager.consume([], phase: .ended, timestamp: startTime + 0.08)
            return events.first?.sequenceID
        }

        let first = runSequence(ids: (1, 2), startTime: 10.00)
        let second = runSequence(ids: (4, 5), startTime: 10.14)
        try requireGesture(
            first != nil && second != nil && first != second,
            "A second independent swipe inside the former 0.32-second throttle was lost"
        )
    }

    private static func transientRawContactDropoutDoesNotCancel() throws {
        var pager = LocalTouchPager()
        let start = samples([(1, 0.72, 0.48), (2, 0.52, 0.50)])
        let moved = samples([(1, 0.66, 0.48), (2, 0.46, 0.50)])
        _ = pager.consume(
            start,
            phase: .changed,
            timestamp: 20.00,
            toleratesTransientDropout: true
        )
        let began = pager.consume(
            moved,
            phase: .changed,
            timestamp: 20.04,
            toleratesTransientDropout: true
        )
        let partial = Array(moved.prefix(1))
        let partialEvents = pager.consume(
            partial,
            phase: .changed,
            timestamp: 20.05,
            toleratesTransientDropout: true
        )
        try requireGesture(
            !partialEvents.contains { $0.phase == .ended || $0.phase == .cancelled },
            "One transient low-capacitance contact emitted a terminal event"
        )
        let restored = samples([(1, 0.63, 0.48), (2, 0.43, 0.50)])
        let changed = pager.consume(
            restored,
            phase: .changed,
            timestamp: 20.07,
            toleratesTransientDropout: true
        )
        try requireGesture(
            began.first?.phase == .began
                && changed.first?.phase == .changed
                && changed.first?.sequenceID == began.first?.sequenceID,
            "A one-frame raw contact dropout permanently blocked the gesture"
        )
    }

    private static func droppedFingerEndingKeepsLastReliableProgress() throws {
        var pager = LocalTouchPager()
        let start = samples([(1, 0.72, 0.48), (2, 0.52, 0.50)])
        let beganMotion = samples([(1, 0.68, 0.48), (2, 0.48, 0.50)])
        _ = pager.consume(
            start,
            phase: .changed,
            timestamp: 21.00,
            toleratesTransientDropout: true
        )
        let began = pager.consume(
            beganMotion,
            phase: .changed,
            timestamp: 21.03,
            toleratesTransientDropout: true
        )
        let reliableMotion = samples([(1, 0.64, 0.48), (2, 0.44, 0.50)])
        let changed = pager.consume(
            reliableMotion,
            phase: .changed,
            timestamp: 21.04,
            toleratesTransientDropout: true
        )
        // At lift-off the one contact that happens to remain can report much
        // smaller deltas than the complete two-finger frame. This used to
        // overwrite the visibly completed motion and make the page rebound.
        let finalPartial = samples([(1, 0.715, 0.48)])
        let partial = pager.consume(
            finalPartial,
            phase: .changed,
            timestamp: 21.05,
            toleratesTransientDropout: true
        )
        let ended = pager.consume(
            [],
            phase: .ended,
            timestamp: 21.06,
            toleratesTransientDropout: true
        )
        try requireGesture(
            began.first?.phase == .began
                && changed.first?.phase == .changed
                && (changed.first?.progress ?? 0) < -0.40
                && partial.isEmpty
                && ended.first?.phase == .ended
                && ended.first?.progress == changed.first?.progress
                && ended.first?.velocity == changed.first?.velocity,
            "An uneven one-finger lift tail overwrote reliable exact-two motion"
        )
    }

    private static func rawLiftTailCannotUndoVisibleTwoFingerMotion() throws {
        var reducer = RawGestureFrameReducer()
        let start = rawContacts([(1, 0.72, 0.48), (2, 0.52, 0.50)])
        let beganMotion = rawContacts([(1, 0.68, 0.48), (2, 0.48, 0.50)])
        let visibleMotion = rawContacts([(1, 0.64, 0.48), (2, 0.44, 0.50)])
        let unevenOneFingerTail = rawContacts([(1, 0.715, 0.48)])

        _ = reducer.consume(contacts: start, timestamp: 22.00)
        let began = reducer.consume(contacts: beganMotion, timestamp: 22.03)
        let changed = reducer.consume(contacts: visibleMotion, timestamp: 22.04)
        let tail = reducer.consume(contacts: unevenOneFingerTail, timestamp: 22.05)
        let ended = reducer.consume(contacts: [], timestamp: 22.06)

        let reliableEvent = changed?.pageEvents.first
        let terminalEvent = ended?.pageEvents.first
        try requireGesture(
            began?.pageEvents.first?.phase == .began
                && reliableEvent?.phase == .changed
                && (reliableEvent?.progress ?? 0) < -0.40
                && tail == nil
                && terminalEvent?.phase == .ended
                && terminalEvent?.progress == reliableEvent?.progress
                && terminalEvent?.velocity == reliableEvent?.velocity,
            "The raw one-finger lift tail shrank a visibly completed two-finger swipe"
        )
    }

    private static func committedIdentityChurnSettlesUsingReliableMotion() throws {
        var pager = LocalTouchPager()
        let start = samples([(1, 0.72, 0.48), (2, 0.52, 0.50)])
        let beganMotion = samples([(1, 0.66, 0.48), (2, 0.46, 0.50)])
        let committedMotion = samples([(1, 0.625, 0.48), (2, 0.425, 0.50)])
        let identityChurn = samples([(1, 0.62, 0.48), (9, 0.42, 0.50)])

        _ = pager.consume(start, phase: .began, timestamp: 23.00)
        let began = pager.consume(beganMotion, phase: .changed, timestamp: 23.04)
        let changed = pager.consume(
            committedMotion,
            phase: .changed,
            timestamp: 23.06
        )
        let quarantined = pager.consume(
            identityChurn,
            phase: .changed,
            timestamp: 23.07
        )
        let terminal = pager.consume([], phase: .ended, timestamp: 23.08)
        try requireGesture(
            began.first?.phase == .began
                && changed.first?.phase == .changed
                && abs(changed.first?.progress ?? 0)
                    >= TrackpadPageCommitPolicy.distanceThreshold
                && quarantined.isEmpty
                && terminal.first?.phase == .ended
                && terminal.first?.progress == changed.first?.progress
                && terminal.first?.velocity == changed.first?.velocity,
            "Committed exact-two motion was cancelled by lift-time identity churn"
        )
    }

    private static func committedSpanTailSettlesUsingReliableMotion() throws {
        var pager = LocalTouchPager()
        let start = samples([(1, 0.72, 0.48), (2, 0.52, 0.50)])
        let beganMotion = samples([(1, 0.66, 0.48), (2, 0.46, 0.50)])
        let committedMotion = samples([(1, 0.625, 0.48), (2, 0.425, 0.50)])
        // Both records still look active for one lift frame, but their
        // span is no longer comparable with the reliable translation sample.
        let distortedLiftFrame = samples([(1, 0.36, 0.30), (2, 0.68, 0.72)])

        _ = pager.consume(start, phase: .began, timestamp: 23.20)
        _ = pager.consume(beganMotion, phase: .changed, timestamp: 23.24)
        let changed = pager.consume(
            committedMotion,
            phase: .changed,
            timestamp: 23.26
        )
        let quarantined = pager.consume(
            distortedLiftFrame,
            phase: .changed,
            timestamp: 23.27
        )
        let terminal = pager.consume([], phase: .ended, timestamp: 23.28)
        try requireGesture(
            changed.first?.phase == .changed
                && quarantined.isEmpty
                && terminal.first?.phase == .ended
                && terminal.first?.progress == changed.first?.progress
                && terminal.first?.velocity == changed.first?.velocity,
            "Committed exact-two motion was cancelled by a distorted lift frame"
        )
    }

    private static func thirdFingerStillCancelsCommittedMotion() throws {
        var pager = LocalTouchPager()
        let start = samples([(1, 0.72, 0.48), (2, 0.52, 0.50)])
        let committed = samples([(1, 0.62, 0.48), (2, 0.42, 0.50)])
        let three = samples([
            (1, 0.61, 0.48), (2, 0.41, 0.50), (3, 0.51, 0.68),
        ])
        _ = pager.consume(start, phase: .began, timestamp: 23.40)
        let began = pager.consume(committed, phase: .changed, timestamp: 23.44)
        let terminal = pager.consume(three, phase: .changed, timestamp: 23.45)
        try requireGesture(
            abs(began.first?.progress ?? 0)
                >= TrackpadPageCommitPolicy.distanceThreshold
                && terminal.first?.phase == .cancelled,
            "A third finger committed an already-moving page instead of blocking it"
        )
    }

    private static func rawOwnerSurvivesCompetingLocalCancelAndLiftTail() throws {
        var rawReducer = RawGestureFrameReducer()
        var localPager = LocalTouchPager()
        var arbiter = TrackpadPageSourceArbiter()

        let rawStart = rawContacts([(1, 0.72, 0.48), (2, 0.52, 0.50)])
        let rawBeganMotion = rawContacts([(1, 0.66, 0.48), (2, 0.46, 0.50)])
        let rawCommittedMotion = rawContacts([(1, 0.625, 0.48), (2, 0.425, 0.50)])
        _ = rawReducer.consume(contacts: rawStart, timestamp: 23.60)
        let rawBegan = rawReducer.consume(
            contacts: rawBeganMotion,
            timestamp: 23.64
        )?.pageEvents.first
        let rawChanged = rawReducer.consume(
            contacts: rawCommittedMotion,
            timestamp: 23.66
        )?.pageEvents.first

        let localStart = samples([(11, 0.72, 0.48), (12, 0.52, 0.50)])
        let localMoved = samples([(11, 0.66, 0.48), (12, 0.46, 0.50)])
        _ = localPager.consume(localStart, phase: .began, timestamp: 23.61)
        let localBegan = localPager.consume(
            localMoved,
            phase: .changed,
            timestamp: 23.65
        ).first
        let localCancelled = localPager.consume(
            [],
            phase: .cancelled,
            timestamp: 23.67
        ).first

        guard let rawBegan, let rawChanged, let localBegan, let localCancelled else {
            throw GestureCheckFailure(
                description: "The raw/local cancellation reproduction did not establish both sources"
            )
        }
        let acceptedRaw = arbiter.accepts(rawBegan, from: .raw)
            && arbiter.accepts(rawChanged, from: .raw)
        let rejectedLocal = !arbiter.accepts(localBegan, from: .local)
            && !arbiter.accepts(localCancelled, from: .local)

        let rawIdentityChurn = rawContacts([(1, 0.62, 0.48), (9, 0.42, 0.50)])
        let quarantined = rawReducer.consume(
            contacts: rawIdentityChurn,
            timestamp: 23.675
        )
        let rawOne = Array(rawCommittedMotion.prefix(1))
        let oneTail = rawReducer.consume(contacts: rawOne, timestamp: 23.68)
        let rawTerminal = rawReducer.consume(
            contacts: [],
            timestamp: 23.70
        )?.pageEvents.first
        try requireGesture(
            acceptedRaw
                && rejectedLocal
                && quarantined == nil
                && oneTail == nil
                && rawTerminal?.phase == .ended
                && rawTerminal?.progress == rawChanged.progress
                && arbiter.accepts(rawTerminal!, from: .raw)
                && arbiter.activeIdentity == nil,
            "A competing local cancellation or two-to-one tail cancelled the raw-owned page"
        )
    }

    private static func rawOwnerQuarantinesTheDelayedLocalTail() throws {
        var quarantine = RawOwnedLocalPageQuarantine()
        quarantine.rawSequenceBegan()
        let concurrentLocalTwo = quarantine.suppressesLocalFrame(touchCount: 2)
        quarantine.rawSequenceEnded(currentLocalTouchCount: 2)
        let delayedLocalTwo = quarantine.suppressesLocalFrame(touchCount: 2)
        let delayedLocalAllUp = quarantine.suppressesLocalFrame(touchCount: 0)
        let nextPhysicalSequence = quarantine.suppressesLocalFrame(touchCount: 2)
        try requireGesture(
            concurrentLocalTwo
                && delayedLocalTwo
                && delayedLocalAllUp
                && !nextPhysicalSequence
                && !quarantine.isActive,
            "The delayed AppKit tail escaped raw ownership or poisoned the next sequence"
        )
    }

    private static func missingRawAllUpDoesNotPoisonNextSequence() throws {
        var reducer = RawGestureFrameReducer()
        let firstStart = rawContacts([(1, 0.72, 0.48), (2, 0.52, 0.50)])
        let firstMoved = rawContacts([(1, 0.66, 0.48), (2, 0.46, 0.50)])
        _ = reducer.consume(contacts: firstStart, timestamp: 25.00)
        let firstBegan = reducer.consume(contacts: firstMoved, timestamp: 25.04)
        let secondStart = rawContacts([(7, 0.72, 0.48), (8, 0.52, 0.50)])
        let boundary = reducer.consume(contacts: secondStart, timestamp: 25.50)
        let secondMoved = rawContacts([(7, 0.66, 0.48), (8, 0.46, 0.50)])
        let secondBegan = reducer.consume(contacts: secondMoved, timestamp: 25.54)
        try requireGesture(
            firstBegan?.pageEvents.first?.phase == .began
                && boundary?.pageEvents.first?.phase == .cancelled
                && secondBegan?.pageEvents.first?.phase == .began,
            "A missing raw all-up frame left the next physical sequence latched out"
        )
    }

    private static func rawMotionFramesAreCoalescedWithoutLosingBoundaries() throws {
        var buffer = RawGestureActionBuffer()
        buffer.enqueue(rawPageAction(phase: .began, progress: -0.02))
        for index in 1...120 {
            buffer.enqueue(
                rawPageAction(
                    phase: .changed,
                    progress: -Double(index) / 120
                )
            )
        }
        buffer.enqueue(rawPageAction(phase: .ended, progress: -1))

        let delivered = buffer.drain()
        try requireGesture(
            delivered.count == 3
                && delivered[0].pageEvents.first?.phase == .began
                && delivered[1].pageEvents.first?.phase == .changed
                && delivered[1].pageEvents.first?.progress == -1
                && delivered[2].pageEvents.first?.phase == .ended,
            "High-frequency raw changes were not coalesced between begin/end boundaries"
        )
        try requireGesture(
            buffer.count == 0,
            "The raw action buffer retained already-delivered frames"
        )
    }

    private static func shortRawGestureBoundariesAreNotCoalesced() throws {
        var buffer = RawGestureActionBuffer()
        buffer.enqueue(rawPageAction(phase: .began, progress: -0.09))
        buffer.enqueue(rawPageAction(phase: .ended, progress: -0.09))
        let delivered = buffer.drain()
        try requireGesture(
            delivered.count == 2
                && delivered[0].pageEvents.first?.phase == .began
                && delivered[1].pageEvents.first?.phase == .ended,
            "A began-to-ended fast gesture lost a boundary during raw coalescing"
        )
    }

    private static func silentRawBridgeCannotDisableLocalPaging() throws {
        var arbiter = TrackpadPageSourceArbiter()
        let began = pageEvent(
            sequenceID: 1,
            phase: .began,
            touchCount: 2,
            progress: -0.12,
            velocity: -1
        )
        let changed = pageEvent(
            sequenceID: 1,
            phase: .changed,
            touchCount: 2,
            progress: -0.45,
            velocity: -2
        )
        let ended = pageEvent(
            sequenceID: 1,
            phase: .ended,
            touchCount: 2,
            progress: -0.45,
            velocity: -2
        )
        try requireGesture(
            arbiter.accepts(began, from: .local)
                && arbiter.accepts(changed, from: .local)
                && arbiter.accepts(ended, from: .local)
                && arbiter.activeIdentity == nil,
            "A silent-but-created raw bridge prevented a complete local page sequence"
        )
    }

    private static func duplicateRawAndLocalSequencesDeliverOnlyOneSource() throws {
        var arbiter = TrackpadPageSourceArbiter()
        let localBegan = pageEvent(
            sequenceID: 7,
            phase: .began,
            touchCount: 2,
            progress: 0.08,
            velocity: 0.8
        )
        let rawBegan = pageEvent(
            sequenceID: 91,
            phase: .began,
            touchCount: 2,
            progress: 0.09,
            velocity: 0.9
        )
        let rawCancelled = pageEvent(
            sequenceID: 91,
            phase: .cancelled,
            touchCount: 2,
            progress: 0.09,
            velocity: 0.9
        )
        let localChanged = pageEvent(
            sequenceID: 7,
            phase: .changed,
            touchCount: 2,
            progress: 0.42,
            velocity: 1.7
        )
        let localEnded = pageEvent(
            sequenceID: 7,
            phase: .ended,
            touchCount: 2,
            progress: 0.42,
            velocity: 1.7
        )
        try requireGesture(
            arbiter.accepts(localBegan, from: .local)
                && !arbiter.accepts(rawBegan, from: .raw)
                && !arbiter.accepts(rawCancelled, from: .raw)
                && arbiter.accepts(localChanged, from: .local)
                && arbiter.accepts(localEnded, from: .local)
                && arbiter.activeIdentity == nil,
            "The competing raw source duplicated or cancelled a local page sequence"
        )
    }

    private static func rawGraceWinsBeforeLocalSystemCancellation() throws {
        var pendingLocal = PendingLocalPageGestureBuffer()
        var arbiter = TrackpadPageSourceArbiter()
        let localBegan = pageEvent(
            sequenceID: 18,
            phase: .began,
            touchCount: 2,
            progress: -0.09,
            velocity: -0.8
        )
        let localChanged = pageEvent(
            sequenceID: 18,
            phase: .changed,
            touchCount: 2,
            progress: -0.20,
            velocity: -1.1
        )
        let localCancelled = pageEvent(
            sequenceID: 18,
            phase: .cancelled,
            touchCount: 2,
            progress: -0.20,
            velocity: -1.1
        )
        let rawBegan = pageEvent(
            sequenceID: 62,
            phase: .began,
            touchCount: 2,
            progress: -0.10,
            velocity: -0.9
        )
        let rawChanged = pageEvent(
            sequenceID: 62,
            phase: .changed,
            touchCount: 2,
            progress: -0.42,
            velocity: -1.8
        )
        let rawEnded = pageEvent(
            sequenceID: 62,
            phase: .ended,
            touchCount: 2,
            progress: -0.42,
            velocity: -1.8
        )

        try requireGesture(
            pendingLocal.stage(localBegan)
                && pendingLocal.stage(localChanged),
            "The local grace buffer lost its begin/change boundaries"
        )
        // Raw begins inside the grace interval, so the manager discards the
        // buffered local source before claiming raw ownership.
        pendingLocal.reset()
        try requireGesture(
            arbiter.accepts(rawBegan, from: .raw)
                && !arbiter.accepts(localCancelled, from: .local)
                && arbiter.accepts(rawChanged, from: .raw)
                && arbiter.accepts(rawEnded, from: .raw)
                && pendingLocal.isEmpty
                && arbiter.activeIdentity == nil,
            "A local system cancellation interrupted the raw-owned page sequence"
        )
    }

    private static func stalledSourceReleasesForTheNextSequence() throws {
        var arbiter = TrackpadPageSourceArbiter()
        let stalled = pageEvent(
            sequenceID: 12,
            phase: .began,
            touchCount: 2,
            progress: -0.10,
            velocity: -0.5
        )
        let next = pageEvent(
            sequenceID: 44,
            phase: .began,
            touchCount: 2,
            progress: -0.11,
            velocity: -0.7
        )
        try requireGesture(
            arbiter.accepts(stalled, from: .raw),
            "The initial raw source did not claim its page sequence"
        )
        // The manager's inactivity watchdog calls this same release operation.
        arbiter.reset()
        try requireGesture(
            arbiter.accepts(next, from: .local)
                && arbiter.activeIdentity == TrackpadPageInputIdentity(
                    source: .local,
                    sequenceID: 44
                ),
            "A stalled source prevented the next local sequence after watchdog release"
        )
    }

    private static func thirdFingerBlocksTheWholeSequence() throws {
        var pager = LocalTouchPager()
        let two = samples([(1, 0.72, 0.48), (2, 0.52, 0.50)])
        let three = samples([
            (1, 0.71, 0.48), (2, 0.51, 0.50), (3, 0.61, 0.68),
        ])
        let trailingTwo = samples([(1, 0.50, 0.48), (2, 0.30, 0.50)])
        _ = pager.consume(two, phase: .began, timestamp: 3.00)
        _ = pager.consume(three, phase: .changed, timestamp: 3.02)
        try requireGesture(
            pager.consume(trailingTwo, phase: .changed, timestamp: 3.10).isEmpty,
            "The two-finger tail of a three-finger gesture paginated"
        )
    }

    private static func twoFingerPinchDoesNotPaginate() throws {
        var pager = LocalTouchPager()
        let start = samples([(1, 0.36, 0.44), (2, 0.64, 0.44)])
        let pinch = samples([(1, 0.44, 0.48), (2, 0.56, 0.48)])
        let laterSwipe = samples([(1, 0.30, 0.48), (2, 0.42, 0.48)])
        _ = pager.consume(start, phase: .began, timestamp: 4.00)
        try requireGesture(
            pager.consume(pinch, phase: .changed, timestamp: 4.04).isEmpty,
            "A two-finger pinch was mistaken for page navigation"
        )
        try requireGesture(
            pager.consume(laterSwipe, phase: .changed, timestamp: 4.10).isEmpty,
            "A blocked pinch sequence later paginated"
        )
    }

    private static func twoFingerVerticalSwipeDoesNotPaginate() throws {
        var pager = LocalTouchPager()
        let start = samples([(1, 0.72, 0.42), (2, 0.52, 0.44)])
        let finish = samples([(1, 0.74, 0.52), (2, 0.54, 0.54)])
        _ = pager.consume(start, phase: .began, timestamp: 5.00)
        try requireGesture(
            pager.consume(finish, phase: .changed, timestamp: 5.04).isEmpty,
            "A predominantly vertical two-finger swipe paginated"
        )
    }

    private static func directThreeFingerTailDoesNotPaginate() throws {
        var pager = LocalTouchPager()
        let three = samples([
            (1, 0.72, 0.48), (2, 0.52, 0.50), (3, 0.62, 0.68),
        ])
        let trailingTwo = samples([(1, 0.50, 0.48), (2, 0.30, 0.50)])
        _ = pager.consume(three, phase: .began, timestamp: 5.50)
        try requireGesture(
            pager.consume(trailingTwo, phase: .changed, timestamp: 5.58).isEmpty,
            "A direct three-finger sequence rearmed on its two-finger tail"
        )
    }

    private static func replacingOneOfTwoIdentitiesBlocksTheSequence() throws {
        var pager = LocalTouchPager()
        let original = samples([(1, 0.72, 0.48), (2, 0.52, 0.50)])
        let replacement = samples([(1, 0.52, 0.48), (4, 0.32, 0.50)])
        _ = pager.consume(original, phase: .began, timestamp: 5.70)
        try requireGesture(
            pager.consume(replacement, phase: .changed, timestamp: 5.78).isEmpty,
            "Replacing one identity inside an exact-two frame paginated"
        )
    }

    private static func rawByteBufferUsesTheVerifiedIdentifierOffset() throws {
        var bytes = [UInt8](repeating: 0, count: 96 * 3)
        let identifiers: [Int32] = [101, 202, 303]
        let positions: [(Float, Float)] = [(0.25, 0.40), (0.50, 0.45), (0.75, 0.42)]

        func write<T>(_ value: T, record: Int, offset: Int) {
            withUnsafeBytes(of: value) { source in
                bytes.replaceSubrange(
                    (record * 96 + offset)..<(record * 96 + offset + source.count),
                    with: source
                )
            }
        }

        for index in 0..<3 {
            write(identifiers[index], record: index, offset: 0x10)
            write(UInt32(4), record: index, offset: 0x14)
            // Deliberately identical across all records. The old decoder read
            // this reserved field as the ID and rejected every real multi-touch
            // frame as having duplicate fingers.
            write(Int32(0), record: index, offset: 0x18)
            write(positions[index].0, record: index, offset: 0x20)
            write(positions[index].1, record: index, offset: 0x24)
            write(Float(0.5), record: index, offset: 0x30)
        }

        let decoded = bytes.withUnsafeBytes { buffer in
            RawTouchContactDecoder.decodeFrame(
                rawTouches: buffer.baseAddress,
                count: 3
            )
        }
        try requireGesture(
            decoded?.contacts.map(\.id) == identifiers
                && decoded?.contacts.count == 3,
            "The 9450.2 byte decoder did not read contact identifiers from +0x10"
        )

        write(identifiers[1], record: 2, offset: 0x10)
        let duplicate = bytes.withUnsafeBytes { buffer in
            RawTouchContactDecoder.decodeFrame(
                rawTouches: buffer.baseAddress,
                count: 3
            )
        }
        try requireGesture(
            duplicate == nil,
            "A real duplicate +0x10 identifier did not fail the byte frame closed"
        )
    }

    private static func rawContactDecoderFiltersGhostContacts() throws {
        let contacts = RawTouchContactDecoder.validatedContacts(
            from: [
                RawTouchRecord(state: 3, id: 1, x: 0.3, y: 0.4, zTotal: 0),
                RawTouchRecord(state: 1, id: 2, x: 0.5, y: 0.4, zTotal: 0.2),
                RawTouchRecord(state: 4, id: 3, x: 0.7, y: 0.4, zTotal: 0.2),
            ]
        )
        try requireGesture(
            contacts?.map(\.id) == [3],
            "Zero-capacitance or non-touching raw contacts were counted"
        )
    }

    private static func rawContactDecoderRejectsDuplicateFingerIDs() throws {
        let contacts = RawTouchContactDecoder.validatedContacts(
            from: [
                RawTouchRecord(state: 3, id: 7, x: 0.3, y: 0.4, zTotal: 0.2),
                RawTouchRecord(state: 4, id: 7, x: 0.7, y: 0.4, zTotal: 0.2),
            ]
        )
        try requireGesture(
            contacts == nil,
            "A duplicate raw finger identity did not fail the frame closed"
        )
    }

    private static func uncertainRawFrameDoesNotEndGesture() throws {
        var reducer = RawGestureFrameReducer()
        let baseline = rawContacts([(1, 0.72, 0.48), (2, 0.52, 0.50)])
        let moved = rawContacts([(1, 0.66, 0.48), (2, 0.46, 0.50)])
        _ = reducer.consume(contacts: baseline, timestamp: 28.00)
        let began = reducer.consume(contacts: moved, timestamp: 28.04)
        let uncertain = RawTouchContactDecoder.validatedFrame(
            from: [
                RawTouchRecord(state: 4, id: 1, x: 0.64, y: 0.48, zTotal: 0.2),
                RawTouchRecord(state: 4, id: 2, x: 0.44, y: 0.50, zTotal: 0.2),
                RawTouchRecord(state: 4, id: 3, x: 0.54, y: 0.68, zTotal: 0),
            ]
        )
        try requireGesture(
            uncertain?.hasUncertainTouchRecord == true
                && reducer.consume(frame: uncertain, timestamp: 28.05) == nil,
            "An uncertain low-capacitance frame was treated as a real lift"
        )
        let restored = rawContacts([(1, 0.62, 0.48), (2, 0.42, 0.50)])
        let changed = reducer.consume(contacts: restored, timestamp: 28.07)
        try requireGesture(
            began?.pageEvents.first?.phase == .began
                && changed?.pageEvents.first?.phase == .changed
                && changed?.pageEvents.first?.sequenceID
                    == began?.pageEvents.first?.sequenceID,
            "A single uncertain raw frame permanently blocked active paging"
        )
    }

    private static func malformedRawFrameBlocksUntilAllContactsLeave() throws {
        var reducer = RawGestureFrameReducer()
        let baseline = rawContacts([(1, 0.72, 0.48), (2, 0.52, 0.50)])
        let moved = rawContacts([(1, 0.52, 0.48), (2, 0.32, 0.50)])
        _ = reducer.consume(contacts: baseline, timestamp: 30.00)
        _ = reducer.consume(contacts: nil, timestamp: 30.02)
        try requireGesture(
            reducer.consume(contacts: moved, timestamp: 30.10) == nil,
            "A valid frame after malformed input reused the old raw baseline"
        )

        _ = reducer.consume(contacts: [], timestamp: 30.12)
        _ = reducer.consume(contacts: baseline, timestamp: 30.20)
        try requireGesture(
            reducer.consume(contacts: moved, timestamp: 30.28)?
                .pageEvents.first?.phase == .began,
            "A validated all-up frame did not rearm raw two-finger paging"
        )
    }

    private static func fiveFingerPinchRequiresFiveStableContacts() throws {
        var reducer = FiveFingerPinchReducer()
        let baseline = contacts(scale: 1.0)
        let contracted = contacts(scale: 0.60)
        try requireGesture(
            reducer.consume(contacts: Array(baseline.prefix(4))) == nil,
            "Four contacts started the five-finger gesture"
        )
        _ = reducer.consume(contacts: baseline)
        _ = reducer.consume(contacts: baseline)
        try requireGesture(
            reducer.consume(contacts: contracted) == .inward,
            "Five stable contacts contracting together did not trigger"
        )
        try requireGesture(
            reducer.consume(contacts: contracted) == nil,
            "Five-finger gesture retriggered before all contacts lifted"
        )
    }

    private static func fiveFingerPinchSurvivesOneDroppedContactFrame() throws {
        var reducer = FiveFingerPinchReducer()
        let baseline = contacts(scale: 1.0)
        _ = reducer.consume(contacts: baseline)
        try requireGesture(
            reducer.consume(contacts: Array(baseline.prefix(4))) == nil,
            "A one-frame five-to-four dropout triggered a pinch"
        )
        try requireGesture(
            reducer.consume(contacts: contacts(scale: 0.74)) == .inward,
            "One dropped raw contact frame erased the five-finger pinch baseline"
        )
    }

    private static func partiallyContractedFiveFingerBaselineStillTriggers() throws {
        var reducer = FiveFingerPinchReducer()
        _ = reducer.consume(contacts: contacts(scale: 0.85))
        try requireGesture(
            reducer.consume(contacts: contacts(scale: 0.65)) == .inward,
            "A first exact-five frame already partway inward required excessive extra contraction"
        )
    }

    private static func fiveFingerPinchUsesPreLandingPairHistory() throws {
        var reducer = FiveFingerPinchReducer()
        let fourBeforeFifthFinger = Array(contacts(scale: 1.0).prefix(4))
        _ = reducer.consume(contacts: fourBeforeFifthFinger)
        try requireGesture(
            reducer.consume(contacts: contacts(scale: 0.70)) == nil,
            "The first exact-five frame triggered before five contacts were stable"
        )
        try requireGesture(
            reducer.consume(contacts: contacts(scale: 0.70)) == .inward,
            "Contraction that began while the fifth finger landed was discarded"
        )
    }

    private static func fiveFingerPinchRearmsAfterAllUp() throws {
        var reducer = FiveFingerPinchReducer()
        _ = reducer.consume(contacts: contacts(scale: 1.0))
        try requireGesture(
            reducer.consume(contacts: contacts(scale: 0.74)) == .inward,
            "The first five-finger sequence did not trigger"
        )
        try requireGesture(
            reducer.consume(contacts: contacts(scale: 0.60)) == nil,
            "One physical five-finger sequence triggered twice"
        )
        _ = reducer.consume(contacts: [])
        _ = reducer.consume(contacts: contacts(scale: 1.0))
        try requireGesture(
            reducer.consume(contacts: contacts(scale: 0.74)) == .inward,
            "A full lift did not rearm the next five-finger sequence"
        )
    }

    private static func publicFiveFingerFallbackRequiresExactFive() throws {
        var reducer = PublicFiveFingerMagnifyReducer()
        try requireGesture(
            reducer.consume(
                magnification: -0.30,
                touchCount: 3,
                phase: [.began, .changed]
            ) == nil,
            "The public fallback accepted three reported touches"
        )
        try requireGesture(
            reducer.consume(
                magnification: -0.20,
                touchCount: 4,
                phase: .changed
            ) == nil,
            "The public fallback accepted fewer than five reported touches"
        )
        try requireGesture(
            reducer.consume(
                magnification: -0.40,
                touchCount: 0,
                phase: .changed,
                allowsUnavailableTouchCount: true
            ) == nil,
            "A sequence that exposed three/four touches escaped through a zero-count tail"
        )
        _ = reducer.consume(
            magnification: 0,
            touchCount: 0,
            phase: .ended
        )
        _ = reducer.consume(
            magnification: -0.04,
            touchCount: 5,
            phase: .began
        )
        _ = reducer.consume(
            magnification: -0.04,
            touchCount: 5,
            phase: .changed
        )
        try requireGesture(
            reducer.consume(
                magnification: -0.04,
                touchCount: 5,
                phase: .changed
            ) == .inward,
            "The exact-five public magnify fallback did not accumulate an inward pinch"
        )
        try requireGesture(
            reducer.consume(
                magnification: -0.20,
                touchCount: 5,
                phase: .changed
            ) == nil,
            "The public fallback retriggered before the gesture ended"
        )
        _ = reducer.consume(magnification: 0, touchCount: 0, phase: .ended)
        _ = reducer.consume(magnification: 0.06, touchCount: 5, phase: .began)
        try requireGesture(
            reducer.consume(
                magnification: 0.06,
                touchCount: 5,
                phase: .changed
            ) == .outward,
            "The public fallback did not rearm after an ended exact-five gesture"
        )
    }

    private static func publicUnavailableCountFallbackActivatesWithoutRawHealth() throws {
        let health = RawFiveFingerHealth()
        let now = 20.0
        let allowsUnavailableCount = !health.hasRecentExactFive(
            at: now,
            maximumAge: 0.30
        ) && !health.hasRecentTwoToFour(
            at: now,
            maximumAge: 0.30
        )
        var reducer = PublicFiveFingerMagnifyReducer()
        try requireGesture(
            reducer.consume(
                magnification: -0.08,
                touchCount: 0,
                phase: .began,
                allowsUnavailableTouchCount: allowsUnavailableCount
            ) == nil,
            "A raw-silent public pinch triggered before the strict threshold"
        )
        _ = reducer.consume(
            magnification: -0.08,
            touchCount: 0,
            phase: .changed,
            allowsUnavailableTouchCount: allowsUnavailableCount
        )
        try requireGesture(
            reducer.consume(
                magnification: -0.08,
                touchCount: 0,
                phase: .changed,
                allowsUnavailableTouchCount: allowsUnavailableCount
            ) == .inward,
            "A whole-sequence count-unavailable public pinch could not cover a silent raw bridge"
        )
    }

    private static func publicUnavailableCountFallbackRejectsTwoFingerSequence() throws {
        var health = RawFiveFingerHealth()
        health.observe(recordCount: 2, at: 30.0)
        let allowsUnavailableCount = !health.hasRecentExactFive(
            at: 30.05,
            maximumAge: 0.30
        ) && !health.hasRecentTwoToFour(
            at: 30.05,
            maximumAge: 0.30
        )
        try requireGesture(
            !allowsUnavailableCount,
            "Recent raw exact-two evidence did not quarantine count-unavailable magnify"
        )
        var reducer = PublicFiveFingerMagnifyReducer()
        try requireGesture(
            reducer.consume(
                magnification: -0.10,
                touchCount: 0,
                phase: .began,
                allowsUnavailableTouchCount: true
            ) == nil,
            "The unavailable-count probe triggered before raw evidence arrived"
        )
        try requireGesture(
            reducer.consume(
                magnification: -0.30,
                touchCount: 0,
                phase: .changed,
                allowsUnavailableTouchCount: allowsUnavailableCount,
                blocksUnavailableTouchCount: true
            ) == nil
                && reducer.consume(
                    magnification: -0.30,
                    touchCount: 0,
                    phase: .changed,
                    allowsUnavailableTouchCount: true
                ) == nil,
            "A global two-finger zoom with unavailable AppKit counts opened Launch"
        )

        reducer.reset()
        _ = reducer.consume(
            magnification: -0.10,
            touchCount: 0,
            phase: .began,
            allowsUnavailableTouchCount: true
        )
        _ = reducer.consume(
            magnification: -0.10,
            touchCount: 2,
            phase: .changed,
            allowsUnavailableTouchCount: true
        )
        try requireGesture(
            reducer.consume(
                magnification: -0.40,
                touchCount: 0,
                phase: .changed,
                allowsUnavailableTouchCount: true
            ) == nil,
            "A sequence that exposed two contacts escaped through its unavailable-count tail"
        )
    }

    private static func rawFiveFingerHealthExpires() throws {
        var health = RawFiveFingerHealth()
        health.observe(recordCount: 2, at: 40.0)
        health.observe(recordCount: 5, at: 40.1)
        try requireGesture(
            health.maximumRecordCount == 5
                && health.hasRecentTwoToFour(at: 40.2, maximumAge: 0.30)
                && health.hasRecentExactFive(at: 40.2, maximumAge: 0.30),
            "Raw callback-count health did not retain recent direct evidence"
        )
        try requireGesture(
            !health.hasRecentTwoToFour(at: 40.31, maximumAge: 0.30)
                && !health.hasRecentExactFive(at: 40.41, maximumAge: 0.30),
            "Stale raw contact evidence permanently disabled the public fallback"
        )
    }

    private static func rawPinchOwnershipCannotBeCancelledByPublicTail() throws {
        var ownership = TrackpadPinchSourceArbiter()
        try requireGesture(
            ownership.recognize(from: .public)
                && ownership.owner == .public,
            "The public fallback could not own a raw-silent five-finger sequence"
        )
        try requireGesture(
            ownership.recognize(from: .raw)
                && ownership.owner == .raw
                && ownership.accepts(.raw)
                && !ownership.accepts(.public),
            "Raw input did not preempt the public fallback for the same pinch"
        )
        try requireGesture(
            !ownership.recognize(from: .public)
                && ownership.owner == .raw,
            "A late public cancellation could reclaim and revoke a raw presentation"
        )
    }

    private static func recognizedPinchRequestsImmediatePresentation() throws {
        var state = DeferredPinchActivationState()
        try requireGesture(
            state.register(.inward) == .armFallback
                && state.release() == .activate(.inward)
                && state.recordActivity() == .none
                && state.release() == .none,
            "A confident recognition still waited for all-up before presentation"
        )
        try requireGesture(
            state.cancel() == .cancelActivation,
            "Lifecycle cancellation could not revoke the next-turn presentation"
        )
    }

    private static func deferredPinchActivatesOnceAfterRelease() throws {
        var state = DeferredPinchActivationState()
        try requireGesture(
            state.register(.inward) == .armFallback
                && state.recordActivity() == .armFallback
                && state.release() == .activate(.inward)
                && state.release() == .none,
            "A released five-finger pinch did not request exactly one activation"
        )
        state.presentationCompleted()
        try requireGesture(
            state.pendingDirection == nil && !state.activationWasRequested,
            "A completed deferred pinch remained armed"
        )
    }

    private static func deferredPinchFallsBackAfterMissingAllUp() throws {
        var state = DeferredPinchActivationState()
        _ = state.register(.inward)
        _ = state.recordActivity()
        try requireGesture(
            state.fallbackExpired() == .activate(.inward)
                && state.fallbackExpired() == .none
                && state.release() == .none,
            "A missing raw all-up did not fall back to one deferred activation"
        )
    }

    private static func deferredPinchCancellationPreventsLateActivation() throws {
        var beforeTimeout = DeferredPinchActivationState()
        _ = beforeTimeout.register(.inward)
        try requireGesture(
            beforeTimeout.cancel() == .cancelActivation
                && beforeTimeout.fallbackExpired() == .none,
            "A cancelled pinch could still activate from its fallback timer"
        )

        var afterTimeout = DeferredPinchActivationState()
        _ = afterTimeout.register(.inward)
        _ = afterTimeout.fallbackExpired()
        try requireGesture(
            afterTimeout.cancel() == .cancelActivation,
            "Cancellation did not revoke an activation queued for presentation"
        )
    }

    private static func inactiveGestureEndsWithLatestMotion() throws {
        var tracker = PageGestureInactivityTracker()
        let began = pageEvent(
            sequenceID: 31,
            phase: .began,
            touchCount: 2,
            progress: -0.08,
            velocity: -0.4
        )
        let changed = pageEvent(
            sequenceID: 31,
            phase: .changed,
            touchCount: 2,
            progress: -0.46,
            velocity: -1.7
        )
        try requireGesture(
            tracker.record(began, at: 100.0)
                && tracker.record(changed, at: 100.1),
            "The inactivity tracker rejected a valid page sequence"
        )
        try requireGesture(
            tracker.terminalEventIfExpired(
                at: 100.70,
                timeout: 0.65,
                phase: .ended
            ) == nil,
            "The inactivity watchdog ended a gesture before its timeout"
        )
        let ended = tracker.terminalEventIfExpired(
            at: 100.76,
            timeout: 0.65,
            phase: .ended
        )
        try requireGesture(
            ended?.phase == .ended
                && ended?.sequenceID == 31
                && ended?.progress == changed.progress
                && ended?.velocity == changed.velocity
                && tracker.latestEvent == nil,
            "A missing raw all-up did not settle with the latest motion sample"
        )
    }

    private static func inactiveGestureCancelsWhenInteractivityIsLost() throws {
        var tracker = PageGestureInactivityTracker()
        let changed = pageEvent(
            sequenceID: 41,
            phase: .began,
            touchCount: 2,
            progress: 0.38,
            velocity: 1.1
        )
        _ = tracker.record(changed, at: 200.0)
        let cancelled = tracker.terminalEventIfExpired(
            at: 200.7,
            timeout: 0.65,
            phase: .cancelled
        )
        try requireGesture(
            cancelled?.phase == .cancelled
                && cancelled?.sequenceID == changed.sequenceID
                && cancelled?.progress == changed.progress,
            "An inactive launcher did not cancel its timed-out page interaction"
        )
        try requireGesture(
            tracker.terminalEventIfExpired(
                at: 201.5,
                timeout: 0.65,
                phase: .cancelled
            ) == nil,
            "The inactivity watchdog terminated one sequence more than once"
        )
    }

    private static func inactivityTrackerRejectsStaleSequences() throws {
        var tracker = PageGestureInactivityTracker()
        let began = pageEvent(
            sequenceID: 51,
            phase: .began,
            touchCount: 2,
            progress: 0.05,
            velocity: 0.2
        )
        let stale = pageEvent(
            sequenceID: 52,
            phase: .changed,
            touchCount: 2,
            progress: 0.9,
            velocity: 4
        )
        let ended = pageEvent(
            sequenceID: 51,
            phase: .ended,
            touchCount: 2,
            progress: 0.2,
            velocity: 0.5
        )
        try requireGesture(
            tracker.record(began, at: 300.0)
                && !tracker.record(stale, at: 300.1)
                && tracker.latestEvent == began,
            "A stale sequence replaced the active inactivity watchdog sample"
        )
        try requireGesture(
            tracker.record(ended, at: 300.2)
                && tracker.latestEvent == nil
                && tracker.terminalEventIfExpired(
                    at: 301.0,
                    timeout: 0.65,
                    phase: .ended
                ) == nil,
            "A normally ended sequence left an armed inactivity watchdog"
        )
    }

    private static func samples(
        _ values: [(Int, Double, Double)]
    ) -> [TrackpadTouchSample] {
        values.map { TrackpadTouchSample(id: $0.0, x: $0.1, y: $0.2) }
    }

    private static func rawContacts(
        _ values: [(Int32, Double, Double)]
    ) -> [RawTrackpadContact] {
        values.map { RawTrackpadContact(id: $0.0, x: $0.1, y: $0.2) }
    }

    private static func rawPageAction(
        phase: TrackpadPageGestureEvent.Phase,
        progress: Double
    ) -> RawGestureAction {
        RawGestureAction(
            pageEvents: [
                TrackpadPageGestureEvent(
                    sequenceID: 42,
                    phase: phase,
                    touchCount: 2,
                    progress: progress,
                    velocity: 0
                ),
            ],
            pinchDirection: nil,
            exactTwoSequenceBegan: phase == .began,
            pinchSequenceActivity: false,
            pinchSequenceBoundary: nil
        )
    }

    private static func pageEvent(
        sequenceID: UInt64,
        phase: TrackpadPageGestureEvent.Phase,
        touchCount: Int,
        progress: Double,
        velocity: Double
    ) -> TrackpadPageGestureEvent {
        TrackpadPageGestureEvent(
            sequenceID: sequenceID,
            phase: phase,
            touchCount: touchCount,
            progress: progress,
            velocity: velocity
        )
    }

    private static func contacts(
        scale: Double
    ) -> [(id: Int32, x: Double, y: Double)] {
        let offsets = [
            (-0.30, 0.00), (-0.12, 0.24), (0.12, 0.24),
            (0.30, 0.00), (0.00, -0.28),
        ]
        return offsets.enumerated().map { index, offset in
            (
                id: Int32(index + 1),
                x: 0.5 + offset.0 * scale,
                y: 0.5 + offset.1 * scale
            )
        }
    }
}
