import AppKit
import Darwin
import Foundation

/// Opt-in, low-volume diagnostics for real-hardware gesture routing.
///
/// `LAUNCH_GESTURE_DIAGNOSTICS=1` mirrors events to stderr. Setting
/// `LAUNCH_GESTURE_DIAGNOSTIC_PATH=/private/tmp/LaunchGesture.log` additionally
/// maintains a bounded text ring at that path. Both switches are off by
/// default. Entries contain only source/count/phase/progress routing metadata;
/// coordinates, application names and user content are never recorded.
enum LaunchGestureDiagnostics {
    private static let environment = ProcessInfo.processInfo.environment
    private static let mirrorsToStandardError = environment[
        "LAUNCH_GESTURE_DIAGNOSTICS"
    ] == "1"
    private static let configuredPath = environment[
        "LAUNCH_GESTURE_DIAGNOSTIC_PATH"
    ].flatMap { value -> String? in
        guard value.hasPrefix("/"), !value.contains("\0") else { return nil }
        return value
    }
    private static let ringWriter = configuredPath.map {
        LaunchGestureDiagnosticRingWriter(fileURL: URL(fileURLWithPath: $0))
    }

    static let isEnabled = mirrorsToStandardError || configuredPath != nil
    static var outputPath: String? { configuredPath }

    static func log(_ message: @autoclosure () -> String) {
        guard isEnabled else { return }
        let timestamp = String(
            format: "%.3f",
            ProcessInfo.processInfo.systemUptime
        )
        let line = "[LaunchGesture \(timestamp)] \(message())"
        if mirrorsToStandardError {
            FileHandle.standardError.write(Data("\(line)\n".utf8))
        }
        ringWriter?.append(line)
    }

    static func flush() {
        ringWriter?.flush()
    }
}

private final class LaunchGestureDiagnosticRingWriter: @unchecked Sendable {
    private let fileURL: URL
    private let queue = DispatchQueue(
        label: "app.launch.gesture-diagnostics",
        qos: .utility
    )
    private let maximumLineCount = 512
    private let maximumUTF8ByteCount = 96 * 1_024
    private var lines: [String]

    init(fileURL: URL) {
        self.fileURL = fileURL
        let existing = (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
        lines = existing.split(whereSeparator: { $0.isNewline }).map(String.init)
        trimIfNeeded()
    }

    func append(_ line: String) {
        queue.async { [self] in
            lines.append(line)
            trimIfNeeded()
            persist()
        }
    }

    func flush() {
        queue.sync {}
    }

    private func trimIfNeeded() {
        if lines.count > maximumLineCount {
            lines.removeFirst(lines.count - maximumLineCount)
        }
        while lines.count > 1,
              lines.reduce(0, { $0 + $1.utf8.count + 1 }) > maximumUTF8ByteCount {
            lines.removeFirst()
        }
    }

    private func persist() {
        let contents = lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
        do {
            try contents.write(to: fileURL, atomically: true, encoding: .utf8)
        } catch {
            // Diagnostics must never affect gesture delivery or app lifetime.
        }
    }
}

struct TrackpadTouchSample: Hashable, Sendable {
    let id: Int
    let x: Double
    let y: Double
}

enum TrackpadTouchPhase: Sendable {
    case began
    case changed
    case ended
    case cancelled
}

enum TrackpadPageBlockReason: String, Equatable, Sendable {
    case primaryPointerButtonDown = "primary-pointer-button-down"
    case tooManyTouches = "too-many-touches"
    case candidateContactLoss = "candidate-contact-loss"
    case candidateIdentityChanged = "candidate-identity-changed"
    case unavailableBaseline = "unavailable-baseline"
    case candidateGeometryChanged = "candidate-geometry-changed"
    case verticalIntent = "vertical-intent"
    case activeIdentityChanged = "active-identity-changed"
    case activeGeometryChanged = "active-geometry-changed"
}

struct TrackpadPageGestureEvent: Equatable, Sendable {
    enum Phase: Equatable, Sendable {
        case began
        case changed
        case ended
        case cancelled
    }

    let sequenceID: UInt64
    let phase: Phase
    let touchCount: Int
    /// Horizontal translation in page widths. Right is positive, left is negative.
    let progress: Double
    /// Horizontal velocity in page widths per second.
    let velocity: Double
    /// Present only for reducer-internal cancellation. Lifecycle cancellation
    /// deliberately leaves this nil so the manager can distinguish the two.
    let blockReason: TrackpadPageBlockReason?

    init(
        sequenceID: UInt64,
        phase: Phase,
        touchCount: Int,
        progress: Double,
        velocity: Double,
        blockReason: TrackpadPageBlockReason? = nil
    ) {
        self.sequenceID = sequenceID
        self.phase = phase
        self.touchCount = touchCount
        self.progress = progress
        self.velocity = velocity
        self.blockReason = blockReason
    }
}

enum TrackpadPageInputSource: String, Equatable, Sendable {
    case local
    case raw
}

struct TrackpadPageInputIdentity: Equatable, Sendable {
    let source: TrackpadPageInputSource
    let sequenceID: UInt64
}

/// Namespaces local AppKit and private raw sequences and lets exactly one input
/// source own the UI interaction until it terminates. Merely constructing the
/// raw bridge is not proof that its callback is healthy; a silent raw bridge
/// therefore cannot suppress the public local path.
struct TrackpadPageSourceArbiter {
    private(set) var activeIdentity: TrackpadPageInputIdentity?

    mutating func accepts(
        _ event: TrackpadPageGestureEvent,
        from source: TrackpadPageInputSource
    ) -> Bool {
        let identity = TrackpadPageInputIdentity(
            source: source,
            sequenceID: event.sequenceID
        )
        switch event.phase {
        case .began:
            guard activeIdentity == nil else { return false }
            activeIdentity = identity
            return true

        case .changed:
            return activeIdentity == identity

        case .ended, .cancelled:
            guard activeIdentity == identity else { return false }
            activeIdentity = nil
            return true
        }
    }

    mutating func reset() {
        activeIdentity = nil
    }
}

/// Briefly holds the public AppKit source while a concurrently running raw
/// bridge has a chance to emit its begin. Consecutive motion frames coalesce,
/// but begin and terminal boundaries are retained exactly.
struct PendingLocalPageGestureBuffer {
    private(set) var sequenceID: UInt64?
    private var events: [TrackpadPageGestureEvent] = []

    var isEmpty: Bool { events.isEmpty }

    @discardableResult
    mutating func stage(_ event: TrackpadPageGestureEvent) -> Bool {
        switch event.phase {
        case .began:
            guard events.isEmpty else { return false }
            sequenceID = event.sequenceID
            events = [event]
            return true

        case .changed:
            guard sequenceID == event.sequenceID,
                  events.first?.phase == .began,
                  events.last?.phase != .ended,
                  events.last?.phase != .cancelled else { return false }
            if events.last?.phase == .changed {
                events[events.count - 1] = event
            } else {
                events.append(event)
            }
            return true

        case .ended, .cancelled:
            guard sequenceID == event.sequenceID,
                  events.first?.phase == .began,
                  events.last?.phase != .ended,
                  events.last?.phase != .cancelled else { return false }
            events.append(event)
            return true
        }
    }

    mutating func drain() -> [TrackpadPageGestureEvent] {
        let drained = events
        reset()
        return drained
    }

    mutating func reset() {
        sequenceID = nil
        events.removeAll(keepingCapacity: true)
    }
}

/// Keeps AppKit's delayed copy of a raw-owned physical gesture from becoming a
/// second sequence after raw has already settled. The quarantine lives until
/// AppKit reports its own all-up boundary.
struct RawOwnedLocalPageQuarantine {
    private(set) var isActive = false

    mutating func rawSequenceBegan() {
        isActive = true
    }

    /// Returns true while the local frame belongs to the raw-owned sequence.
    /// The all-up frame is consumed as the release boundary as well.
    mutating func suppressesLocalFrame(touchCount: Int) -> Bool {
        guard isActive else { return false }
        if touchCount == 0 {
            isActive = false
        }
        return true
    }

    mutating func rawSequenceEnded(currentLocalTouchCount: Int) {
        if currentLocalTouchCount == 0 {
            isActive = false
        }
    }

    mutating func reset() {
        isActive = false
    }
}

/// Closes the narrow race where a raw frame is decoded immediately before a
/// mouse-down but reaches the main queue immediately after it. Reducer-level
/// suppression owns the normal path; this delivery latch discards that stale
/// begin and every remaining event from the same raw sequence through its
/// terminal boundary.
struct PrimaryButtonPageDeliveryQuarantine {
    struct Result: Equatable, Sendable {
        let acceptedEvents: [TrackpadPageGestureEvent]
        let didSuppress: Bool
    }

    private(set) var isActive = false

    mutating func beginPhysicalSequence() {
        isActive = true
    }

    mutating func filter(
        _ events: [TrackpadPageGestureEvent],
        primaryButtonIsDown: Bool
    ) -> Result {
        var acceptedEvents: [TrackpadPageGestureEvent] = []
        acceptedEvents.reserveCapacity(events.count)
        var didSuppress = false

        for event in events {
            if primaryButtonIsDown {
                isActive = true
            }
            guard isActive else {
                acceptedEvents.append(event)
                continue
            }

            didSuppress = true
            if event.phase == .ended || event.phase == .cancelled {
                isActive = false
            }
        }
        return Result(
            acceptedEvents: acceptedEvents,
            didSuppress: didSuppress
        )
    }

    mutating func reset() {
        isActive = false
    }
}

/// Remembers that a local touch sequence overlapped a primary-button drag even
/// if lifecycle code resets the page reducer before the fingers lift.
struct PrimaryButtonTouchSequenceLatch {
    private(set) var isActive = false

    mutating func blocksPageGesture(
        touchCount: Int,
        primaryButtonIsDown: Bool,
        phase: TrackpadTouchPhase? = nil
    ) -> Bool {
        // AppKit cancellation is the terminal boundary of the observable local
        // sequence. It may still report other `.touching` contacts in that same
        // event, but no later all-up callback is guaranteed. Block this frame,
        // then rearm only for a future AppKit sequence.
        if phase == .cancelled {
            let blocksCancelledFrame = isActive || primaryButtonIsDown
            isActive = false
            return blocksCancelledFrame
        }
        if touchCount == 0 {
            isActive = false
            return false
        }
        if primaryButtonIsDown {
            isActive = true
        }
        return isActive
    }

    mutating func reset() {
        isActive = false
    }
}

enum TrackpadPinchInputSource: String, Equatable, Sendable {
    case raw
    case `public`
}

/// Gives a concurrently observed five-finger sequence one presentation owner.
/// The version-verified raw stream is authoritative when it appears, while the
/// public magnify stream remains available when raw is silent. In particular, a
/// system-cancelled public tail can never revoke a presentation recognized by
/// raw input.
struct TrackpadPinchSourceArbiter: Sendable {
    private(set) var owner: TrackpadPinchInputSource?

    mutating func recognize(from source: TrackpadPinchInputSource) -> Bool {
        switch (owner, source) {
        case (nil, _):
            owner = source
            return true
        case let (current?, proposed) where current == proposed:
            return true
        case (.public?, .raw):
            owner = .raw
            return true
        case (.raw?, .public):
            return false
        default:
            return false
        }
    }

    func accepts(_ source: TrackpadPinchInputSource) -> Bool {
        owner == source
    }

    mutating func reset() {
        owner = nil
    }
}

/// A page watchdog may settle a stalled exact-two gesture only while ordinary
/// paging is still interactive. A primary-button press is an explicit drag
/// boundary even when AppKit/MultitouchSupport does not deliver another touch
/// frame before the watchdog fires.
struct PageGestureWatchdogTerminalPolicy {
    static func terminalPhase(
        isInteractive: Bool,
        primaryButtonIsDown: Bool,
        primaryButtonSequenceIsLatched: Bool
    ) -> TrackpadPageGestureEvent.Phase {
        isInteractive
            && !primaryButtonIsDown
            && !primaryButtonSequenceIsLatched
            ? .ended
            : .cancelled
    }
}

/// Deterministic release prediction shared by AppDelegate and gesture checks.
/// Distance wins outright. A shorter movement can commit only as a deliberate,
/// same-direction flick with both a minimum travel and velocity.
struct TrackpadPageCommitPolicy {
    static let distanceThreshold = 0.22
    static let minimumFlickDistance = 0.08
    static let minimumFlickVelocity = 0.90
    static let velocityProjectionDuration = 0.16

