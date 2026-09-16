#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="Zoid Lock In"
BUILD_DIR="${REPO_DIR}/build"
APP_BUNDLE="${BUILD_DIR}/${APP_NAME}.app"
CONTENTS_DIR="${APP_BUNDLE}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"
LAUNCH_DAEMONS_DIR="${CONTENTS_DIR}/Library/LaunchDaemons"

echo "==> Building ZoidLockInApp and ZoidLockInDaemon in release mode..."
cd "${REPO_DIR}"
swift build -c release --product ZoidLockInApp
swift build -c release --product ZoidLockInDaemon

BIN_DIR="$(swift build -c release --show-bin-path)"
BIN_PATH="${BIN_DIR}/ZoidLockInApp"
DAEMON_BIN_PATH="${BIN_DIR}/ZoidLockInDaemon"

echo "==> Packaging ${APP_BUNDLE}..."
rm -rf "${APP_BUNDLE}"
mkdir -p "${MACOS_DIR}" "${RESOURCES_DIR}" "${LAUNCH_DAEMONS_DIR}"

# Copy compiled executables
cp "${BIN_PATH}" "${MACOS_DIR}/ZoidLockInApp"
chmod +x "${MACOS_DIR}/ZoidLockInApp"

cp "${DAEMON_BIN_PATH}" "${MACOS_DIR}/ZoidLockInDaemon"
chmod +x "${MACOS_DIR}/ZoidLockInDaemon"

# Copy LaunchDaemon plist for SMAppService.daemon
cp "${REPO_DIR}/Resources/com.mavoid.zoidlockin.helper.plist" "${LAUNCH_DAEMONS_DIR}/com.mavoid.zoidlockin.helper.plist"

# Copy Info.plist
cp "${REPO_DIR}/Resources/App-Info.plist" "${CONTENTS_DIR}/Info.plist"

# Generate and copy icon if not already present
if [[ ! -f "${REPO_DIR}/Resources/AppIcon.icns" ]]; then
    echo "==> Generating AppIcon.icns..."
    python3 "${REPO_DIR}/scripts/generate_app_icon.py"
fi
cp "${REPO_DIR}/Resources/AppIcon.icns" "${RESOURCES_DIR}/AppIcon.icns"

# Ad-hoc code sign so macOS LaunchServices trusts it
echo "==> Ad-hoc signing ${APP_BUNDLE}..."
codesign --force --deep --sign - "${APP_BUNDLE}"

echo "==> Successfully packaged: ${APP_BUNDLE}"
echo "==> To launch: open \"${APP_BUNDLE}\""
