import AppKit

private struct MenuBarCoverCheckFailure: Error, CustomStringConvertible {
    let description: String
}

private func requireCover(
    _ condition: @autoclosure () -> Bool,
    _ message: String
) throws {
    guard condition() else {
        throw MenuBarCoverCheckFailure(description: message)
    }
}

@main
private enum MenuBarCoverChecks {
    static func main() throws {
        let screen = NSRect(x: -1440, y: 0, width: 1440, height: 900)
        let bottomDockVisible = NSRect(x: -1440, y: 70, width: 1440, height: 805)
        let standard = MenuBarCoverGeometry.frame(
            screenFrame: screen,
            visibleFrame: bottomDockVisible,
            safeAreaTop: 0
        )
        try requireCover(
            standard == NSRect(x: -1440, y: 875, width: 1440, height: 25),
            "The cover did not use only the real top inset"
        )
        try requireCover(
            standard.minY > bottomDockVisible.minY,
            "The top cover extended into the Dock region"
        )

        let notched = MenuBarCoverGeometry.frame(
            screenFrame: screen,
            visibleFrame: screen,
            safeAreaTop: 38
        )
        try requireCover(
            notched.minY == 862 && notched.height == 38,
            "The cover did not respect a notched screen safe area"
        )

        let autoHiddenMenuBar = MenuBarCoverGeometry.frame(
            screenFrame: screen,
            visibleFrame: screen,
            safeAreaTop: 0
        )
        try requireCover(
            autoHiddenMenuBar.minY == 876
                && autoHiddenMenuBar.height == MenuBarCoverGeometry.fallbackHeight,
            "An auto-hidden menu bar did not receive the safe fallback strip"
        )
        try requireCover(
            LauncherWindowLevelPolicy.launcher.rawValue
                < Int(CGWindowLevelForKey(.dockWindow)),
            "The full-screen launcher window can cover a visible Dock"
        )
        try requireCover(
            LauncherWindowLevelPolicy.settings.rawValue
                > LauncherWindowLevelPolicy.launcher.rawValue
                && LauncherWindowLevelPolicy.settings.rawValue
                    < Int(CGWindowLevelForKey(.dockWindow)),
            "Settings is not above Launch while remaining below the Dock"
        )
        try requireCover(
            LauncherWindowLevelPolicy.menuBarCover.rawValue
                > NSWindow.Level.statusBar.rawValue,
            "The narrow menu-bar cover cannot obscure the system-owned label"
        )
        print("Launch menu-bar cover checks passed (6/6)")
    }
}