    static func predictedTranslation(
        progress: Double,
        velocity: Double
    ) -> Double {
        guard progress.isFinite, velocity.isFinite else { return 0 }
        let measured = min(max(progress, -1.25), 1.25)
        if abs(measured) >= distanceThreshold {
            return measured
        }
        guard abs(measured) >= minimumFlickDistance,
              abs(velocity) >= minimumFlickVelocity,
              measured * velocity > 0 else {
            return measured
        }
        return min(
            max(measured + velocity * velocityProjectionDuration, -1.25),
            1.25
        )
    }
}

struct TrackpadPageTerminalPolicy {
    static func normalized(
        event: TrackpadPageGestureEvent,
        source: TrackpadPageInputSource,
        activeIdentity: TrackpadPageInputIdentity?,
        reliableEvent: TrackpadPageGestureEvent?,
        isInteractive: Bool
    ) -> TrackpadPageGestureEvent {
        guard event.phase == .cancelled,
              event.blockReason != .tooManyTouches,
              event.blockReason != .primaryPointerButtonDown,
              isInteractive,
              activeIdentity == TrackpadPageInputIdentity(
                source: source,
                sequenceID: event.sequenceID
              ),
              let reliableEvent,
              reliableEvent.sequenceID == event.sequenceID,
              abs(reliableEvent.progress)
                >= TrackpadPageCommitPolicy.distanceThreshold else {
            return event
        }
        return TrackpadPageGestureEvent(
            sequenceID: reliableEvent.sequenceID,
            phase: .ended,
            touchCount: reliableEvent.touchCount,
            progress: reliableEvent.progress,
            velocity: reliableEvent.velocity,
            blockReason: event.blockReason
        )
    }
}

/// Tracks the latest UI-delivered page sample independently of the raw touch
/// reducer. MultitouchSupport occasionally omits its final all-up callback, so
/// an otherwise valid gesture must still settle instead of leaving SwiftUI in
/// an indefinitely tracking state.
struct PageGestureInactivityTracker {
    private(set) var latestEvent: TrackpadPageGestureEvent?
    private(set) var lastActivityTimestamp: TimeInterval?

    @discardableResult
    mutating func record(
        _ event: TrackpadPageGestureEvent,
        at timestamp: TimeInterval
    ) -> Bool {
        switch event.phase {
        case .began:
            guard latestEvent == nil else { return false }
            latestEvent = event
            lastActivityTimestamp = timestamp
            return true

        case .changed:
            guard latestEvent?.sequenceID == event.sequenceID else { return false }
            latestEvent = event
            lastActivityTimestamp = timestamp
            return true

        case .ended, .cancelled:
            guard latestEvent?.sequenceID == event.sequenceID else { return false }
            reset()
            return true
        }
    }

    mutating func terminalEventIfExpired(
        at timestamp: TimeInterval,
        timeout: TimeInterval,
        phase: TrackpadPageGestureEvent.Phase
    ) -> TrackpadPageGestureEvent? {
        guard phase == .ended || phase == .cancelled,
              let latestEvent,
              let lastActivityTimestamp,
              timestamp - lastActivityTimestamp >= timeout else {
            return nil
        }
        reset()
        return Self.terminalEvent(from: latestEvent, phase: phase)
    }

    mutating func cancelCurrent() -> TrackpadPageGestureEvent? {
        guard let latestEvent else { return nil }
        reset()
        return Self.terminalEvent(from: latestEvent, phase: .cancelled)
    }

    mutating func reset() {
        latestEvent = nil
        lastActivityTimestamp = nil
    }

    private static func terminalEvent(
        from event: TrackpadPageGestureEvent,
        phase: TrackpadPageGestureEvent.Phase
    ) -> TrackpadPageGestureEvent {
        TrackpadPageGestureEvent(
            sequenceID: event.sequenceID,
            phase: phase,
            touchCount: event.touchCount,
            progress: event.progress,
            velocity: event.velocity
        )
    }
}

/// Interprets raw/public contact streams as one interactive page gesture.
///
/// Exactly two contacts are accepted. One contact is ignored while the second
/// finger is still landing; once three contacts appear, or the identities
/// of an active gesture change, the whole physical sequence is blocked until
/// all contacts leave. Raw frames may temporarily omit one low-capacitance
/// contact, so that source receives a short dropout grace period instead of
/// permanently poisoning the gesture on a single frame.
struct LocalTouchPager {
    private var sequenceIsActive = false
    private var sequenceIsBlocked = false
    private var maximumTouchCount = 0
    private var candidateIDs = Set<Int>()
    private var candidatePositions: [Int: TrackpadTouchSample] = [:]
    private var candidateCentroid: (x: Double, y: Double)?
    private var candidateSpan: Double?
    private var candidateTimestamp: TimeInterval = 0
    private var candidateDropoutTimestamp: TimeInterval?
    private var candidateHorizontalIntentFrameCount = 0
    private var activeSequenceID: UInt64?
    private var nextSequenceID: UInt64 = 1
    private var activeIDs = Set<Int>()
    private var activeBaselinePositions: [Int: TrackpadTouchSample] = [:]
    private var latestProgress = 0.0
    private var latestVelocity = 0.0
    private var latestCentroid: (x: Double, y: Double)?
    private var latestTimestamp: TimeInterval = 0
    private var dropoutTimestamp: TimeInterval?
    private var spreadViolationFrameCount = 0
    private var trackingDidFinish = false

    private let fullPageTranslation = 0.18
    private let horizontalIntentThreshold = 0.010
    private let horizontalDirectionRatio = 1.35
    private let verticalDirectionRatio = 1.20
    private let verticalIntentThreshold = 0.018
    // Only a nearly commit-distance horizontal displacement may lock in one
    // frame. Smaller movements need two horizontally dominant frames, so the
    // common "small sideways landing wobble, then vertical swipe" never makes
    // the page move before vertical intent is known.
    private let immediateHorizontalIntentThreshold = 0.035
    private let maximumSpreadChangeRatio = 0.15
    // Give additional fingers a short landing window before exact-two becomes
    // eligible. This keeps a five-finger pinch (or a three-finger system
    // gesture) from briefly moving the page while still retaining fast flicks.
    private let twoFingerStableDuration: TimeInterval = 0.018
    private let rawDropoutGraceDuration: TimeInterval = 0.075

    mutating func consume(
        _ samples: [TrackpadTouchSample],
        phase: TrackpadTouchPhase,
        timestamp: TimeInterval,
        toleratesTransientDropout: Bool = false,
        blocksPageGesture: Bool = false,
        diagnosticSource: TrackpadPageInputSource? = nil
    ) -> [TrackpadPageGestureEvent] {
        if phase == .cancelled {
            let events = finishTracking(cancelled: true)
            reset()
            return events
        }

        if samples.isEmpty {
            let events = finishTracking(cancelled: false)
            reset()
            return events
        }

        if !sequenceIsActive {
            reset()
            sequenceIsActive = true
        }

        // A primary-button drag and trackpad pagination are mutually
        // exclusive. Lock the whole physical contact sequence, rather than
        // merely ignoring this frame, so fingers still resting after mouse-up
        // cannot become a fresh exact-two candidate.
        if blocksPageGesture {
            guard !sequenceIsBlocked else { return [] }
            return blockSequence(
                reason: .primaryPointerButtonDown,
                diagnosticSource: diagnosticSource
            )
        }

        maximumTouchCount = max(maximumTouchCount, samples.count)
        if maximumTouchCount >= 3 {
            guard !sequenceIsBlocked else { return [] }
            return blockSequence(
                reason: .tooManyTouches,
                diagnosticSource: diagnosticSource
            )
        }

        guard !sequenceIsBlocked, !trackingDidFinish else { return [] }

        if activeSequenceID != nil {
            return consumeActiveGesture(
                samples,
                phase: phase,
                timestamp: timestamp,
                toleratesTransientDropout: toleratesTransientDropout,
                diagnosticSource: diagnosticSource
            )
        }

        guard samples.count == 2 else {
            if !candidateIDs.isEmpty,
               samples.count < 2,
               Set(samples.map(\.id)).isSubset(of: candidateIDs),
               phase != .ended,
                toleratesTransientDropout {
                if candidateDropoutTimestamp == nil {
                    candidateDropoutTimestamp = timestamp
                    candidateHorizontalIntentFrameCount = 0
                    return []
                }
                if timestamp - (candidateDropoutTimestamp ?? timestamp)
                    <= rawDropoutGraceDuration {
                    return []
                }
            }
            // Before exact-two is reached, one finger is only the landing
            // prelude and never creates a page candidate. Once an exact-two
            // candidate exists, its lift tail cannot rearm.
            if !candidateIDs.isEmpty {
                return blockSequence(
                    reason: .candidateContactLoss,
                    diagnosticSource: diagnosticSource
                )
            }
            return []
        }

        let ids = Set(samples.map(\.id))
        let centroid = Self.centroid(of: samples)
        let span = Self.span(of: samples)

        if candidateIDs.isEmpty {
            establishCandidate(
                samples: samples,
                ids: ids,
                centroid: centroid,
                span: span,
                timestamp: timestamp
            )
            return []
        }

        guard candidateIDs == ids else {
            return blockSequence(
                reason: .candidateIdentityChanged,
                diagnosticSource: diagnosticSource
            )
        }
        candidateDropoutTimestamp = nil

        guard let candidateCentroid, let candidateSpan else {
            return blockSequence(
                reason: .unavailableBaseline,
                diagnosticSource: diagnosticSource
            )
        }
        if spreadChangeBlocksGesture(current: span, baseline: candidateSpan) {
            return blockSequence(
                reason: .candidateGeometryChanged,
                diagnosticSource: diagnosticSource
            )
        }

        guard timestamp - candidateTimestamp >= twoFingerStableDuration else {
            return []
        }

        let deltaX = centroid.x - candidateCentroid.x
        let deltaY = centroid.y - candidateCentroid.y
        let horizontalDistance = abs(deltaX)
        let verticalDistance = abs(deltaY)

        // Resolve vertical intent before ever emitting `began`. Pure vertical
        // and vertically dominant diagonal swipes therefore cannot first move
        // the page and only later cancel it.
        if verticalDistance >= verticalIntentThreshold,
           verticalDistance > horizontalDistance * verticalDirectionRatio {
            if let diagnosticSource {
                LaunchGestureDiagnostics.log(
                    "direction source=\(diagnosticSource.rawValue) count=2 decision=vertical-block"
                )
            }
            return blockSequence(
                reason: .verticalIntent,
                diagnosticSource: diagnosticSource
            )
        }

        guard horizontalDistance >= horizontalIntentThreshold,
              horizontalDistance > verticalDistance * horizontalDirectionRatio else {
            candidateHorizontalIntentFrameCount = 0
            return []
        }
        candidateHorizontalIntentFrameCount += 1
        guard horizontalDistance >= immediateHorizontalIntentThreshold
                || candidateHorizontalIntentFrameCount >= 2 else {
            return []
        }

        let sequenceID = nextSequenceID
        nextSequenceID &+= 1
        if nextSequenceID == 0 { nextSequenceID = 1 }
        activeSequenceID = sequenceID
        activeIDs = ids
        activeBaselinePositions = candidatePositions
        spreadViolationFrameCount = 0
        latestProgress = Self.clampedPageProgress(deltaX / fullPageTranslation)
        let initialDuration = max(timestamp - candidateTimestamp, 0.001)
        latestVelocity = Self.clampedPageVelocity(
            latestProgress / initialDuration
        )
        latestCentroid = centroid
        latestTimestamp = timestamp
        dropoutTimestamp = nil

        if let diagnosticSource {
            LaunchGestureDiagnostics.log(
                "direction source=\(diagnosticSource.rawValue) count=2 decision=horizontal-begin"
            )
        }

        return [event(phase: .began)]
    }

    mutating func reset() {
        sequenceIsActive = false
        sequenceIsBlocked = false
        maximumTouchCount = 0
        candidateIDs.removeAll(keepingCapacity: true)
        candidatePositions.removeAll(keepingCapacity: true)
        candidateCentroid = nil
        candidateSpan = nil
        candidateTimestamp = 0
        candidateDropoutTimestamp = nil
        candidateHorizontalIntentFrameCount = 0
        activeSequenceID = nil
        activeIDs.removeAll(keepingCapacity: true)
        activeBaselinePositions.removeAll(keepingCapacity: true)
        latestProgress = 0
        latestVelocity = 0
        latestCentroid = nil
        latestTimestamp = 0
        dropoutTimestamp = nil
        spreadViolationFrameCount = 0
        trackingDidFinish = false
    }

