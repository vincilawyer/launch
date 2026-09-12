import AppKit

/// Window levels shared by the launcher controllers and their geometry checks.
/// Settings must remain above the launcher, but every ordinary content window
/// stays below the Dock. Only the narrow menu-bar cover intentionally exceeds
/// the system UI level.
enum LauncherWindowLevelPolicy {
    static let launcher = NSWindow.Level.modalPanel
    static let settings = NSWindow.Level(
        rawValue: NSWindow.Level.modalPanel.rawValue + 1
    )
    static let menuBarCover = NSWindow.Level(
        rawValue: NSWindow.Level.statusBar.rawValue + 1
    )
}

/// Pure geometry for a visual menu-bar cover. The result is always anchored to
/// the top edge of one screen and never extends toward a bottom/side Dock.
struct MenuBarCoverGeometry {
    static let fallbackHeight: CGFloat = 24
    private static let maximumReasonableHeight: CGFloat = 96

    static func frame(
        screenFrame: NSRect,
        visibleFrame: NSRect,
        safeAreaTop: CGFloat
    ) -> NSRect {
        let rawTopGap = screenFrame.maxY - visibleFrame.maxY
        let topGap = rawTopGap.isFinite && rawTopGap >= 0
            ? min(rawTopGap, maximumReasonableHeight)
            : 0
        let safeTop = safeAreaTop.isFinite
            ? min(max(0, safeAreaTop), maximumReasonableHeight)
            : 0
        let height = min(
            screenFrame.height,
            max(fallbackHeight, topGap, safeTop)
        )
        return NSRect(
            x: screenFrame.minX,
            y: screenFrame.maxY - height,
            width: screenFrame.width,
            height: height
        )
    }
}
