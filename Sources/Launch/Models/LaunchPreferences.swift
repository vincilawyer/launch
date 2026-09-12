import Foundation

/// A Carbon-compatible global shortcut that can be persisted without importing
/// AppKit into the layout model. `modifiers` uses the classic Carbon masks:
/// Command 256, Shift 512, Option 2048, and Control 4096.
public struct LaunchShortcutDescriptor: Codable, Hashable, Sendable {
    public static let commandModifier: UInt32 = 256
    public static let shiftModifier: UInt32 = 512
    public static let optionModifier: UInt32 = 2_048
    public static let controlModifier: UInt32 = 4_096
    public static let allowedModifierMask = commandModifier
        | shiftModifier
        | optionModifier
        | controlModifier

    public var enabled: Bool
    public var keyCode: UInt32
    public var modifiers: UInt32
    /// A stable, user-facing representation captured with the shortcut.
    public var display: String

    public init(
        enabled: Bool = true,
        keyCode: UInt32,
        modifiers: UInt32,
        display: String
    ) {
        self.enabled = enabled
        self.keyCode = keyCode
        self.modifiers = modifiers & Self.allowedModifierMask
        self.display = display
    }

    /// The historical primary shortcut. F4 is intentionally not retained as a
    /// hidden second shortcut so disabling the preference truly disables it.
    public static let optionSpace = LaunchShortcutDescriptor(
        enabled: true,
        keyCode: 49,
        modifiers: optionModifier,
        display: "⌥Space"
    )
    public static let `default` = optionSpace
    public static let disabled = LaunchShortcutDescriptor(
        enabled: false,
        keyCode: optionSpace.keyCode,
        modifiers: optionSpace.modifiers,
        display: optionSpace.display
    )

    public var displayName: String {
        guard enabled else { return "Disabled" }
        let trimmed = display.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? Self.fallbackDisplay(keyCode: keyCode, modifiers: modifiers) : trimmed
    }

    public func normalized() -> LaunchShortcutDescriptor {
        LaunchShortcutDescriptor(
            enabled: enabled,
            keyCode: keyCode,
            modifiers: modifiers,
            display: displayNameForPersistence
        )
    }

    private enum CodingKeys: String, CodingKey {
        case enabled
        case keyCode
        case modifiers
        case display
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        keyCode = try container.decodeIfPresent(UInt32.self, forKey: .keyCode)
            ?? Self.optionSpace.keyCode
        modifiers = (
            try container.decodeIfPresent(UInt32.self, forKey: .modifiers)
                ?? Self.optionSpace.modifiers
        ) & Self.allowedModifierMask
        display = try container.decodeIfPresent(String.self, forKey: .display)
            ?? Self.fallbackDisplay(keyCode: keyCode, modifiers: modifiers)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(enabled, forKey: .enabled)
        try container.encode(keyCode, forKey: .keyCode)
        try container.encode(modifiers & Self.allowedModifierMask, forKey: .modifiers)
        try container.encode(displayNameForPersistence, forKey: .display)
    }

    private var displayNameForPersistence: String {
        let trimmed = display.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? Self.fallbackDisplay(keyCode: keyCode, modifiers: modifiers) : trimmed
    }

    private static func fallbackDisplay(keyCode: UInt32, modifiers: UInt32) -> String {
        var result = ""
        if modifiers & controlModifier != 0 { result += "⌃" }
        if modifiers & optionModifier != 0 { result += "⌥" }
        if modifiers & shiftModifier != 0 { result += "⇧" }
        if modifiers & commandModifier != 0 { result += "⌘" }
        result += keyCode == 49 ? "Space" : "Key \(keyCode)"
        return result
    }
}

/// User-controlled presentation and startup preferences.
public struct LaunchPreferences: Codable, Hashable, Sendable {
    public var rows: Int
    public var columns: Int
    public var iconSize: Double
    public var showLabels: Bool
    public var launchAtLogin: Bool
    public var hiddenApplicationIDs: Set<String>
    public var showMenuBarIcon: Bool
    public var globalShortcut: LaunchShortcutDescriptor

    public init(
        rows: Int = 5,
        columns: Int = 7,
        iconSize: Double = 100,
        showLabels: Bool = true,
        launchAtLogin: Bool = false,
        hiddenApplicationIDs: Set<String> = [],
        showMenuBarIcon: Bool = true,
        globalShortcut: LaunchShortcutDescriptor = .optionSpace
    ) {
        self.rows = rows
        self.columns = columns
        self.iconSize = iconSize
        self.showLabels = showLabels
        self.launchAtLogin = launchAtLogin
        self.hiddenApplicationIDs = hiddenApplicationIDs
        self.showMenuBarIcon = showMenuBarIcon
        self.globalShortcut = globalShortcut.normalized()
    }

    public static let `default` = LaunchPreferences()

    private enum CodingKeys: String, CodingKey {
        case rows
        case columns
        case iconSize
        case showLabels
        case launchAtLogin
        case hiddenApplicationIDs
        case showMenuBarIcon
        case globalShortcut
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        rows = try container.decodeIfPresent(Int.self, forKey: .rows) ?? Self.default.rows
        columns = try container.decodeIfPresent(Int.self, forKey: .columns) ?? Self.default.columns
        iconSize = try container.decodeIfPresent(Double.self, forKey: .iconSize) ?? Self.default.iconSize
        showLabels = try container.decodeIfPresent(Bool.self, forKey: .showLabels) ?? Self.default.showLabels
        launchAtLogin = try container.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? Self.default.launchAtLogin
        hiddenApplicationIDs = try container.decodeIfPresent(Set<String>.self, forKey: .hiddenApplicationIDs) ?? []
        showMenuBarIcon = try container.decodeIfPresent(Bool.self, forKey: .showMenuBarIcon)
            ?? Self.default.showMenuBarIcon
        globalShortcut = try container.decodeIfPresent(
            LaunchShortcutDescriptor.self,
            forKey: .globalShortcut
        )?.normalized() ?? Self.default.globalShortcut
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(rows, forKey: .rows)
        try container.encode(columns, forKey: .columns)
        try container.encode(iconSize, forKey: .iconSize)
        try container.encode(showLabels, forKey: .showLabels)
        try container.encode(launchAtLogin, forKey: .launchAtLogin)
        try container.encode(hiddenApplicationIDs, forKey: .hiddenApplicationIDs)
        try container.encode(showMenuBarIcon, forKey: .showMenuBarIcon)
        try container.encode(globalShortcut.normalized(), forKey: .globalShortcut)
    }

    /// A defensive page capacity for data read from an older or hand-edited file.
    public var pageCapacity: Int {
        let safeRows = max(1, rows)
        let safeColumns = max(1, columns)
        let (capacity, overflow) = safeRows.multipliedReportingOverflow(by: safeColumns)
        return overflow ? Int.max : capacity
    }
}