    private mutating func establishCandidate(
        samples: [TrackpadTouchSample],
        ids: Set<Int>,
        centroid: (x: Double, y: Double),
        span: Double,
        timestamp: TimeInterval
    ) {
        candidateIDs = ids
        candidatePositions = Dictionary(
            uniqueKeysWithValues: samples.map { ($0.id, $0) }
        )
        candidateCentroid = centroid
        candidateSpan = span
        candidateTimestamp = timestamp
        candidateDropoutTimestamp = nil
        candidateHorizontalIntentFrameCount = 0
    }

    private mutating func consumeActiveGesture(
        _ samples: [TrackpadTouchSample],
        phase: TrackpadTouchPhase,
        timestamp: TimeInterval,
        toleratesTransientDropout: Bool,
        diagnosticSource: TrackpadPageInputSource?
    ) -> [TrackpadPageGestureEvent] {
        guard let candidateSpan else {
            return blockSequence(
                reason: .unavailableBaseline,
                settleCommittedMotion: true,
                diagnosticSource: diagnosticSource
            )
        }

        let ids = Set(samples.map(\.id))
        guard samples.count == 2, ids == activeIDs else {
            let isPossibleDropout = samples.count < 2
                && ids.isSubset(of: activeIDs)
            if isPossibleDropout, phase != .ended, toleratesTransientDropout {
                // A one-contact tail is not geometrically comparable with
                // the exact-two baseline. In particular, one remaining
                // finger can have a much smaller (or briefly reversed) delta
                // and used to overwrite a clearly completed swipe immediately
                // before `ended`. Freeze the last reliable exact-two sample;
                // this also guarantees that a lift tail never influences page
                // motion.
                if dropoutTimestamp == nil {
                    dropoutTimestamp = timestamp
                    return []
                }
                if timestamp - (dropoutTimestamp ?? timestamp) <= rawDropoutGraceDuration {
                    return []
                }
                let events = finishTracking(cancelled: false)
                sequenceIsBlocked = true
                return events
            }

            if isPossibleDropout, phase == .ended {
                let events = finishTracking(cancelled: false)
                sequenceIsBlocked = true
                return events
            }
            return blockSequence(
                reason: .activeIdentityChanged,
                settleCommittedMotion: true,
                diagnosticSource: diagnosticSource
            )
        }
        dropoutTimestamp = nil

        let centroid = Self.centroid(of: samples)
        let span = Self.span(of: samples)
        if spreadChangeBlocksGesture(current: span, baseline: candidateSpan) {
            return blockSequence(
                reason: .activeGeometryChanged,
                settleCommittedMotion: true,
                diagnosticSource: diagnosticSource
            )
        }

        return updateActiveMotion(samples, timestamp: timestamp, centroid: centroid)
    }

    private mutating func updateActiveMotion(
        _ samples: [TrackpadTouchSample],
        timestamp: TimeInterval,
        centroid: (x: Double, y: Double)? = nil
    ) -> [TrackpadPageGestureEvent] {
        guard !samples.isEmpty else { return [] }
        let deltas = samples.compactMap { sample -> Double? in
            guard let baseline = activeBaselinePositions[sample.id] else { return nil }
            return sample.x - baseline.x
        }
        guard deltas.count == samples.count else { return [] }
        let averageDeltaX = deltas.reduce(0, +) / Double(deltas.count)
        let progress = Self.clampedPageProgress(
            averageDeltaX / fullPageTranslation
        )
        let deltaTime = timestamp - latestTimestamp
        if deltaTime > 0.000_1 {
            let instantaneousVelocity = (progress - latestProgress) / deltaTime
            let boundedVelocity = Self.clampedPageVelocity(instantaneousVelocity)
            latestVelocity = latestTimestamp == 0
                ? boundedVelocity
                : latestVelocity * 0.68 + boundedVelocity * 0.32
        }
        latestProgress = progress
        latestCentroid = centroid ?? Self.centroid(of: samples)
        latestTimestamp = timestamp
        return [event(phase: .changed)]
    }

    private mutating func spreadChangeBlocksGesture(
        current: Double,
        baseline: Double
    ) -> Bool {
        guard baseline > 0.001 else { return false }
        let ratio = abs(current - baseline) / baseline
        if ratio > 0.30 {
            return true
        }
        if ratio > maximumSpreadChangeRatio {
            spreadViolationFrameCount += 1
        } else {
            spreadViolationFrameCount = 0
        }
        return spreadViolationFrameCount >= 2
    }

    private mutating func blockSequence(
        reason: TrackpadPageBlockReason,
        settleCommittedMotion: Bool = false,
        diagnosticSource: TrackpadPageInputSource?
    ) -> [TrackpadPageGestureEvent] {
        let shouldSettle = settleCommittedMotion
            && activeSequenceID != nil
            && abs(latestProgress) >= TrackpadPageCommitPolicy.distanceThreshold
        // A real lift frequently presents one final exact-two frame whose
        // identity or span is no longer stable. Once the user has already
        // crossed the commit distance, freeze the last reliable exact-two
        // sample and quarantine the sequence until all-up. Emitting cancel here
        // is what made a visibly completed page rebound intermittently.
        let events = shouldSettle
            ? []
            : finishTracking(cancelled: true, blockReason: reason)
        if let diagnosticSource {
            LaunchGestureDiagnostics.log(
                "block source=\(diagnosticSource.rawValue) reason=\(reason.rawValue) terminal=\(shouldSettle ? "defer-ended-until-all-up" : (events.isEmpty ? "none" : "cancelled")) progress=\(String(format: "%.3f", latestProgress))"
            )
        }
        sequenceIsBlocked = true
        candidateIDs.removeAll(keepingCapacity: true)
        candidatePositions.removeAll(keepingCapacity: true)
        candidateCentroid = nil
        candidateSpan = nil
        candidateDropoutTimestamp = nil
        candidateHorizontalIntentFrameCount = 0
        return events
    }

    private mutating func finishTracking(
        cancelled: Bool,
        blockReason: TrackpadPageBlockReason? = nil
    ) -> [TrackpadPageGestureEvent] {
        guard activeSequenceID != nil, !trackingDidFinish else { return [] }
        trackingDidFinish = true
        let finalEvent = event(
            phase: cancelled ? .cancelled : .ended,
            blockReason: blockReason
        )
        activeSequenceID = nil
        return [finalEvent]
    }

    private func event(
        phase: TrackpadPageGestureEvent.Phase,
        blockReason: TrackpadPageBlockReason? = nil
    ) -> TrackpadPageGestureEvent {
        TrackpadPageGestureEvent(
            sequenceID: activeSequenceID ?? 0,
            phase: phase,
            touchCount: 2,
            progress: latestProgress,
            velocity: latestVelocity,
            blockReason: blockReason
        )
    }

    private static func clampedPageProgress(_ value: Double) -> Double {
        min(max(value, -1.25), 1.25)
    }

    private static func clampedPageVelocity(_ value: Double) -> Double {
        min(max(value, -8), 8)
    }

    private static func centroid(
        of samples: [TrackpadTouchSample]
    ) -> (x: Double, y: Double) {
        let total = samples.reduce(into: (x: 0.0, y: 0.0)) { result, sample in
            result.x += sample.x
            result.y += sample.y
        }
        let count = Double(max(samples.count, 1))
        return (total.x / count, total.y / count)
    }

    /// RMS distance from the centroid works for two contacts and stays nearly
    /// constant during a translation, while changing clearly during a pinch.
    private static func span(of samples: [TrackpadTouchSample]) -> Double {
        guard !samples.isEmpty else { return 0 }
        let center = centroid(of: samples)
        let meanSquare = samples.reduce(0.0) { total, sample in
            let deltaX = sample.x - center.x
            let deltaY = sample.y - center.y
            return total + deltaX * deltaX + deltaY * deltaY
        } / Double(samples.count)
        return sqrt(meanSquare)
    }
}

enum RawPinchDirection: Equatable, Sendable {
    case inward
    case outward
}

enum DeferredPinchActivationCommand: Equatable, Sendable {
    case none
    case armFallback
    case activate(RawPinchDirection)
    case cancelActivation
    case cancelActivationAndArmFallback
}

/// Keeps recognition state separate from the delayed window presentation. The
/// manager can request activation immediately for responsive input, while the
/// same state still supports release/fallback consumers and lifecycle cancel.
struct DeferredPinchActivationState {
    private(set) var pendingDirection: RawPinchDirection?
    private(set) var activationWasRequested = false

    mutating func register(
        _ direction: RawPinchDirection
    ) -> DeferredPinchActivationCommand {
        if pendingDirection != direction {
            let needsCancellation = activationWasRequested
            pendingDirection = direction
            activationWasRequested = false
            return needsCancellation
                ? .cancelActivationAndArmFallback
                : .armFallback
        }
        return activationWasRequested ? .none : .armFallback
    }

    mutating func recordActivity() -> DeferredPinchActivationCommand {
        guard pendingDirection != nil else { return .none }
        if activationWasRequested {
            activationWasRequested = false
            return .cancelActivationAndArmFallback
        }
        return .armFallback
    }

    mutating func release() -> DeferredPinchActivationCommand {
        guard let direction = pendingDirection else { return .none }
        pendingDirection = nil
        guard !activationWasRequested else { return .none }
        activationWasRequested = true
        return .activate(direction)
    }

    mutating func fallbackExpired() -> DeferredPinchActivationCommand {
        guard let direction = pendingDirection,
              !activationWasRequested else { return .none }
        activationWasRequested = true
        return .activate(direction)
    }

    mutating func cancel() -> DeferredPinchActivationCommand {
        let shouldCancelActivation = pendingDirection != nil
            || activationWasRequested
        reset()
        return shouldCancelActivation ? .cancelActivation : .none
    }

    mutating func presentationCompleted() {
        reset()
    }

    mutating func reset() {
        pendingDirection = nil
        activationWasRequested = false
    }
}

struct RawGestureAction: Equatable, Sendable {
    let pageEvents: [TrackpadPageGestureEvent]
    let pinchDirection: RawPinchDirection?
    let exactTwoSequenceBegan: Bool
    let pinchSequenceActivity: Bool
    let pinchSequenceBoundary: RawPinchSequenceBoundary?
}

enum RawPinchSequenceBoundary: Equatable, Sendable {
    case released
    case cancelled
}

struct RawTouchRecord: Sendable {
    let state: UInt32
    let id: Int32
    let x: Float
    let y: Float
    let zTotal: Float
}

struct RawTrackpadContact: Equatable, Sendable {
    let id: Int32
    let x: Double
    let y: Double
}

struct RawDecodedTouchFrame: Equatable, Sendable {
    let contacts: [RawTrackpadContact]
    /// True only when the raw records confidently describe no touching contact.
    let isDefiniteAllUp: Bool
    /// A state-3/4 record with zero/near-zero capacitance is ignored for motion,
    /// but is not treated as a finger lift because it commonly occurs for one
    /// frame while a finger is moving.
    let hasUncertainTouchRecord: Bool
}

/// Scalar validation is kept separate from the private callback so malformed,
/// duplicate, hover and zero-capacitance records fail closed and are testable.
enum RawTouchContactDecoder {
    static func decodeFrame(
        rawTouches: UnsafeRawPointer?,
        count: Int
    ) -> RawDecodedTouchFrame? {
        guard (0...32).contains(count), count == 0 || rawTouches != nil else {
            return nil
        }
        guard let rawTouches else {
            return RawDecodedTouchFrame(
                contacts: [],
                isDefiniteAllUp: true,
                hasUncertainTouchRecord: false
            )
        }

        let records = (0..<count).map { index -> RawTouchRecord in
            let record = rawTouches.advanced(by: index * 96)
            return RawTouchRecord(
                state: record.load(fromByteOffset: 0x14, as: UInt32.self),
                // 9450.2's callback record is the 96-byte path-frame record:
                // identifier is +0x10, state +0x14, normalized x/y +0x20/+0x24
                // and total capacitance +0x30. +0x18 is a reserved/auxiliary
                // field that is commonly identical across every contact; using
                // it as the identifier made all real three-finger frames fail
                // the duplicate-ID validation below.
                id: record.load(fromByteOffset: 0x10, as: Int32.self),
                x: record.load(fromByteOffset: 0x20, as: Float.self),
                y: record.load(fromByteOffset: 0x24, as: Float.self),
                zTotal: record.load(fromByteOffset: 0x30, as: Float.self)
            )
        }
        return validatedFrame(from: records)
    }

