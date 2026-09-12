#!/bin/zsh
set -euo pipefail

SCRIPT_DIRECTORY="${0:A:h}"
PROJECT_DIRECTORY="${SCRIPT_DIRECTORY:h}"
INFO_PLIST="${PROJECT_DIRECTORY}/Resources/Info.plist"

WORK_DIRECTORY=""

cleanup() {
    if [[ -n "${WORK_DIRECTORY}" && -d "${WORK_DIRECTORY}" ]]; then
        rm -rf -- "${WORK_DIRECTORY}"
    fi
}

trap cleanup EXIT INT TERM HUP

APP_VERSION="$(/usr/bin/plutil -extract CFBundleShortVersionString raw -o - "${INFO_PLIST}")"
ARCHIVE_BASENAME="Launch-${APP_VERSION}-source"
OUTPUT_ARCHIVE="${PROJECT_DIRECTORY}/dist/${ARCHIVE_BASENAME}.zip"

WORK_DIRECTORY="$(mktemp -d /private/tmp/Launch-source.XXXXXX)"
STAGING_DIRECTORY="${WORK_DIRECTORY}/${ARCHIVE_BASENAME}"
TEMPORARY_ARCHIVE="${WORK_DIRECTORY}/${ARCHIVE_BASENAME}.zip"

mkdir -p "${STAGING_DIRECTORY}" "${PROJECT_DIRECTORY}/dist"
/usr/bin/rsync -a \
    --exclude '.build/' \
    --exclude 'dist/' \
    --exclude '.git/' \
    --exclude '.DS_Store' \
    --exclude '.swiftpm/' \
    --exclude 'DerivedData/' \
    --exclude '*.log' \
    --exclude '*.xcuserstate' \
    "${PROJECT_DIRECTORY}/" "${STAGING_DIRECTORY}/"

COPYFILE_DISABLE=1 /usr/bin/ditto -c -k --keepParent \
    --norsrc --noextattr --noqtn --noacl --nopersistRootless \
    "${STAGING_DIRECTORY}" "${TEMPORARY_ARCHIVE}"
/usr/bin/unzip -tq "${TEMPORARY_ARCHIVE}"
/bin/mv -f "${TEMPORARY_ARCHIVE}" "${OUTPUT_ARCHIVE}"
/usr/bin/unzip -tq "${OUTPUT_ARCHIVE}"

echo "Packaged and verified ${OUTPUT_ARCHIVE}"
