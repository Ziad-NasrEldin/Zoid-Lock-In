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

echo "==> Verifying LaunchDaemon helper packaging..."
HELPER_BIN="${MACOS_DIR}/ZoidLockInDaemon"
HELPER_PLIST="${LAUNCH_DAEMONS_DIR}/com.mavoid.zoidlockin.helper.plist"
if [[ ! -x "${HELPER_BIN}" ]]; then
    echo "error: packaged helper missing or not executable: ${HELPER_BIN}" >&2
    exit 1
fi
if [[ ! -f "${HELPER_PLIST}" ]]; then
    echo "error: packaged LaunchDaemon plist missing: ${HELPER_PLIST}" >&2
    exit 1
fi
python3 - "${HELPER_PLIST}" <<'PY'
import plistlib
import sys

path = sys.argv[1]
with open(path, "rb") as handle:
    payload = plistlib.load(handle)

errors = []
if payload.get("Label") != "com.mavoid.zoidlockin.helper":
    errors.append("Label")
if payload.get("BundleProgram") != "Contents/MacOS/ZoidLockInDaemon":
    errors.append("BundleProgram")
if payload.get("KeepAlive") is not True:
    errors.append("KeepAlive")
if payload.get("ThrottleInterval") != 1:
    errors.append("ThrottleInterval")
mach = payload.get("MachServices") or {}
if mach.get("com.mavoid.zoidlockin.enforcement") is not True:
    errors.append("MachServices")
if errors:
    raise SystemExit("error: packaged LaunchDaemon plist failed fail-closed checks: " + ", ".join(errors))
print("==> LaunchDaemon plist fail-closed checks passed")
PY

echo "==> Packaged helper layout:"
ls -l "${HELPER_BIN}" "${HELPER_PLIST}"

echo "==> Successfully packaged: ${APP_BUNDLE}"
echo "==> To launch: open \"${APP_BUNDLE}\""
