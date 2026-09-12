import AppKit
import SwiftUI

struct LauncherSettingsContent: View {
    @ObservedObject var applicationModel: LauncherModel
    @Binding var preferences: LaunchPreferences

    @State private var showsApplicationManager = false

    let loginItemAvailable: Bool
    let loginItemRequiresApproval: Bool
    let loginItemError: String?
    let shortcutError: String?
    let iconProvider: (String) -> NSImage?
    let setLaunchAtLogin: (Bool) -> Void
    let openLoginItemsSettings: () -> Void
    let clearShortcutError: () -> Void
    let save: () -> Void
    let rescan: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                LauncherSettingsSection(
                    title: LaunchText.value("布局", "Layout"),
                    systemImage: "square.grid.3x3"
                ) {
                    LauncherSettingsRow(title: LaunchText.value("行数", "Rows")) {
                        Stepper(value: $preferences.rows, in: 3...8) {
                            Text("\(preferences.rows)")
                                .monospacedDigit()
                                .frame(width: 24, alignment: .trailing)
                        }
                        .frame(width: 92)
                    }

                    LauncherSettingsDivider()

                    LauncherSettingsRow(title: LaunchText.value("列数", "Columns")) {
                        Stepper(value: $preferences.columns, in: 4...12) {
                            Text("\(preferences.columns)")
                                .monospacedDigit()
                                .frame(width: 24, alignment: .trailing)
                        }
                        .frame(width: 92)
                    }

                    LauncherSettingsDivider()

                    LauncherSettingsRow(title: LaunchText.value("图标大小", "Icon size")) {
                        HStack(spacing: 10) {
                            Slider(value: $preferences.iconSize, in: 48...112, step: 2)
                                .frame(width: 190)
                            Text("\(Int(preferences.iconSize)) pt")
                                .font(.callout)
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                                .frame(width: 54, alignment: .trailing)
                        }
                    }

                    LauncherSettingsDivider()

                    LauncherSettingsRow(
                        title: LaunchText.value("显示应用名称", "Show application names")
                    ) {
                        Toggle("", isOn: $preferences.showLabels)
                            .labelsHidden()
                    }
                }

                LauncherSettingsSection(
                    title: LaunchText.value("通用", "General"),
                    systemImage: "gearshape"
                ) {
                    LauncherSettingsRow(
                        title: LaunchText.value("登录时自动打开 Launch", "Open Launch automatically at login"),
                        subtitle: loginItemAvailable
                            ? nil
                            : LaunchText.value(
                                "登录项功能仅在打包后的应用中可用。",
                                "Available in the packaged Launch application."
                            )
                    ) {
                        Toggle(
                            "",
                            isOn: Binding(
                                get: { preferences.launchAtLogin },
                                set: setLaunchAtLogin
                            )
                        )
                        .labelsHidden()
                        .disabled(!loginItemAvailable)
                    }

                    if loginItemRequiresApproval {
                        LauncherSettingsDivider()
                        LauncherSettingsNotice(
                            text: LaunchText.value(
                                "macOS 需要你在“登录项”中批准。",
                                "macOS needs your approval in Login Items."
                            ),
                            systemImage: "exclamationmark.triangle.fill",
                            tint: .orange,
                            actionTitle: LaunchText.value("打开系统设置", "Open Settings"),
                            action: openLoginItemsSettings
                        )
                    }

                    if let loginItemError {
                        LauncherSettingsDivider()
                        LauncherSettingsNotice(
                            text: loginItemError,
                            systemImage: "exclamationmark.circle.fill",
                            tint: .red
                        )
                    }

                    LauncherSettingsDivider()

                    LauncherSettingsRow(
                        title: LaunchText.value("显示菜单栏图标", "Show menu bar icon"),
                        subtitle: LaunchText.value(
                            "关闭后仍可使用全局快捷键或从“应用程序”文件夹打开 Launch。",
                            "When off, use the global shortcut or open Launch from Applications."
                        )
                    ) {
                        Toggle("", isOn: $preferences.showMenuBarIcon)
                            .labelsHidden()
                    }

                    LauncherSettingsDivider()

                    LauncherSettingsRow(
                        title: LaunchText.value("管理应用", "Manage applications"),
                        subtitle: LaunchText.value(
                            "在一个列表中选择哪些应用显示在 Launch 中。",
                            "Choose which applications appear in Launch from one list."
                        )
                    ) {
                        HStack(spacing: 7) {
                            Button(LaunchText.value("应用列表…", "Application List…")) {
                                showsApplicationManager = true
                            }
                            .disabled(applicationModel.managedApplications.isEmpty)

                            Button(LaunchText.value("重新扫描", "Scan Again"), action: rescan)
                        }
                        .controlSize(.small)
                    }
                }

