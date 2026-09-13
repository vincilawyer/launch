#!/bin/zsh
set -euo pipefail

SCRIPT_DIRECTORY="${0:A:h}"
PROJECT_DIRECTORY="${SCRIPT_DIRECTORY:h}"
APP_DIRECTORY="${PROJECT_DIRECTORY}/dist/启动台.app"
INFO_PLIST="${PROJECT_DIRECTORY}/Resources/Info.plist"

WORK_DIRECTORY=""

cleanup() {
    if [[ -n "${WORK_DIRECTORY}" && -d "${WORK_DIRECTORY}" ]]; then
        rm -rf -- "${WORK_DIRECTORY}"
    fi
}

trap cleanup EXIT INT TERM HUP

"${SCRIPT_DIRECTORY}/build-app.sh"

APP_VERSION="$(/usr/bin/plutil -extract CFBundleShortVersionString raw -o - "${INFO_PLIST}")"
DMG_NAME="启动台-${APP_VERSION}.dmg"
OUTPUT_DMG="${PROJECT_DIRECTORY}/dist/${DMG_NAME}"

WORK_DIRECTORY="$(mktemp -d /private/tmp/Launch-package.XXXXXX)"
STAGING_DIRECTORY="${WORK_DIRECTORY}/staging"
TEMPORARY_DMG="${WORK_DIRECTORY}/${DMG_NAME}"

mkdir -p "${STAGING_DIRECTORY}"
/usr/bin/ditto "${APP_DIRECTORY}" "${STAGING_DIRECTORY}/启动台.app"
/bin/ln -s /Applications "${STAGING_DIRECTORY}/应用程序"

codesign --verify --deep --strict "${STAGING_DIRECTORY}/启动台.app"

hdiutil create \
    -volname "启动台" \
    -srcfolder "${STAGING_DIRECTORY}" \
    -fs HFS+ \
    -format UDZO \
    -ov \
    "${TEMPORARY_DMG}"

hdiutil verify "${TEMPORARY_DMG}"
/bin/mv -f "${TEMPORARY_DMG}" "${OUTPUT_DMG}"
hdiutil verify "${OUTPUT_DMG}"

echo "Packaged and verified ${OUTPUT_DMG}"