    static func decode(
        rawTouches: UnsafeRawPointer?,
        count: Int
    ) -> [RawTrackpadContact]? {
        decodeFrame(rawTouches: rawTouches, count: count)?.contacts
    }

    static func validatedContacts(
        from records: [RawTouchRecord]
    ) -> [RawTrackpadContact]? {
        validatedFrame(from: records)?.contacts
    }

    static func validatedFrame(
        from records: [RawTouchRecord]
    ) -> RawDecodedTouchFrame? {
        var contacts: [RawTrackpadContact] = []
        contacts.reserveCapacity(min(records.count, 5))
        var seenIDs = Set<Int32>()
        var hasUncertainTouchRecord = false

        for record in records {
            guard record.state <= 7,
                  record.x.isFinite,
                  record.y.isFinite,
                  record.zTotal.isFinite,
                  (-0.1...1.1).contains(record.x),
                  (-0.1...1.1).contains(record.y) else {
                return nil
            }
            guard record.state == 3 || record.state == 4 else {
                continue
            }
            guard record.zTotal > 0.001 else {
                hasUncertainTouchRecord = true
                continue
            }
            guard seenIDs.insert(record.id).inserted else {
                return nil
            }
            contacts.append(
                RawTrackpadContact(
                    id: record.id,
                    x: Double(record.x),
                    y: Double(record.y)
                )
            )
        }
        return RawDecodedTouchFrame(
            contacts: contacts,
            isDefiniteAllUp: contacts.isEmpty && !hasUncertainTouchRecord,
            hasUncertainTouchRecord: hasUncertainTouchRecord
        )
    }
}

/// Invalid private frames poison the current physical sequence. Reducers rearm
/// only after a validated frame contains no physical contacts, preventing a
/// malformed/duplicate frame from preserving an older motion baseline.
struct RawGestureFrameReducer {
    private var pinchReducer = FiveFingerPinchReducer()
    private var pageReducer = LocalTouchPager()
    private var reportedExactTwoForSequence = false
    private var pinchIsAwaitingRelease = false
    private var lastPinchHeartbeatTimestamp: TimeInterval?
    private var sequenceIsInvalid = false
    private var lastCallbackTimestamp: TimeInterval?
    private let inferredAllUpInterval: TimeInterval = 0.35
    private let pinchHeartbeatInterval: TimeInterval = 0.10

    mutating func consume(
        contacts decodedContacts: [RawTrackpadContact]?,
        timestamp: TimeInterval,
        blocksPageGesture: Bool = false
    ) -> RawGestureAction? {
        let frame = decodedContacts.map {
            RawDecodedTouchFrame(
                contacts: $0,
                isDefiniteAllUp: $0.isEmpty,
                hasUncertainTouchRecord: false
            )
        }
        return consume(
            frame: frame,
            timestamp: timestamp,
            blocksPageGesture: blocksPageGesture
        )
    }

    mutating func consume(
        frame decodedFrame: RawDecodedTouchFrame?,
        timestamp: TimeInterval,
        blocksPageGesture: Bool = false
    ) -> RawGestureAction? {
        let callbackGap = lastCallbackTimestamp.map { timestamp - $0 } ?? 0
        lastCallbackTimestamp = timestamp

        guard let decodedFrame else {
            sequenceIsInvalid = true
            pinchReducer.reset()
            let cancelledEvents = pageReducer.consume(
                [],
                phase: .cancelled,
                timestamp: timestamp,
                toleratesTransientDropout: true
            )
            reportedExactTwoForSequence = false
            let hadPendingPinch = pinchIsAwaitingRelease
            pinchIsAwaitingRelease = false
            lastPinchHeartbeatTimestamp = nil
            guard !cancelledEvents.isEmpty || hadPendingPinch else { return nil }
            return RawGestureAction(
                pageEvents: cancelledEvents,
                pinchDirection: nil,
                exactTwoSequenceBegan: false,
                pinchSequenceActivity: false,
                pinchSequenceBoundary: hadPendingPinch ? .cancelled : nil
            )
        }

        if decodedFrame.isDefiniteAllUp {
            let endedEvents = pageReducer.consume(
                [],
                phase: .ended,
                timestamp: timestamp,
                toleratesTransientDropout: true
            )
            sequenceIsInvalid = false
            pinchReducer.reset()
            reportedExactTwoForSequence = false
            let hadPendingPinch = pinchIsAwaitingRelease
            pinchIsAwaitingRelease = false
            lastPinchHeartbeatTimestamp = nil
            guard !endedEvents.isEmpty || hadPendingPinch else { return nil }
            return RawGestureAction(
                pageEvents: endedEvents,
                pinchDirection: nil,
                exactTwoSequenceBegan: false,
                pinchSequenceActivity: false,
                pinchSequenceBoundary: hadPendingPinch ? .released : nil
            )
        }

        // MultitouchSupport normally emits frames continuously while contacts
        // remain down. A long callback gap followed by non-empty contacts is a
        // conservative synthetic all-up boundary for the occasional device/OS
        // path that omits the final empty frame.
        var prefixEvents: [TrackpadPageGestureEvent] = []
        var pinchSequenceBoundary: RawPinchSequenceBoundary?
        if callbackGap >= inferredAllUpInterval {
            prefixEvents = pageReducer.consume(
                [],
                phase: .cancelled,
                timestamp: timestamp,
                toleratesTransientDropout: true
            )
            pinchReducer.reset()
            sequenceIsInvalid = false
            reportedExactTwoForSequence = false
            if pinchIsAwaitingRelease {
                pinchSequenceBoundary = .cancelled
                pinchIsAwaitingRelease = false
                lastPinchHeartbeatTimestamp = nil
            }
        }

        guard !sequenceIsInvalid else { return nil }
        // Ignore the whole uncertain frame. Feeding a partial set into the page
        // reducer was the main cause of intermittent permanent blocking.
        if decodedFrame.hasUncertainTouchRecord { return nil }

        let contacts = decodedFrame.contacts.map { ($0.id, $0.x, $0.y) }
        let samples = decodedFrame.contacts.map {
            TrackpadTouchSample(id: Int($0.id), x: $0.x, y: $0.y)
        }
        let pinchDirection = pinchReducer.consume(contacts: contacts)
        if pinchDirection != nil {
            pinchIsAwaitingRelease = true
            lastPinchHeartbeatTimestamp = timestamp
        }
        let pinchSequenceActivity: Bool
        if pinchIsAwaitingRelease,
           pinchDirection == nil,
           timestamp - (lastPinchHeartbeatTimestamp ?? timestamp)
                >= pinchHeartbeatInterval {
            pinchSequenceActivity = true
            lastPinchHeartbeatTimestamp = timestamp
        } else {
            pinchSequenceActivity = false
        }
        let pageEvents = pageReducer.consume(
            samples,
            phase: .changed,
            timestamp: timestamp,
            toleratesTransientDropout: true,
            blocksPageGesture: blocksPageGesture,
            diagnosticSource: .raw
        )
        let exactTwoSequenceBegan = pageEvents.contains {
            $0.phase == .began && $0.touchCount == 2
        } && !reportedExactTwoForSequence
        if exactTwoSequenceBegan {
            reportedExactTwoForSequence = true
        }

        guard pinchDirection != nil
                || pinchSequenceActivity
                || pinchSequenceBoundary != nil
                || !pageEvents.isEmpty
                || !prefixEvents.isEmpty else {
            return nil
        }
        return RawGestureAction(
            pageEvents: prefixEvents + pageEvents,
            pinchDirection: pinchDirection,
            exactTwoSequenceBegan: exactTwoSequenceBegan,
            pinchSequenceActivity: pinchSequenceActivity,
            pinchSequenceBoundary: pinchSequenceBoundary
        )
    }
}

/// A small state machine that sees only copied scalar values from the private
/// callback. It can retain pair-distance history while the fifth finger is
/// landing, but emits only after two exact-five frames. This recovers the common
/// case where the hand starts closing before all five contacts are reported,
/// without allowing three/four-finger input to trigger an action.
struct FiveFingerPinchReducer {
    private struct FingerPair: Hashable {
        let lower: Int32
        let upper: Int32

        init(_ first: Int32, _ second: Int32) {
            lower = min(first, second)
            upper = max(first, second)
        }
    }

    private var trackedIDs = Set<Int32>()
    private var minimumRadius: Double?
    private var maximumRadius: Double?
    private var maximumPairDistances: [FingerPair: Double] = [:]
    private var stableFrameCount = 0
    private var missingFrameCount = 0
    private var didTrigger = false
    private var sequenceIsBlocked = false

    private let toleratedMissingFrameCount = 20

    mutating func consume(
        contacts: [(id: Int32, x: Double, y: Double)]
    ) -> RawPinchDirection? {
        guard !contacts.isEmpty else {
            reset()
            return nil
        }
        guard !didTrigger, !sequenceIsBlocked else { return nil }

        let ids = Set(contacts.map(\.id))
        guard ids.count == contacts.count, contacts.count <= 5 else {
            sequenceIsBlocked = true
            return nil
        }

        let historicalContraction = contractionAgainstPairHistory(contacts)

        guard contacts.count == 5 else {
            if !trackedIDs.isEmpty {
                missingFrameCount += 1
                if missingFrameCount > toleratedMissingFrameCount {
                    resetTrackingBaseline(clearPairHistory: true)
                }
            }
            updatePairDistanceHistory(with: contacts)
            return nil
        }

        let radius = Self.rootMeanSquareRadius(of: contacts)
        guard radius > 0.001 else { return nil }

        if trackedIDs == ids,
           let minimumRadius,
           let maximumRadius {
            stableFrameCount += 1
            self.minimumRadius = min(minimumRadius, radius)
            self.maximumRadius = max(maximumRadius, radius)
        } else {
            trackedIDs = ids
            self.minimumRadius = radius
            self.maximumRadius = radius
            stableFrameCount = 1
        }

        missingFrameCount = 0
        updatePairDistanceHistory(with: contacts)
        guard stableFrameCount >= 2,
              let updatedMinimum = self.minimumRadius,
              let updatedMaximum = self.maximumRadius else { return nil }

        let radiusShowsInwardMotion = radius / updatedMaximum <= 0.84
            && updatedMaximum - radius >= 0.018
        let pairHistoryShowsInwardMotion = historicalContraction.map {
            $0.ratio <= 0.84 && $0.distance >= 0.018
        } ?? false
        if radiusShowsInwardMotion || pairHistoryShowsInwardMotion {
            didTrigger = true
            return .inward
        }
        if radius / updatedMinimum >= 1.19,
           radius - updatedMinimum >= 0.018 {
            didTrigger = true
            return .outward
        }
        return nil
    }

    mutating func reset() {
        resetTrackingBaseline(clearPairHistory: true)
        didTrigger = false
        sequenceIsBlocked = false
    }

    private mutating func resetTrackingBaseline(clearPairHistory: Bool) {
        trackedIDs.removeAll(keepingCapacity: true)
        minimumRadius = nil
        maximumRadius = nil
        stableFrameCount = 0
        missingFrameCount = 0
        if clearPairHistory {
            maximumPairDistances.removeAll(keepingCapacity: true)
        }
    }

    private mutating func updatePairDistanceHistory(
        with contacts: [(id: Int32, x: Double, y: Double)]
    ) {
        guard contacts.count >= 3 else { return }
        for firstIndex in 0..<(contacts.count - 1) {
            for secondIndex in (firstIndex + 1)..<contacts.count {
                let first = contacts[firstIndex]
                let second = contacts[secondIndex]
                let distance = hypot(first.x - second.x, first.y - second.y)
                guard distance.isFinite else { continue }
                let pair = FingerPair(first.id, second.id)
                maximumPairDistances[pair] = max(
                    maximumPairDistances[pair] ?? 0,
                    distance
                )
            }
        }
    }