                LauncherSettingsSection(
                    title: LaunchText.value("键盘", "Keyboard"),
                    systemImage: "keyboard"
                ) {
                    LauncherGlobalShortcutEditor(
                        shortcut: $preferences.globalShortcut
                    )

                    if let shortcutError {
                        LauncherSettingsDivider()
                        LauncherSettingsNotice(
                            text: shortcutError,
                            systemImage: "exclamationmark.triangle.fill",
                            tint: .red,
                            actionTitle: LaunchText.value("关闭", "Dismiss"),
                            action: clearShortcutError
                        )
                    }

                    LauncherSettingsDivider()
                    LauncherShortcutRow(
                        keys: ["←", "↑", "↓", "→"],
                        action: LaunchText.value("移动选择", "Move selection")
                    )
                    LauncherSettingsDivider()
                    LauncherShortcutRow(keys: ["↩"], action: LaunchText.value("打开所选项目", "Open selected item"))
                    LauncherSettingsDivider()
                    LauncherShortcutRow(keys: ["Esc"], action: LaunchText.value("关闭文件夹或 Launch", "Close folder or Launch"))
                }

                LauncherSettingsSection(
                    title: LaunchText.value("触控板", "Trackpad"),
                    systemImage: "hand.draw"
                ) {
                    LauncherShortcutRow(
                        keys: [LaunchText.value("五指", "5 fingers"), LaunchText.value("捏合", "Pinch")],
                        action: LaunchText.value("显示 Launch", "Show Launch")
                    )
                    LauncherSettingsDivider()
                    LauncherShortcutRow(
                        keys: [LaunchText.value("五指", "5 fingers"), LaunchText.value("张开", "Spread")],
                        action: LaunchText.value("隐藏 Launch", "Hide Launch")
                    )
                    LauncherSettingsDivider()
                    LauncherShortcutRow(
                        keys: [LaunchText.value("二指", "2 fingers"), LaunchText.value("横向滑动", "Swipe")],
                        action: LaunchText.value("跟手切换页面", "Interactively change pages")
                    )
                    LauncherSettingsDivider()
                    LauncherSettingsNotice(
                        text: LaunchText.value(
                            "Launch 打开时，二指横向滑动会让页面跟随手势移动；三指手势继续交给 macOS。五指手势暂不可用时，可使用你在上方设置的全局快捷键。",
                            "While Launch is open, a two-finger horizontal swipe moves pages with your gesture; three-finger gestures remain available to macOS. If five-finger gestures are unavailable, use the global shortcut configured above."
                        ),
                        systemImage: "info.circle",
                        tint: .secondary
                    )
                }

            }
            .padding(.horizontal, 26)
            .padding(.vertical, 22)
            .frame(maxWidth: 720)
            .frame(maxWidth: .infinity)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .navigationTitle(LaunchText.value("Launch 设置", "Launch Settings"))
        .onChange(of: preferences) { _, _ in
            save()
        }
        .sheet(isPresented: $showsApplicationManager) {
            LauncherApplicationManagerSheet(
                model: applicationModel,
                iconProvider: iconProvider
            )
        }
    }
}

