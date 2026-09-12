#!/bin/zsh
set -euo pipefail

SCRIPT_DIRECTORY="${0:A:h}"
PROJECT_DIRECTORY="${SCRIPT_DIRECTORY:h}"
APP_DIRECTORY="${PROJECT_DIRECTORY}/dist/Launch.app"
CONTENTS_DIRECTORY="${APP_DIRECTORY}/Contents"
MODULE_CACHE_DIRECTORY="${PROJECT_DIRECTORY}/.build/ModuleCache"
ICON_GENERATOR_BINARY="${PROJECT_DIRECTORY}/.build/LaunchCreateIcon"

cd "${PROJECT_DIRECTORY}"

source "${SCRIPT_DIRECTORY}/resolve-compatible-sdk.zsh"
COMPATIBLE_SDK="$(resolve_compatible_macos_sdk \
    "${PROJECT_DIRECTORY}" \
    "${PROJECT_DIRECTORY}/Sources/Launch/Utilities/LaunchText.swift")"
export SDKROOT="${COMPATIBLE_SDK}"
export SWIFT_MODULECACHE_PATH="${MODULE_CACHE_DIRECTORY}"
export CLANG_MODULE_CACHE_PATH="${MODULE_CACHE_DIRECTORY}"

swift build --disable-sandbox -c release --product Launch
BIN_DIRECTORY="$(swift build --disable-sandbox -c release --show-bin-path)"

rm -rf "${APP_DIRECTORY}"
mkdir -p "${CONTENTS_DIRECTORY}/MacOS" "${CONTENTS_DIRECTORY}/Resources"

cp "${BIN_DIRECTORY}/Launch" "${CONTENTS_DIRECTORY}/MacOS/Launch"
cp "${PROJECT_DIRECTORY}/Resources/Info.plist" "${CONTENTS_DIRECTORY}/Info.plist"

xcrun swiftc \
    -sdk "${COMPATIBLE_SDK}" \
    -module-cache-path "${MODULE_CACHE_DIRECTORY}" \
    -framework AppKit \
    "${PROJECT_DIRECTORY}/scripts/create-icon.swift" \
    -o "${ICON_GENERATOR_BINARY}"
"${ICON_GENERATOR_BINARY}" \
    "${CONTENTS_DIRECTORY}/Resources/Launch.icns"

chmod 755 "${CONTENTS_DIRECTORY}/MacOS/Launch"
codesign --force --deep --sign - "${APP_DIRECTORY}"

echo "Built ${APP_DIRECTORY}"