    private func contractionAgainstPairHistory(
        _ contacts: [(id: Int32, x: Double, y: Double)]
    ) -> (ratio: Double, distance: Double)? {
        guard contacts.count >= 3 else { return nil }
        var ratios: [Double] = []
        var distances: [Double] = []
        for firstIndex in 0..<(contacts.count - 1) {
            for secondIndex in (firstIndex + 1)..<contacts.count {
                let first = contacts[firstIndex]
                let second = contacts[secondIndex]
                let pair = FingerPair(first.id, second.id)
                guard let baseline = maximumPairDistances[pair],
                      baseline >= 0.035 else { continue }
                let current = hypot(first.x - second.x, first.y - second.y)
                guard current.isFinite else { continue }
                ratios.append(current / baseline)
                distances.append(baseline - current)
            }
        }
        guard ratios.count >= 3 else { return nil }
        ratios.sort()
        distances.sort()
        return (
            ratios[ratios.count / 2],
            distances[distances.count / 2]
        )
    }

    private static func rootMeanSquareRadius(
        of contacts: [(id: Int32, x: Double, y: Double)]
    ) -> Double {
        let count = Double(contacts.count)
        let centerX = contacts.reduce(0) { $0 + $1.x } / count
        let centerY = contacts.reduce(0) { $0 + $1.y } / count
        let meanSquare = contacts.reduce(0) { total, contact in
            let dx = contact.x - centerX
            let dy = contact.y - centerY
            return total + dx * dx + dy * dy
        } / count
        return sqrt(meanSquare)
    }
}

enum PublicPinchTouchEvidence: String, Equatable, Sendable {
    case fiveOrMore = "five-or-more"
    case unavailableFallback = "unavailable-fallback"
    case unavailableIgnored = "unavailable-ignored"
    case insufficient = "insufficient"
}

/// Public AppKit health fallback kept alongside the version-locked raw bridge.
/// System-owned gestures can reach a global monitor without an NSTouch set.
/// An unavailable count is therefore accepted only while raw input has no
/// recent two-or-more-contact evidence, and uses a stricter inward-only threshold.
struct PublicFiveFingerMagnifyReducer {
    private var isActive = false
    private var didTrigger = false
    private var sequenceIsBlocked = false
    private var accumulatedMagnification = 0.0

    mutating func consume(
        magnification: Double,
        touchCount: Int,
        phase: NSEvent.Phase,
        allowsUnavailableTouchCount: Bool = false,
        blocksUnavailableTouchCount: Bool = false
    ) -> RawPinchDirection? {
        if phase.contains(.began) {
            reset()
            isActive = true
        }

        let evidence = Self.touchEvidence(
            touchCount: touchCount,
            allowsUnavailableTouchCount: allowsUnavailableTouchCount
        )
        if !isActive,
           evidence == .fiveOrMore || evidence == .unavailableFallback {
            isActive = true
        }
        if evidence == .insufficient
            || (touchCount == 0 && blocksUnavailableTouchCount) {
            // Once AppKit or the raw bridge proves this is a two-to-four-contact
            // magnify, a later count-unavailable tail must not reopen it as a
            // five-finger fallback candidate.
            sequenceIsBlocked = true
        }

        var result: RawPinchDirection?
        if isActive,
           !didTrigger,
           !sequenceIsBlocked,
           magnification.isFinite {
            switch evidence {
            case .fiveOrMore, .unavailableFallback:
                accumulatedMagnification += magnification
            case .unavailableIgnored, .insufficient:
                break
            }

            let inwardThreshold = evidence == .unavailableFallback
                ? -0.22
                : -0.10
            if accumulatedMagnification <= inwardThreshold {
                didTrigger = true
                result = .inward
            } else if evidence == .fiveOrMore,
                      accumulatedMagnification >= 0.12 {
                didTrigger = true
                result = .outward
            }
        }

        if phase.contains(.ended) || phase.contains(.cancelled) {
            reset()
        }
        return result
    }

    mutating func reset() {
        isActive = false
        didTrigger = false
        sequenceIsBlocked = false
        accumulatedMagnification = 0
    }

    static func touchEvidence(
        touchCount: Int,
        allowsUnavailableTouchCount: Bool
    ) -> PublicPinchTouchEvidence {
        if touchCount >= 5 {
            return .fiveOrMore
        }
        if touchCount == 0 {
            return allowsUnavailableTouchCount
                ? .unavailableFallback
                : .unavailableIgnored
        }
        return .insufficient
    }
}

/// Runtime health is based on the framework-supplied callback count, before
/// any private-record decoding. It cannot prove gesture geometry; it only says
/// whether this bridge recently demonstrated five contacts or contradicted an
/// unavailable-count fallback with a definite two-to-four-contact frame.
struct RawFiveFingerHealth: Equatable, Sendable {
    private(set) var maximumRecordCount = 0
    private(set) var lastExactFiveTimestamp: TimeInterval?
    private(set) var lastTwoToFourTimestamp: TimeInterval?

    mutating func observe(
        recordCount: Int,
        at timestamp: TimeInterval
    ) {
        guard recordCount >= 0, timestamp.isFinite else { return }
        maximumRecordCount = max(maximumRecordCount, recordCount)
        if recordCount >= 5 {
            lastExactFiveTimestamp = timestamp
        } else if (2...4).contains(recordCount) {
            lastTwoToFourTimestamp = timestamp
        }
    }

    func hasRecentExactFive(
        at timestamp: TimeInterval,
        maximumAge: TimeInterval
    ) -> Bool {
        guard timestamp.isFinite,
              maximumAge >= 0,
              let lastExactFiveTimestamp else { return false }
        let age = timestamp - lastExactFiveTimestamp
        return age >= 0 && age <= maximumAge
    }

    func hasRecentTwoToFour(
        at timestamp: TimeInterval,
        maximumAge: TimeInterval
    ) -> Bool {
        guard timestamp.isFinite,
              maximumAge >= 0,
              let lastTwoToFourTimestamp else { return false }
        let age = timestamp - lastTwoToFourTimestamp
        return age >= 0 && age <= maximumAge
    }
}

/// Dynamically loads the system multitouch bridge only for the ABI verified on
/// this Mac. Unknown versions fail closed, leaving keyboard shortcuts intact.
private final class RawMultitouchBridge: @unchecked Sendable {
    private typealias DeviceRef = UnsafeMutableRawPointer
    private typealias FrameCallback = @convention(c) (
        DeviceRef?, UnsafeRawPointer?, Int, Double, Int, UnsafeMutableRawPointer?
    ) -> Void
    private typealias CreateDefault = @convention(c) () -> DeviceRef?
    private typealias RegisterWithRefcon = @convention(c) (
        DeviceRef?, FrameCallback?, UnsafeMutableRawPointer?
    ) -> Bool
    private typealias Unregister = @convention(c) (DeviceRef?, FrameCallback?) -> Bool
    private typealias Start = @convention(c) (DeviceRef?, Int32) -> Int32
    private typealias Stop = @convention(c) (DeviceRef?) -> Int32
    private typealias Release = @convention(c) (DeviceRef?) -> Void

    private static let frameworkPath =
        "/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport"
    private static let infoPlistPath =
        "/System/Library/PrivateFrameworks/MultitouchSupport.framework/Resources/Info.plist"
    private static let verifiedFrameworkVersions: Set<String> = ["9450.2"]

    private let library: UnsafeMutableRawPointer
    private let device: DeviceRef
    private let context: CallbackContext
    private let contextPointer: UnsafeMutableRawPointer
    private let unregister: Unregister
    private let stopDevice: Stop
    private let releaseDevice: Release
    private var isStopped = false

    init?(onAction: @escaping @Sendable (RawGestureAction) -> Void) {
        guard Self.hasVerifiedABI else {
            LaunchGestureDiagnostics.log(
                "raw unavailable: os=\(ProcessInfo.processInfo.operatingSystemVersionString) framework=\(Self.frameworkVersion ?? "unknown")"
            )
            return nil
        }
        guard let library = dlopen(Self.frameworkPath, RTLD_NOW | RTLD_LOCAL) else {
            LaunchGestureDiagnostics.log("raw unavailable: dlopen failed")
            return nil
        }
        guard let createSymbol = dlsym(library, "MTDeviceCreateDefault"),
              let registerSymbol = dlsym(library, "MTRegisterContactFrameCallbackWithRefcon"),
              let unregisterSymbol = dlsym(library, "MTUnregisterContactFrameCallback"),
              let startSymbol = dlsym(library, "MTDeviceStart"),
              let stopSymbol = dlsym(library, "MTDeviceStop"),
              let releaseSymbol = dlsym(library, "MTDeviceRelease") else {
            LaunchGestureDiagnostics.log("raw unavailable: required symbol missing")
            dlclose(library)
            return nil
        }

        let create = unsafeBitCast(createSymbol, to: CreateDefault.self)
        let register = unsafeBitCast(registerSymbol, to: RegisterWithRefcon.self)
        let unregister = unsafeBitCast(unregisterSymbol, to: Unregister.self)
        let start = unsafeBitCast(startSymbol, to: Start.self)
        let stop = unsafeBitCast(stopSymbol, to: Stop.self)
        let release = unsafeBitCast(releaseSymbol, to: Release.self)

        guard let device = create() else {
            LaunchGestureDiagnostics.log("raw unavailable: no default device")
            dlclose(library)
            return nil
        }

        let context = CallbackContext(onAction: onAction)
        let contextPointer = Unmanaged.passRetained(context).toOpaque()
        guard register(device, Self.frameCallback, contextPointer) else {
            LaunchGestureDiagnostics.log("raw unavailable: callback registration failed")
            release(device)
            Unmanaged<CallbackContext>.fromOpaque(contextPointer).release()
            dlclose(library)
            return nil
        }
        let startResult = start(device, 0)
        guard startResult == 0 else {
            LaunchGestureDiagnostics.log("raw unavailable: device start=\(startResult)")
            // Registration can race with MTDeviceStart returning an error. Make
            // the refcon inert before releasing device-owned frame storage, then
            // wait for every callback that already entered to finish decoding.
            context.deactivate()
            _ = unregister(device, Self.frameCallback)
            _ = stop(device)
            context.waitForCallbacksToDrain()
            release(device)
            // A registered callback may already have been fetched by the
            // framework. Keep its tiny refcon and the shared-cache image alive
            // until process exit rather than risking a late callback UAF.
            return nil
        }

        self.library = library
        self.device = device
        self.context = context
        self.contextPointer = contextPointer
        self.unregister = unregister
        self.stopDevice = stop
        self.releaseDevice = release
        LaunchGestureDiagnostics.log(
            "raw active: framework=\(Self.frameworkVersion ?? "unknown") device-start=0"
        )
    }

    deinit {
        shutdown()
    }

    func shutdown() {
        guard !isStopped else { return }
        isStopped = true
        context.deactivate()
        _ = unregister(device, Self.frameCallback)
        _ = stopDevice(device)
        context.waitForCallbacksToDrain()
        releaseDevice(device)
        // Intentionally retain the small callback context and dynamic image
        // until process exit. The private API does not document MTDeviceStop as
        // a callback barrier, so releasing either here could create a UAF.
    }

    private static var hasVerifiedABI: Bool {
        guard ProcessInfo.processInfo.operatingSystemVersion.majorVersion == 26,
              let version = frameworkVersion else {
            return false
        }
        return verifiedFrameworkVersions.contains(version)
    }

    private static var frameworkVersion: String? {
        guard let data = FileManager.default.contents(atPath: infoPlistPath),
              let plist = try? PropertyListSerialization.propertyList(
                from: data,
                options: [],
                format: nil
              ) as? [String: Any],
              let version = plist["CFBundleVersion"] as? String else {
            return nil
        }
        return version
    }

    private static let frameCallback: FrameCallback = {
        _, rawTouches, count, timestamp, _, rawContext in
        guard let rawContext else { return }
        let context = Unmanaged<CallbackContext>
            .fromOpaque(rawContext)
            .takeUnretainedValue()
        guard context.enterCallback() else { return }
        defer { context.leaveCallback() }
        context.process(rawTouches: rawTouches, count: count, timestamp: timestamp)
    }

