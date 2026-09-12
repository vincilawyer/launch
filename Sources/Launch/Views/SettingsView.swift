import SwiftUI

@MainActor
struct SettingsView: View {
    @ObservedObject var model: LauncherModel
    @ObservedObject var launchAtLoginManager: LaunchAtLoginManager

    init(
        model: LauncherModel,
        launchAtLoginManager: LaunchAtLoginManager
    ) {
        self.model = model
        self.launchAtLoginManager = launchAtLoginManager
    }

    var body: some View {
        LauncherSettingsContent(
            applicationModel: model,
            preferences: $model.preferences,
            loginItemAvailable: launchAtLoginManager.isAvailable,
            loginItemRequiresApproval: launchAtLoginManager.requiresApproval,
            loginItemError: launchAtLoginManager.lastError,
            shortcutError: model.errorMessage,
            iconProvider: model.icon,
            setLaunchAtLogin: { enabled in
                model.preferences.launchAtLogin = enabled
            },
            openLoginItemsSettings: launchAtLoginManager.openLoginItemsSettings,
            clearShortcutError: model.clearError,
            save: model.savePreferences,
            rescan: model.rescan
        )
        .frame(minWidth: 500, minHeight: 440)
    }
}
