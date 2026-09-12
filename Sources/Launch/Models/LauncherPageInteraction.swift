import Foundation

/// Testable, UI-agnostic state for a continuously tracked horizontal page
/// gesture. Progress is measured in page widths: right is positive and left is
/// negative, so the visual position is `originPage - progress`.
public struct LauncherPageInteractionState: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        case idle
        case tracking
        case settling
    }

    public private(set) var phase: Phase
    public private(set) var originPage: Int
    public private(set) var progress: Double
    /// Velocity in page widths per second, positive toward the previous page.
    public private(set) var velocity: Double
    public private(set) var targetPage: Int?

    private var rawProgress: Double

    public static let idle = LauncherPageInteractionState()

    public var position: Double {
        Double(originPage) - progress
    }

    public init() {
        phase = .idle
        originPage = 0
        progress = 0
        velocity = 0
        targetPage = nil
        rawProgress = 0
    }

    @discardableResult
    public mutating func begin(at page: Int, pageCount: Int) -> Bool {
        let count = max(1, pageCount)
        originPage = min(max(0, page), count - 1)
        progress = 0
        rawProgress = 0
        velocity = 0
        targetPage = nil
        phase = .tracking
        return true
    }

    public mutating func update(
        translation: Double,
        velocity: Double = 0,
        pageExtent: Double,
        pageCount: Int
    ) {
        guard phase == .tracking,
              translation.isFinite,
              velocity.isFinite,
              pageExtent.isFinite,
              pageExtent > 0 else {
            return
        }

        let count = max(1, pageCount)
        let lastPage = count - 1
        rawProgress = min(max(translation / pageExtent, -1.25), 1.25)
        self.velocity = velocity / pageExtent

        let pullsPastFirstPage = originPage == 0 && rawProgress > 0
        let pullsPastLastPage = originPage >= lastPage && rawProgress < 0
        if pullsPastFirstPage || pullsPastLastPage {
            progress = Self.rubberBanded(rawProgress)
        } else {
            progress = min(max(rawProgress, -1), 1)
        }
    }

    /// Resolves a tracking sequence exactly once and enters `settling`. A second
    /// call returns nil, preventing duplicate page commits from tail callbacks.
    @discardableResult
    public mutating func end(
        predictedTranslation: Double? = nil,
        velocity endingVelocity: Double? = nil,
        pageExtent: Double,
        pageCount: Int
    ) -> Int? {
        guard phase == .tracking else { return nil }

        let count = max(1, pageCount)
        let safeOrigin = min(max(0, originPage), count - 1)
        let predictedProgress: Double
        if let predictedTranslation,
           predictedTranslation.isFinite,
           pageExtent.isFinite,
           pageExtent > 0 {
            predictedProgress = predictedTranslation / pageExtent
        } else {
            let normalizedVelocity: Double
            if let endingVelocity, endingVelocity.isFinite, pageExtent.isFinite, pageExtent > 0 {
                normalizedVelocity = endingVelocity / pageExtent
            } else {
                normalizedVelocity = velocity
            }
            predictedProgress = rawProgress + normalizedVelocity * 0.18
        }

        let threshold = 0.22
        // Once the page itself has crossed the commit distance, a noisy
        // opposite-direction lift sample must not pull an obviously moved page
        // back (or, worse, commit the other direction). Velocity projection is
        // useful only for a short flick that is still travelling in the same
        // direction as its measured displacement.
        let resolutionProgress: Double
        if abs(rawProgress) >= threshold {
            resolutionProgress = rawProgress
        } else if rawProgress != 0, predictedProgress * rawProgress > 0 {
            resolutionProgress = predictedProgress
        } else {
            resolutionProgress = rawProgress
        }

        var destination = safeOrigin
        if resolutionProgress >= threshold {
            destination -= 1
        } else if resolutionProgress <= -threshold {
            destination += 1
        }
        destination = min(max(0, destination), count - 1)

        originPage = safeOrigin
        targetPage = destination
        progress = Double(safeOrigin - destination)
        rawProgress = progress
        if let endingVelocity, endingVelocity.isFinite, pageExtent.isFinite, pageExtent > 0 {
            velocity = endingVelocity / pageExtent
        }
        phase = .settling
        return destination
    }

    public mutating func complete() {
        self = .idle
    }

    public mutating func cancel() {
        self = .idle
    }

    private static func rubberBanded(_ value: Double) -> Double {
        let magnitude = abs(value)
        let resisted = magnitude * 0.28 / (1 + magnitude * 0.35)
        return value < 0 ? -resisted : resisted
    }
}