    private final class CallbackContext: @unchecked Sendable {
        private let condition = NSCondition()
        private let onAction: @Sendable (RawGestureAction) -> Void
        private var gestureReducer = RawGestureFrameReducer()
        private var active = true
        private var callbacksInFlight = 0
        private var didLogFirstCallback = false
        private var didLogFirstDecodedFrame = false
        private var didLogFirstExactTwoFrame = false
        private var didLogFirstPageBegin = false
        private var rawFiveFingerHealth = RawFiveFingerHealth()
        private var didLogFirstExactFiveFrame = false
        private var lastDiagnosticRecordCount: Int?
        private var lastDiagnosticDecodedCount: Int?
        private var lastDiagnosticFrameWasInvalid = false
        private var lastDiagnosticFrameWasUncertain = false

        init(onAction: @escaping @Sendable (RawGestureAction) -> Void) {
            self.onAction = onAction
        }

        func enterCallback() -> Bool {
            condition.lock()
            defer { condition.unlock() }
            guard active else { return false }
            callbacksInFlight += 1
            return true
        }

        func leaveCallback() {
            condition.lock()
            callbacksInFlight -= 1
            if callbacksInFlight == 0 {
                condition.broadcast()
            }
            condition.unlock()
        }

        func deactivate() {
            condition.lock()
            active = false
            condition.unlock()
        }

        func waitForCallbacksToDrain() {
            condition.lock()
            while callbacksInFlight > 0 {
                condition.wait()
            }
            condition.unlock()
        }

        func hasRecentExactFive(
            at timestamp: TimeInterval,
            maximumAge: TimeInterval
        ) -> Bool {
            condition.lock()
            defer { condition.unlock() }
            return rawFiveFingerHealth.hasRecentExactFive(
                at: timestamp,
                maximumAge: maximumAge
            )
        }

        func hasRecentTwoToFour(
            at timestamp: TimeInterval,
            maximumAge: TimeInterval
        ) -> Bool {
            condition.lock()
            defer { condition.unlock() }
            return rawFiveFingerHealth.hasRecentTwoToFour(
                at: timestamp,
                maximumAge: maximumAge
            )
        }

        func process(
            rawTouches: UnsafeRawPointer?,
            count: Int,
            timestamp: TimeInterval
        ) {
            let decodedFrame = RawTouchContactDecoder.decodeFrame(
                rawTouches: rawTouches,
                count: count
            )

            var diagnosticMessages: [String] = []
            condition.lock()
            rawFiveFingerHealth.observe(
                recordCount: count,
                at: ProcessInfo.processInfo.systemUptime
            )
            if LaunchGestureDiagnostics.isEnabled {
                let decodedCount = decodedFrame?.contacts.count
                let isInvalid = decodedFrame == nil
                let isUncertain = decodedFrame?.hasUncertainTouchRecord == true
                if lastDiagnosticRecordCount != count
                    || lastDiagnosticDecodedCount != decodedCount
                    || lastDiagnosticFrameWasInvalid != isInvalid
                    || lastDiagnosticFrameWasUncertain != isUncertain {
                    diagnosticMessages.append(
                        "touch source=raw records=\(count) count=\(decodedCount.map(String.init) ?? "invalid") phase=frame uncertain=\(isUncertain ? 1 : 0)"
                    )
                    lastDiagnosticRecordCount = count
                    lastDiagnosticDecodedCount = decodedCount
                    lastDiagnosticFrameWasInvalid = isInvalid
                    lastDiagnosticFrameWasUncertain = isUncertain
                }
            }
            if LaunchGestureDiagnostics.isEnabled, !didLogFirstCallback {
                didLogFirstCallback = true
                diagnosticMessages.append("raw callback received: record-count=\(count)")
            }
            if LaunchGestureDiagnostics.isEnabled,
               decodedFrame != nil,
               !didLogFirstDecodedFrame {
                didLogFirstDecodedFrame = true
                diagnosticMessages.append(
                    "raw decoder accepted first frame: contacts=\(decodedFrame?.contacts.count ?? 0)"
                )
            }
            if LaunchGestureDiagnostics.isEnabled,
               count >= 5,
               !didLogFirstExactFiveFrame {
                didLogFirstExactFiveFrame = true
                diagnosticMessages.append(
                    "raw health observed first exact-five record frame"
                )
            }
            if LaunchGestureDiagnostics.isEnabled,
               decodedFrame?.contacts.count == 2,
               !didLogFirstExactTwoFrame {
                didLogFirstExactTwoFrame = true
                diagnosticMessages.append("raw decoder accepted exact-two frame")
            }
            let action = gestureReducer.consume(
                frame: decodedFrame,
                timestamp: timestamp,
                blocksPageGesture: NSEvent.pressedMouseButtons & 1 != 0
            )
            if LaunchGestureDiagnostics.isEnabled,
               action?.pageEvents.contains(where: { $0.phase == .began }) == true,
               !didLogFirstPageBegin {
                didLogFirstPageBegin = true
                diagnosticMessages.append("raw reducer emitted first page begin")
            }
            let shouldDeliver = active && action != nil
            condition.unlock()

            for message in diagnosticMessages {
                LaunchGestureDiagnostics.log(message)
            }

            if shouldDeliver, let action {
                onAction(action)
            }
        }
    }

    func hasRecentExactFive(
        at timestamp: TimeInterval,
        maximumAge: TimeInterval
    ) -> Bool {
        context.hasRecentExactFive(
            at: timestamp,
            maximumAge: maximumAge
        )
    }

    func hasRecentTwoToFour(
        at timestamp: TimeInterval,
        maximumAge: TimeInterval
    ) -> Bool {
        context.hasRecentTwoToFour(
            at: timestamp,
            maximumAge: maximumAge
        )
    }
}

/// Pure buffering policy used by the main-queue relay and gesture checks.
struct RawGestureActionBuffer {
    private var actions: [RawGestureAction] = []

    var count: Int { actions.count }

    mutating func enqueue(_ action: RawGestureAction) {
        if Self.isChangeOnly(action),
           let last = actions.last,
           Self.isChangeOnly(last),
           last.pageEvents.first?.sequenceID == action.pageEvents.first?.sequenceID {
            actions[actions.count - 1] = action
        } else {
            actions.append(action)
        }
    }

    mutating func drain() -> [RawGestureAction] {
        let result = actions
        actions.removeAll(keepingCapacity: true)
        return result
    }

    private static func isChangeOnly(_ action: RawGestureAction) -> Bool {
        action.pinchDirection == nil
            && !action.exactTwoSequenceBegan
            && !action.pinchSequenceActivity
            && action.pinchSequenceBoundary == nil
            && action.pageEvents.count == 1
            && action.pageEvents[0].phase == .changed
    }
}

/// Coalesces high-frequency raw motion frames into at most one pending main
/// queue delivery. Begin/end/cancel and pinch actions remain ordered, while
/// consecutive change-only frames for the same sequence collapse to the latest
/// sample. This prevents a 100–130 Hz touch stream from starving SwiftUI.
private final class RawGestureActionDelivery: @unchecked Sendable {
    typealias Handler = @MainActor @Sendable ([RawGestureAction]) -> Void

    private let lock = NSLock()
    private let handler: Handler
    private var buffer = RawGestureActionBuffer()
    private var deliveryIsScheduled = false
    private var isActive = true

    init(handler: @escaping Handler) {
        self.handler = handler
    }

    func submit(_ action: RawGestureAction) {
        lock.lock()
        guard isActive else {
            lock.unlock()
            return
        }

        buffer.enqueue(action)

        let shouldSchedule = !deliveryIsScheduled
        deliveryIsScheduled = true
        lock.unlock()

        if shouldSchedule {
            DispatchQueue.main.async { [weak self] in
                self?.drain()
            }
        }
    }

    func deactivate() {
        lock.lock()
        isActive = false
        _ = buffer.drain()
        lock.unlock()
    }

    @MainActor
    private func drain() {
        lock.lock()
        let actions = buffer.drain()
        deliveryIsScheduled = false
        let shouldDeliver = isActive
        lock.unlock()

        if shouldDeliver, !actions.isEmpty {
            handler(actions)
        }
    }

}

@MainActor
final class TrackpadGestureManager: @unchecked Sendable {
    typealias Handler = @MainActor @Sendable () -> Void
    typealias VisibilityProvider = @MainActor @Sendable () -> Bool
    typealias PageGestureHandler = @MainActor @Sendable (TrackpadPageGestureEvent) -> Void

    private let isLauncherVisible: VisibilityProvider
    private let isLauncherInteractive: VisibilityProvider
    private let showLauncher: Handler
    private let hideLauncher: Handler
    private let handlePageGesture: PageGestureHandler

    private var rawBridge: RawMultitouchBridge?
    private var rawActionDelivery: RawGestureActionDelivery?
    private var globalMagnifyMonitor: Any?
    private var localMagnifyMonitor: Any?
    private var localPrimaryButtonMonitor: Any?
    private var publicPinchReducer = PublicFiveFingerMagnifyReducer()
    private var pinchSourceArbiter = TrackpadPinchSourceArbiter()
    private var deferredPinchActivation = DeferredPinchActivationState()
    private var pinchFallbackTask: Task<Void, Never>?
    private var pinchPresentationTask: Task<Void, Never>?
    private var pinchTaskGeneration: UInt64 = 0
    private let pinchFallbackTimeout: TimeInterval = 0.34
    private let rawPinchHealthWindow: TimeInterval = 0.30
    private var touchPager = LocalTouchPager()
    private var pageSourceArbiter = TrackpadPageSourceArbiter()
    private var pendingLocalPageGesture = PendingLocalPageGestureBuffer()
    private var pendingLocalPageTask: Task<Void, Never>?
    private var pendingLocalPageGeneration: UInt64 = 0
    private let localPageGraceDuration: TimeInterval = 0.045
    private var deliveredSequenceIDs = Set<UInt64>()
    private var pageInactivityTracker = PageGestureInactivityTracker()
    private var pageInactivityTask: Task<Void, Never>?
    private var pageInactivityGeneration: UInt64 = 0
    private let pageInactivityTimeout: TimeInterval = 0.65
    private var didLogLocalExactTwoFrame = false
    private var lastLocalDiagnosticCount: Int?
    private var currentLocalTouchCount = 0
    private var rawOwnedLocalPageQuarantine = RawOwnedLocalPageQuarantine()
    private var primaryButtonRawDeliveryQuarantine =
        PrimaryButtonPageDeliveryQuarantine()
    private var primaryButtonLocalTouchLatch =
        PrimaryButtonTouchSequenceLatch()

    var isUsingRawTouchPagination: Bool { rawBridge != nil }

    init(
        isLauncherVisible: @escaping VisibilityProvider,
        isLauncherInteractive: @escaping VisibilityProvider,
        showLauncher: @escaping Handler,
        hideLauncher: @escaping Handler,
        handlePageGesture: @escaping PageGestureHandler
    ) {
        self.isLauncherVisible = isLauncherVisible
        self.isLauncherInteractive = isLauncherInteractive
        self.showLauncher = showLauncher
        self.hideLauncher = hideLauncher
        self.handlePageGesture = handlePageGesture
    }

    deinit {
        rawBridge?.shutdown()
    }

    func start() {
        stop()

        let delivery = RawGestureActionDelivery { [weak self] actions in
            for action in actions {
                self?.handleRawAction(action)
            }
        }
        rawActionDelivery = delivery
        rawBridge = RawMultitouchBridge { [weak delivery] action in
            delivery?.submit(action)
        }
        // A private device can start successfully and later become silent (most
        // commonly across sleep/wake). Keep the public stream alive as a health
        // fallback; sequence ownership below prevents its terminal events from
        // cancelling an independently recognized raw pinch.
        installPublicFiveFingerFallback()
        installPrimaryButtonMonitor()
        LaunchGestureDiagnostics.log(
            "manager started: raw-bridge=\(rawBridge == nil ? "unavailable" : "created") local-touch=enabled diagnostic-path=\(LaunchGestureDiagnostics.outputPath ?? "stderr")"
        )
    }

