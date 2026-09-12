#!/bin/zsh
set -euo pipefail

SCRIPT_DIRECTORY="${0:A:h}"
PROJECT_DIRECTORY="${SCRIPT_DIRECTORY:h}"
cd "${PROJECT_DIRECTORY}"

source "${SCRIPT_DIRECTORY}/resolve-compatible-sdk.zsh"
export SDKROOT="$(resolve_compatible_macos_sdk \
    "${PROJECT_DIRECTORY}" \
    "${PROJECT_DIRECTORY}/Sources/Launch/Utilities/LaunchText.swift")"
export SWIFT_MODULECACHE_PATH="${PROJECT_DIRECTORY}/.build/ModuleCache"
export CLANG_MODULE_CACHE_PATH="${PROJECT_DIRECTORY}/.build/ModuleCache"

swift build --disable-sandbox

xcrun swiftc \
    -sdk "${SDKROOT}" \
    -swift-version 5 \
    -parse-as-library \
    Sources/Launch/Models/LaunchPreferences.swift \
    Sources/Launch/Services/ShellIntegrationPolicy.swift \
    Tests/ShellIntegrationChecks.swift \
    -o .build/ShellIntegrationChecks

.build/ShellIntegrationChecks

xcrun swiftc \
    -sdk "${SDKROOT}" \
    -swift-version 5 \
    -parse-as-library \
    Sources/Launch/Services/StableTouchIdentityKey.swift \
    Tests/TouchIdentityChecks.swift \
    -o .build/TouchIdentityChecks

.build/TouchIdentityChecks

CORE_SOURCES=(
    Sources/Launch/Models/InstalledApplication.swift
    Sources/Launch/Models/LaunchEntry.swift
    Sources/Launch/Models/LaunchFolder.swift
    Sources/Launch/Models/LaunchLayout.swift
    Sources/Launch/Models/LaunchPreferences.swift
    Sources/Launch/Models/LauncherPageInteraction.swift
    Sources/Launch/Models/WeChatCompanionRefresh.swift
    Sources/Launch/Services/AppScanner.swift
    Sources/Launch/Services/ApplicationDirectoryMonitor.swift
    Sources/Launch/Services/LaunchAtLoginManager.swift
    Sources/Launch/Services/LayoutStore.swift
    Sources/Launch/Services/ShellIntegrationPolicy.swift
    Sources/Launch/Services/WeChatDualLaunchService.swift
    Sources/Launch/Services/WeChatCompanionRefreshService.swift
    Sources/Launch/Utilities/LaunchText.swift
    Sources/Launch/Controllers/LauncherModel.swift
)

xcrun swiftc \
    -sdk "${SDKROOT}" \
    -swift-version 5 \
    -parse-as-library \
    "${CORE_SOURCES[@]}" \
    Tests/CoreChecks.swift \
    -o .build/CoreChecks

.build/CoreChecks

xcrun swiftc \
    -sdk "${SDKROOT}" \
    -swift-version 5 \
    -parse-as-library \
    Sources/Launch/Services/TrackpadGestureManager.swift \
    Tests/GestureChecks.swift \
    -o .build/GestureChecks

.build/GestureChecks

xcrun swiftc \
    -sdk "${SDKROOT}" \
    -swift-version 5 \
    -parse-as-library \
    Sources/Launch/Services/MenuBarCoverGeometry.swift \
    Tests/MenuBarCoverChecks.swift \
    -o .build/MenuBarCoverChecks

.build/MenuBarCoverChecks