@MainActor
private struct LauncherApplicationManagerSheet: View {
    @StateObject private var managerState: LauncherApplicationManagerState
    let iconProvider: (String) -> NSImage?

    @Environment(\.dismiss) private var dismiss

    init(
        model: LauncherModel,
        iconProvider: @escaping (String) -> NSImage?
    ) {
        _managerState = StateObject(
            wrappedValue: LauncherApplicationManagerState(model: model)
        )
        self.iconProvider = iconProvider
    }

    private var filteredApplications: [ManagedApplication] {
        managerState.filteredRows
    }

    private var isSearching: Bool {
        !managerState.searchText
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty
    }

    private var applicationCount: Int {
        managerState.applicationCount
    }

    private var visibleCount: Int {
        managerState.visibleCount
    }

    private var visibleApplications: [ManagedApplication] {
        managerState.visibleRows
    }

    private var hiddenApplications: [ManagedApplication] {
        managerState.hiddenRows
    }

    var body: some View {
        VStack(spacing: 0) {
            managerHeader

            Divider()

            if filteredApplications.isEmpty {
                ContentUnavailableView(
                    LaunchText.value("没有匹配的应用", "No Matching Applications"),
                    systemImage: "magnifyingglass",
                    description: Text(
                        LaunchText.value("请尝试其他名称。", "Try another name.")
                    )
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        if isSearching {
                            // Search results stay in one identity namespace.
                            // Toggling visibility cannot remove an active
                            // NSSwitch from one ForEach and recreate it in a
                            // different group during the same control action.
                            applicationGroup(
                                title: LaunchText.value("搜索结果", "Search Results"),
                                systemImage: "magnifyingglass",
                                applications: filteredApplications
                            )
                        } else {
                            applicationGroup(
                                title: LaunchText.value("可见", "Visible"),
                                systemImage: "eye",
                                applications: visibleApplications
                            )

                            applicationGroup(
                                title: LaunchText.value("已隐藏", "Hidden"),
                                systemImage: "eye.slash",
                                applications: hiddenApplications
                            )
                        }
                    }
                    .padding(14)
                }
            }

            Divider()

            HStack {
                Spacer()
                Button(LaunchText.value("完成", "Done")) {
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
            .padding(18)
        }
        .frame(width: 620, height: 560)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var managerHeader: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(LaunchText.value("管理应用", "Manage Applications"))
                        .font(.system(size: 22, weight: .semibold, design: .rounded))
                    Text(
                        LaunchText.value(
                            "更改会立即生效，隐藏的应用随时可以重新显示。",
                            "Changes apply immediately, and hidden applications can be shown again at any time."
                        )
                    )
                    .font(.callout)
                    .foregroundStyle(.secondary)
                }
                Spacer()
                Text(
                    LaunchText.value(
                        "显示 \(visibleCount) / \(applicationCount)",
                        "\(visibleCount) of \(applicationCount) shown"
                    )
                )
                .font(.callout.weight(.medium))
                .foregroundStyle(.secondary)
                .contentTransition(.numericText())
            }

            HStack(spacing: 9) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField(
                    LaunchText.value("搜索应用", "Search applications"),
                    text: $managerState.searchText
                )
                .textFieldStyle(.plain)
                if !managerState.searchText.isEmpty {
                    Button {
                        managerState.searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(LaunchText.value("清除搜索", "Clear search"))
                }
            }
            .padding(.horizontal, 11)
            .frame(height: 36)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .padding(22)
    }

    @ViewBuilder
    private func applicationGroup(
        title: String,
        systemImage: String,
        applications: [ManagedApplication]
    ) -> some View {
        HStack(spacing: 7) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .semibold))
            Text(title)
            Text("\(applications.count)")
                .monospacedDigit()
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.top, 10)
        .padding(.bottom, 3)
        .accessibilityElement(children: .combine)

        ForEach(applications) { item in
            LauncherManagedApplicationRow(
                managerState: managerState,
                applicationID: item.id,
                application: item.application,
                icon: iconProvider(item.id)
            )
        }
    }

}