    func stop() {
        if let globalMagnifyMonitor {
            NSEvent.removeMonitor(globalMagnifyMonitor)
            self.globalMagnifyMonitor = nil
        }
        if let localMagnifyMonitor {
            NSEvent.removeMonitor(localMagnifyMonitor)
            self.localMagnifyMonitor = nil
        }
        if let localPrimaryButtonMonitor {
            NSEvent.removeMonitor(localPrimaryButtonMonitor)
            self.localPrimaryButtonMonitor = nil
        }
        publicPinchReducer.reset()
        pinchSourceArbiter.reset()
        applyDeferredPinchCommand(deferredPinchActivation.cancel())
        cancelDeferredPinchTasks()
        rawActionDelivery?.deactivate()
        rawActionDelivery = nil
        rawBridge?.shutdown()
        rawBridge = nil
        touchPager.reset()
        pageSourceArbiter.reset()
        discardPendingLocalPageGesture()
        cancelPageInactivityWatchdog()
        pageInactivityTracker.reset()
        deliveredSequenceIDs.removeAll(keepingCapacity: false)
        didLogLocalExactTwoFrame = false
        lastLocalDiagnosticCount = nil
        currentLocalTouchCount = 0
        rawOwnedLocalPageQuarantine.reset()
        primaryButtonRawDeliveryQuarantine.reset()
        primaryButtonLocalTouchLatch.reset()
        LaunchGestureDiagnostics.flush()
    }

    private func installPublicFiveFingerFallback() {
        globalMagnifyMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: .magnify
        ) { [weak self] event in
            Task { @MainActor [weak self] in
                self?.handlePublicMagnify(event)
            }
        }
        localMagnifyMonitor = NSEvent.addLocalMonitorForEvents(
            matching: .magnify
        ) { [weak self] event in
            Task { @MainActor [weak self] in
                self?.handlePublicMagnify(event)
            }
            return event
        }
    }

    private func installPrimaryButtonMonitor() {
        localPrimaryButtonMonitor = NSEvent.addLocalMonitorForEvents(
            matching: .leftMouseDown
        ) { [weak self] event in
            // A local monitor runs synchronously in this application's main
            // event loop. Cancel before SwiftUI receives mouseDown and starts a
            // drag, rather than leaving one frame in which paging can advance.
            MainActor.assumeIsolated {
                self?.primaryPointerButtonDidPress()
            }
            return event
        }
    }

    private func handlePublicMagnify(_ event: NSEvent) {
        let touchingTouchCount = event.touches(
            matching: .touching,
            in: nil
        ).count
        let allTouchCount = event.allTouches().count
        // A system-owned gesture can redact one collection but not the other.
        // Treat either collection as affirmative evidence and use the
        // count-unavailable fallback only when both remain empty.
        let touchCount = max(touchingTouchCount, allTouchCount)
        let isCancelled = event.phase.contains(.cancelled)
        let isEnded = event.phase.contains(.ended)
        let now = ProcessInfo.processInfo.systemUptime
        let rawHasRecentExactFive = rawBridge?.hasRecentExactFive(
            at: now,
            maximumAge: rawPinchHealthWindow
        ) == true
        let rawHasRecentTwoToFour = rawBridge?.hasRecentTwoToFour(
            at: now,
            maximumAge: rawPinchHealthWindow
        ) == true
        let allowsUnavailableTouchCount = !rawHasRecentExactFive
            && !rawHasRecentTwoToFour
        let touchEvidence = PublicFiveFingerMagnifyReducer.touchEvidence(
            touchCount: touchCount,
            allowsUnavailableTouchCount: allowsUnavailableTouchCount
        )
        let direction = publicPinchReducer.consume(
            magnification: event.magnification,
            touchCount: touchCount,
            phase: event.phase,
            allowsUnavailableTouchCount: allowsUnavailableTouchCount,
            blocksUnavailableTouchCount: rawHasRecentExactFive
                || rawHasRecentTwoToFour
        )
        let diagnosticResult = direction == nil
            ? (pinchSourceArbiter.owner?.rawValue ?? "candidate")
            : "recognized"
        // Diagnostics deliberately sit outside source ownership. Otherwise a
        // raw-silent public sequence has no owner before crossing its threshold
        // and leaves no evidence explaining why it did or did not recognize.
        LaunchGestureDiagnostics.log(
            "public magnify: phase=\(String(describing: event.phase)) touching=\(touchingTouchCount) all=\(allTouchCount) count=\(touchCount) delta=\(String(format: "%.4f", event.magnification)) evidence=\(touchEvidence.rawValue) raw-recent-five=\(rawHasRecentExactFive ? 1 : 0) raw-recent-2to4=\(rawHasRecentTwoToFour ? 1 : 0) result=\(diagnosticResult)"
        )
        if let direction {
            recognizePinch(direction, from: .public)
        } else if !isEnded,
                  !isCancelled,
                  pinchSourceArbiter.accepts(.public) {
            applyDeferredPinchCommand(
                deferredPinchActivation.recordActivity()
            )
        }
        if (isCancelled || isEnded), pinchSourceArbiter.accepts(.public) {
            // Recognition is already sufficient to request one presentation.
            // macOS commonly labels the public stream cancelled when activation
            // exits App Exposé; that system tail must not undo the user's pinch.
            LaunchGestureDiagnostics.log(
                "pinch terminal: source=public boundary=\(isCancelled ? "cancelled" : "released") result=keep-recognized-presentation"
            )
        }
    }

    private func recognizePinch(
        _ direction: RawPinchDirection,
        from source: TrackpadPinchInputSource
    ) {
        let previousOwner = pinchSourceArbiter.owner
        guard pinchSourceArbiter.recognize(from: source) else {
            LaunchGestureDiagnostics.log(
                "pinch recognized: source=\(source.rawValue) result=rejected owner=\(pinchSourceArbiter.owner?.rawValue ?? "none")"
            )
            return
        }
        LaunchGestureDiagnostics.log(
            "pinch recognized: source=\(source.rawValue) direction=\(String(describing: direction)) previous-owner=\(previousOwner?.rawValue ?? "none") result=activate-next-main-turn"
        )
        applyDeferredPinchCommand(deferredPinchActivation.register(direction))
        // A confident exact-five recognition is the trigger. Do not wait for
        // all-up: release here means "release the activation request", not
        // "wait until the user's fingers are released".
        applyDeferredPinchCommand(deferredPinchActivation.release())
    }

    /// Invalidates both a recognized pinch and a presentation queued for the
    /// next main-actor turn. AppDelegate calls this at every visibility/focus
    /// lifecycle boundary.
    func cancelPendingPinchPresentation() {
        let hadPendingPresentation = deferredPinchActivation.pendingDirection != nil
            || deferredPinchActivation.activationWasRequested
            || pinchFallbackTask != nil
            || pinchPresentationTask != nil
        if hadPendingPresentation {
            LaunchGestureDiagnostics.log(
                "pinch presentation cancelled: reason=lifecycle active=\(NSApp.isActive ? 1 : 0) visible=\(isLauncherVisible() ? 1 : 0)"
            )
        }
        pinchSourceArbiter.reset()
        applyDeferredPinchCommand(deferredPinchActivation.cancel())
        cancelDeferredPinchTasks()
    }

    /// Cancels delivery to the UI when the launcher loses interactivity. The
    /// private reducer continues observing the physical contacts until all-up,
    /// so a lift-off tail cannot start a new gesture when the window reappears.
    func cancelActivePageGestureDelivery() {
        touchPager.reset()
        pageSourceArbiter.reset()
        rawOwnedLocalPageQuarantine.reset()
        // Pointer-button quarantines deliberately survive this UI-delivery
        // reset. Only a physical all-up frame may rearm the residual contacts.
        discardPendingLocalPageGesture()
        cancelPageInactivityWatchdog()
        pageInactivityTracker.reset()
        deliveredSequenceIDs.removeAll(keepingCapacity: true)
    }

    func handleLauncherTouches(
        _ samples: [TrackpadTouchSample],
        phase: TrackpadTouchPhase,
        timestamp: TimeInterval
    ) {
        // Always keep the public AppKit surface alive. A private bridge can
        // register/start successfully yet deliver no usable frames in a given
        // session; source arbitration below prevents duplicate UI delivery when
        // raw and local both work while preserving local fallback when raw is
        // silent or fails decoding.
        let observableTouchCount = phase == .cancelled ? 0 : samples.count
        currentLocalTouchCount = observableTouchCount
        let primaryButtonBlocksPageGesture =
            primaryButtonLocalTouchLatch.blocksPageGesture(
                touchCount: samples.count,
                primaryButtonIsDown: NSEvent.pressedMouseButtons & 1 != 0,
                phase: phase
            )
        if LaunchGestureDiagnostics.isEnabled,
           lastLocalDiagnosticCount != samples.count {
            lastLocalDiagnosticCount = samples.count
            LaunchGestureDiagnostics.log(
                "touch source=local count=\(samples.count) phase=\(String(describing: phase))"
            )
        }
        guard isLauncherInteractive() else {
            if phase == .began || phase == .cancelled {
                LaunchGestureDiagnostics.log(
                    "gate source=local count=\(samples.count) result=not-interactive"
                )
            }
            touchPager.reset()
            cancelDeliveredPageGestureIfNeeded()
            return
        }
        if rawOwnedLocalPageQuarantine.suppressesLocalFrame(
            touchCount: observableTouchCount
        ) {
            if observableTouchCount == 0 {
                touchPager.reset()
                discardPendingLocalPageGesture()
                LaunchGestureDiagnostics.log(
                    "arbitration source=local result=raw-sequence-quarantine-released"
                )
            }
            return
        }
        if samples.count == 2, !didLogLocalExactTwoFrame {
            didLogLocalExactTwoFrame = true
            LaunchGestureDiagnostics.log("local AppKit received exact-two frame")
        }
        let events = touchPager.consume(
            samples,
            phase: phase,
            timestamp: timestamp,
            blocksPageGesture: primaryButtonBlocksPageGesture,
            diagnosticSource: .local
        )
        for event in events {
            routeLocalPageGesture(event)
        }
    }

    private func routeLocalPageGesture(_ event: TrackpadPageGestureEvent) {
        guard rawBridge != nil else {
            deliverPageGesture(event, source: .local)
            return
        }

        if pageSourceArbiter.activeIdentity?.source == .local {
            deliverPageGesture(event, source: .local)
            return
        }
        if pageSourceArbiter.activeIdentity?.source == .raw {
            return
        }

        switch event.phase {
        case .began:
            discardPendingLocalPageGesture()
            guard pendingLocalPageGesture.stage(event) else { return }
            LaunchGestureDiagnostics.log(
                "arbitration source=local sequence=\(event.sequenceID) result=pending-raw-grace"
            )
            schedulePendingLocalPageGesture()

        case .changed, .ended:
            _ = pendingLocalPageGesture.stage(event)

        case .cancelled:
            // A common macOS Spaces path is local begin/change followed by
            // touchesCancelled. Never expose that doomed local sequence; raw
            // remains free to own and finish the same physical swipe.
            if pendingLocalPageGesture.sequenceID == event.sequenceID {
                LaunchGestureDiagnostics.log(
                    "arbitration source=local sequence=\(event.sequenceID) result=discarded-system-cancel"
                )
                discardPendingLocalPageGesture()
            }
        }
    }

    private func primaryPointerButtonDidPress() {
        let overlapsObservedTouchSequence = currentLocalTouchCount > 0
            || pageSourceArbiter.activeIdentity != nil
            || !pendingLocalPageGesture.isEmpty
        if currentLocalTouchCount > 0 {
            _ = primaryButtonLocalTouchLatch.blocksPageGesture(
                touchCount: currentLocalTouchCount,
                primaryButtonIsDown: true
            )
        }
        if overlapsObservedTouchSequence, rawBridge != nil {
            // A raw action decoded just before mouseDown can reach the main
            // actor after mouse-up. Latch at the physical boundary, rather than
            // relying solely on pressedMouseButtons at delivery time.
            primaryButtonRawDeliveryQuarantine.beginPhysicalSequence()
        }
        touchPager.reset()
        discardPendingLocalPageGesture()
        cancelDeliveredPageGestureIfNeeded()
        LaunchGestureDiagnostics.log(
            "gate source=local result=primary-button-down-cancel"
        )
    }

