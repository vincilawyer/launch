import CoreGraphics
import SwiftUI

/// High-frequency cursor movement lives outside the parent View's value state.
/// Only the small floating preview observes this object, so mouseMoved events do
/// not invalidate every tile in the grid.
@MainActor
final class LauncherPointerLocationState: ObservableObject {
    @Published private(set) var location = CGPoint.zero

    func update(_ location: CGPoint) {
        guard self.location != location else { return }
        self.location = location
    }
}

/// Geometry preferences change on every frame of a provisional reorder
/// animation. They are read by pointer hit testing but never rendered directly,
/// so store them behind a stable reference instead of invalidating the entire
/// launcher through `@State` on every frame.
@MainActor
final class LauncherMainGridGeometryState {
    private(set) var tileFrames: [LauncherPageTileFrameKey: CGRect] = [:]
    private(set) var rootTileFrames: [LauncherPageTileFrameKey: CGRect] = [:]
    private(set) var rootFrame = CGRect.zero

    func update(tileFrames: [LauncherPageTileFrameKey: CGRect]) {
        guard self.tileFrames != tileFrames else { return }
        self.tileFrames = tileFrames
    }

    func update(rootTileFrames: [LauncherPageTileFrameKey: CGRect]) {
        guard self.rootTileFrames != rootTileFrames else { return }
        self.rootTileFrames = rootTileFrames
    }

    func update(rootFrame: CGRect) {
        guard self.rootFrame != rootFrame else { return }
        self.rootFrame = rootFrame
    }
}

@MainActor
final class LauncherFolderGridGeometryState: ObservableObject {
    @Published private(set) var tileFrames: [String: CGRect] = [:]
    @Published private(set) var gridFrame = CGRect.zero
    @Published private(set) var viewportFrame = CGRect.zero
    @Published private(set) var panelFrame = CGRect.zero

    func update(tileFrames: [String: CGRect]) {
        guard self.tileFrames != tileFrames else { return }
        self.tileFrames = tileFrames
    }

    func update(gridFrame: CGRect) {
        guard self.gridFrame != gridFrame else { return }
        self.gridFrame = gridFrame
    }

    func update(viewportFrame: CGRect) {
        guard self.viewportFrame != viewportFrame else { return }
        self.viewportFrame = viewportFrame
    }

    func update(panelFrame: CGRect) {
        guard self.panelFrame != panelFrame else { return }
        self.panelFrame = panelFrame
    }

    func reset() {
        tileFrames = [:]
        gridFrame = .zero
        viewportFrame = .zero
        panelFrame = .zero
    }
}