@MainActor
private struct LauncherManagedApplicationRow: View {
    @ObservedObject var managerState: LauncherApplicationManagerState
    let applicationID: String
    let application: InstalledApplication
    let icon: NSImage?

    private var isVisible: Bool {
        managerState.visualVisibility(for: applicationID)
    }

    private var visibilityBinding: Binding<Bool> {
        Binding(
            get: {
                managerState.visualVisibility(for: applicationID)
            },
            set: { desiredVisibility in
                managerState.requestVisibility(
                    applicationID,
                    isVisible: desiredVisibility
                )
            }
        )
    }

    var body: some View {
        HStack(spacing: 12) {
            LauncherAppIcon(
                image: icon,
                fallbackName: application.name,
                size: 38
            )

            VStack(alignment: .leading, spacing: 2) {
                Text(application.name)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(
                    isVisible
                        ? LaunchText.value("在 Launch 中显示", "Shown in Launch")
                        : LaunchText.value("已隐藏", "Hidden")
                )
                .font(.caption)
                .foregroundStyle(isVisible ? Color.secondary : Color.orange)
                .lineLimit(1)
            }

            Spacer()

            Toggle(
                "",
                isOn: visibilityBinding
            )
            .labelsHidden()
            .toggleStyle(.switch)
            .accessibilityLabel(
                LaunchText.value(
                    "在 Launch 中显示 \(application.name)",
                    "Show \(application.name) in Launch"
                )
            )
        }
        .padding(.horizontal, 12)
        .frame(height: 58)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(isVisible ? Color.clear : Color.orange.opacity(0.055))
        }
    }
}

private struct LauncherSettingsSection<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.leading, 4)

            VStack(spacing: 0) {
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                Color(nsColor: .controlBackgroundColor),
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color(nsColor: .separatorColor).opacity(0.42), lineWidth: 1)
            }
        }
    }
}

private struct LauncherSettingsRow<Control: View>: View {
    let title: String
    let subtitle: String?
    @ViewBuilder let control: () -> Control

    init(
        title: String,
        subtitle: String? = nil,
        @ViewBuilder control: @escaping () -> Control
    ) {
        self.title = title
        self.subtitle = subtitle
        self.control = control
    }

    var body: some View {
        HStack(spacing: 18) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body)
                    .foregroundStyle(.primary)

                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 12)

            control()
                .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.horizontal, 14)
        .frame(minHeight: subtitle == nil ? 48 : 58)
    }
}

private struct LauncherSettingsDivider: View {
    var body: some View {
        Divider()
            .padding(.leading, 14)
    }
}

private struct LauncherSettingsNotice: View {
    let text: String
    let systemImage: String
    let tint: Color
    var actionTitle: String?
    var action: (() -> Void)?

    init(
        text: String,
        systemImage: String,
        tint: Color,
        actionTitle: String? = nil,
        action: (() -> Void)? = nil
    ) {
        self.text = text
        self.systemImage = systemImage
        self.tint = tint
        self.actionTitle = actionTitle
        self.action = action
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .foregroundStyle(tint)
                .frame(width: 18)

            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)

            Spacer(minLength: 8)

            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(minHeight: 44)
    }
}

private struct LauncherShortcutRow: View {
    let keys: [String]
    let action: String

    var body: some View {
        HStack {
            Text(action)
            Spacer()
            HStack(spacing: 5) {
                ForEach(keys, id: \.self) { key in
                    Text(key)
                        .font(.system(.callout, design: .rounded, weight: .medium))
                        .padding(.horizontal, 7)
                        .frame(minWidth: 27, minHeight: 24)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 5))
                }
            }
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 48)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            LaunchText.value(
                "\(action)：\(keys.joined(separator: " 加 "))",
                "\(action): \(keys.joined(separator: " plus "))"
            )
        )
    }
}