    private func schedulePendingLocalPageGesture() {
        pendingLocalPageTask?.cancel()
        pendingLocalPageGeneration &+= 1
        let generation = pendingLocalPageGeneration
        let delay = UInt64(localPageGraceDuration * 1_000_000_000)
        pendingLocalPageTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled else { return }
            self?.flushPendingLocalPageGesture(generation: generation)
        }
    }

    private func flushPendingLocalPageGesture(generation: UInt64) {
        guard generation == pendingLocalPageGeneration,
              pageSourceArbiter.activeIdentity == nil else { return }
        pendingLocalPageTask = nil
        if NSEvent.pressedMouseButtons & 1 != 0
            || primaryButtonLocalTouchLatch.isActive {
            LaunchGestureDiagnostics.log(
                "gate source=local result=primary-button-pending-discard"
            )
            discardPendingLocalPageGesture()
            cancelDeliveredPageGestureIfNeeded()
            return
        }
        let events = pendingLocalPageGesture.drain()
        if let sequenceID = events.first?.sequenceID {
            LaunchGestureDiagnostics.log(
                "arbitration source=local sequence=\(sequenceID) result=grace-expired"
            )
        }
        for event in events {
            deliverPageGesture(event, source: .local)
        }
    }

    private func discardPendingLocalPageGesture() {
        pendingLocalPageGeneration &+= 1
        pendingLocalPageTask?.cancel()
        pendingLocalPageTask = nil
        pendingLocalPageGesture.reset()
    }

    private func deliverPageGesture(
        _ incomingEvent: TrackpadPageGestureEvent,
        source: TrackpadPageInputSource
    ) {
        let event = normalizedInternalCancellation(
            incomingEvent,
            source: source
        )
        if source == .raw, event.phase == .began {
            if !pendingLocalPageGesture.isEmpty {
                LaunchGestureDiagnostics.log(
                    "arbitration source=raw sequence=\(event.sequenceID) result=won-local-grace"
                )
            }
            discardPendingLocalPageGesture()
        }
        if event.phase == .began,
           let activeIdentity = pageSourceArbiter.activeIdentity,
           activeIdentity.source == source,
           activeIdentity.sequenceID != event.sequenceID {
            // A new sequence from the owning reducer is a hard boundary. This
            // never lets the competing source cancel the current interaction.
            cancelDeliveredPageGestureIfNeeded()
        }
        guard pageSourceArbiter.accepts(event, from: source) else {
            LaunchGestureDiagnostics.log(
                "arbitration source=\(source.rawValue) sequence=\(event.sequenceID) phase=\(event.phase) result=rejected owner=\(pageSourceArbiter.activeIdentity?.source.rawValue ?? "none")"
            )
            return
        }
        if event.phase == .began {
            LaunchGestureDiagnostics.log(
                "arbitration source=\(source.rawValue) sequence=\(event.sequenceID) result=accepted"
            )
            if source == .raw {
                // Once raw owns a physical sequence, AppKit's delayed
                // horizontal begin/cancel/lift tail is observation only. Keep
                // it from becoming a second page sequence after raw settles.
                rawOwnedLocalPageQuarantine.rawSequenceBegan()
                touchPager.reset()
            }
        }
        if event.phase == .began || event.phase == .ended || event.phase == .cancelled {
            LaunchGestureDiagnostics.log(
                "page \(event.phase): source=\(source.rawValue) sequence=\(event.sequenceID) progress=\(String(format: "%.3f", event.progress)) velocity=\(String(format: "%.3f", event.velocity))"
            )
        }

        switch event.phase {
        case .began:
            guard !deliveredSequenceIDs.contains(event.sequenceID) else { return }
            guard deliveredSequenceIDs.insert(event.sequenceID).inserted else { return }
            guard pageInactivityTracker.record(
                event,
                at: ProcessInfo.processInfo.systemUptime
            ) else {
                deliveredSequenceIDs.remove(event.sequenceID)
                pageSourceArbiter.reset()
                return
            }
        case .changed, .ended, .cancelled:
            guard deliveredSequenceIDs.contains(event.sequenceID) else { return }
            guard pageInactivityTracker.record(
                event,
                at: ProcessInfo.processInfo.systemUptime
            ) else { return }
        }
        handlePageGesture(event)

        if event.phase == .ended || event.phase == .cancelled {
            deliveredSequenceIDs.remove(event.sequenceID)
            cancelPageInactivityWatchdog()
            if source == .raw {
                rawOwnedLocalPageQuarantine.rawSequenceEnded(
                    currentLocalTouchCount: currentLocalTouchCount
                )
            }
        } else {
            schedulePageInactivityWatchdog(for: event.sequenceID)
        }
    }

    /// Raw decoding or AppKit can cancel on a final system-owned lift frame even
    /// though the UI already received a reliable exact-two translation beyond
    /// the commit distance. Keep true lifecycle cancellation (gate loss, hide,
    /// Settings, app deactivation) untouched; those bypass this method. Four or
    /// more contacts also remain a hard cancellation.
    private func normalizedInternalCancellation(
        _ event: TrackpadPageGestureEvent,
        source: TrackpadPageInputSource
    ) -> TrackpadPageGestureEvent {
        let normalized = TrackpadPageTerminalPolicy.normalized(
            event: event,
            source: source,
            activeIdentity: pageSourceArbiter.activeIdentity,
            reliableEvent: pageInactivityTracker.latestEvent,
            isInteractive: isLauncherInteractive()
        )
        if normalized.phase == .ended, event.phase == .cancelled {
            LaunchGestureDiagnostics.log(
                "terminal source=\(source.rawValue) sequence=\(event.sequenceID) result=upgrade-internal-cancel-to-ended reason=\(event.blockReason?.rawValue ?? "unclassified") progress=\(String(format: "%.3f", normalized.progress))"
            )
        }
        return normalized
    }

    private func schedulePageInactivityWatchdog(for sequenceID: UInt64) {
        cancelPageInactivityWatchdog()
        pageInactivityGeneration &+= 1
        let generation = pageInactivityGeneration
        let delay = UInt64(pageInactivityTimeout * 1_000_000_000)
        pageInactivityTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled else { return }
            self?.finishInactivePageGesture(
                sequenceID: sequenceID,
                generation: generation
            )
        }
    }

    private func finishInactivePageGesture(
        sequenceID: UInt64,
        generation: UInt64
    ) {
        guard generation == pageInactivityGeneration,
              deliveredSequenceIDs.contains(sequenceID),
              pageInactivityTracker.latestEvent?.sequenceID == sequenceID else {
            return
        }

        let terminalPhase = PageGestureWatchdogTerminalPolicy.terminalPhase(
            isInteractive: isLauncherInteractive(),
            primaryButtonIsDown: NSEvent.pressedMouseButtons & 1 != 0,
            primaryButtonSequenceIsLatched: primaryButtonLocalTouchLatch.isActive
        )
        guard let event = pageInactivityTracker.terminalEventIfExpired(
            at: ProcessInfo.processInfo.systemUptime,
            timeout: pageInactivityTimeout,
            phase: terminalPhase
        ) else { return }

        let terminalSource = pageSourceArbiter.activeIdentity?.source
        pageInactivityTask = nil
        deliveredSequenceIDs.remove(sequenceID)
        pageSourceArbiter.reset()
        if terminalSource == .raw {
            rawOwnedLocalPageQuarantine.rawSequenceEnded(
                currentLocalTouchCount: currentLocalTouchCount
            )
        }
        LaunchGestureDiagnostics.log(
            "page watchdog terminal: sequence=\(sequenceID) phase=\(terminalPhase) progress=\(String(format: "%.3f", event.progress))"
        )
        handlePageGesture(event)
    }

    private func cancelPageInactivityWatchdog() {
        pageInactivityGeneration &+= 1
        pageInactivityTask?.cancel()
        pageInactivityTask = nil
    }

    private func cancelDeliveredPageGestureIfNeeded() {
        cancelPageInactivityWatchdog()
        discardPendingLocalPageGesture()
        pageSourceArbiter.reset()
        guard let event = pageInactivityTracker.cancelCurrent() else {
            deliveredSequenceIDs.removeAll(keepingCapacity: true)
            return
        }
        deliveredSequenceIDs.remove(event.sequenceID)
        handlePageGesture(event)
    }

    private func performDeferredPinch(_ direction: RawPinchDirection) {
        LaunchGestureDiagnostics.log(
            "pinch presentation requested: direction=\(String(describing: direction)) active=\(NSApp.isActive ? 1 : 0) visible=\(isLauncherVisible() ? 1 : 0)"
        )
        switch direction {
        case .inward where !isLauncherVisible():
            // Activation is synchronous; presentation is queued only to the
            // next main-actor turn so AppKit can settle the activation state.
            // There is deliberately no fixed compositor delay here: reaching
            // the reliable five-finger threshold must feel immediate.
            NSApp.unhide(nil)
            NSApp.activate(ignoringOtherApps: true)
            scheduleImmediatePinchPresentation(direction)
        case .outward where isLauncherVisible():
            hideLauncher()
            completeDeferredPinchPresentation()
        default:
            completeDeferredPinchPresentation()
            break
        }
    }

    private func handleRawAction(_ action: RawGestureAction) {
        if let boundary = action.pinchSequenceBoundary {
            if pinchSourceArbiter.accepts(.raw) {
                LaunchGestureDiagnostics.log(
                    "pinch terminal: source=raw boundary=\(String(describing: boundary)) result=keep-recognized-presentation"
                )
            }
        }
        if let direction = action.pinchDirection {
            recognizePinch(direction, from: .raw)
        } else if action.pinchSequenceActivity,
                  pinchSourceArbiter.accepts(.raw) {
            applyDeferredPinchCommand(
                deferredPinchActivation.recordActivity()
            )
        }

        let filteredPageEvents = primaryButtonRawDeliveryQuarantine.filter(
            action.pageEvents,
            primaryButtonIsDown: NSEvent.pressedMouseButtons & 1 != 0
        )
        if filteredPageEvents.didSuppress {
            LaunchGestureDiagnostics.log(
                "gate source=raw result=primary-button-quarantine"
            )
            cancelDeliveredPageGestureIfNeeded()
        }
        guard isLauncherInteractive() else {
            cancelDeliveredPageGestureIfNeeded()
            return
        }
        for event in filteredPageEvents.acceptedEvents {
            deliverPageGesture(event, source: .raw)
        }
    }

    private func applyDeferredPinchCommand(
        _ command: DeferredPinchActivationCommand
    ) {
        switch command {
        case .none:
            break
        case .armFallback:
            schedulePinchFallback()
        case let .activate(direction):
            pinchFallbackTask?.cancel()
            pinchFallbackTask = nil
            performDeferredPinch(direction)
        case .cancelActivation:
            cancelDeferredPinchTasks()
        case .cancelActivationAndArmFallback:
            cancelDeferredPinchTasks()
            schedulePinchFallback()
        }
    }

    private func schedulePinchFallback() {
        pinchFallbackTask?.cancel()
        pinchTaskGeneration &+= 1
        let generation = pinchTaskGeneration
        let delay = UInt64(pinchFallbackTimeout * 1_000_000_000)
        pinchFallbackTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled,
                  let self,
                  generation == self.pinchTaskGeneration else { return }
            self.pinchFallbackTask = nil
            self.applyDeferredPinchCommand(
                self.deferredPinchActivation.fallbackExpired()
            )
        }
    }

    private func scheduleImmediatePinchPresentation(
        _ direction: RawPinchDirection
    ) {
        pinchPresentationTask?.cancel()
        pinchTaskGeneration &+= 1
        let generation = pinchTaskGeneration
        LaunchGestureDiagnostics.log(
            "pinch presentation queued: direction=\(String(describing: direction)) fixed-delay-ms=0 generation=\(generation)"
        )
        pinchPresentationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            guard !Task.isCancelled else {
                LaunchGestureDiagnostics.log(
                    "pinch presentation dropped: reason=task-cancelled generation=\(generation)"
                )
                return
            }
            guard generation == self.pinchTaskGeneration else {
                LaunchGestureDiagnostics.log(
                    "pinch presentation dropped: reason=stale-generation expected=\(generation) actual=\(self.pinchTaskGeneration)"
                )
                return
            }
            self.pinchPresentationTask = nil
            LaunchGestureDiagnostics.log(
                "pinch presentation firing: direction=\(String(describing: direction)) active=\(NSApp.isActive ? 1 : 0) visible=\(self.isLauncherVisible() ? 1 : 0)"
            )
            switch direction {
            case .inward where !self.isLauncherVisible():
                self.showLauncher()
            case .outward where self.isLauncherVisible():
                self.hideLauncher()
            default:
                break
            }
            self.completeDeferredPinchPresentation()
        }
    }

    private func completeDeferredPinchPresentation() {
        deferredPinchActivation.presentationCompleted()
        pinchSourceArbiter.reset()
    }

    private func cancelDeferredPinchTasks() {
        pinchTaskGeneration &+= 1
        pinchFallbackTask?.cancel()
        pinchFallbackTask = nil
        pinchPresentationTask?.cancel()
        pinchPresentationTask = nil
    }

}
