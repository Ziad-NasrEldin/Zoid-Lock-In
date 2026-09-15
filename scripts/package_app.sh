#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="Zoid Lock In"
BUILD_DIR="${REPO_DIR}/build"
APP_BUNDLE="${BUILD_DIR}/${APP_NAME}.app"
CONTENTS_DIR="${APP_BUNDLE}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"

echo "==> Building ZoidLockInApp in release mode..."
cd "${REPO_DIR}"
swift build -c release --product ZoidLockInApp

BIN_PATH="$(swift build -c release --show-bin-path)/ZoidLockInApp"

echo "==> Packaging ${APP_BUNDLE}..."
rm -rf "${APP_BUNDLE}"
mkdir -p "${MACOS_DIR}" "${RESOURCES_DIR}"

# Copy compiled executable
cp "${BIN_PATH}" "${MACOS_DIR}/ZoidLockInApp"
chmod +x "${MACOS_DIR}/ZoidLockInApp"

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
