#!/usr/bin/env bash
# ==============================================================================
# GreenHarvest Local Gateway - Safe OTA Binary Updater
# Downloads pre-compiled binary from public GitHub Releases, verifies, swaps,
# and safely restarts local_gw service with auto-rollback on failure.
# ==============================================================================

set -u

LOG_FILE="/tmp/local_gw_update.log"
exec > >(tee -a "${LOG_FILE}") 2>&1

echo "========================================================"
echo "[OTA] Starting Gateway Updater at $(date -u '+%Y-%m-%d %H:%M:%SZ')"
echo "========================================================"

REPO_RELEASES="caonhungoc/local_gateway_releases"
TARGET_VERSION="${1:-latest}"

# 1. Detect Host Architecture
UNAME_M=$(uname -m)
case "${UNAME_M}" in
  aarch64|arm64)
    ARCH_BIN="local_gw-linux-arm64"
    ;;
  armv7l|armhf)
    ARCH_BIN="local_gw-linux-armv7"
    ;;
  x86_64|amd64)
    ARCH_BIN="local_gw-linux-amd64"
    ;;
  *)
    echo "[OTA ERROR] Unsupported architecture: ${UNAME_M}"
    exit 1
    ;;
esac

echo "[OTA] Host Architecture: ${UNAME_M} -> Target Binary: ${ARCH_BIN}"

# 2. Resolve Target Version Tag
if [ "${TARGET_VERSION}" = "latest" ]; then
  echo "[OTA] Fetching latest release tag from GitHub..."
  RESOLVED_TAG=$(curl -s "https://api.github.com/repos/${REPO_RELEASES}/releases/latest" | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
  if [ -z "${RESOLVED_TAG}" ]; then
    echo "[OTA ERROR] Failed to resolve latest tag from https://api.github.com/repos/${REPO_RELEASES}/releases/latest"
    exit 1
  fi
  TARGET_VERSION="${RESOLVED_TAG}"
fi

echo "[OTA] Target Version: ${TARGET_VERSION}"

# 3. Locate Target Binary on Local Machine
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PARENT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

if [ -f "${PARENT_DIR}/local_gw" ]; then
  LOCAL_BIN="${PARENT_DIR}/local_gw"
elif [ -f "/opt/local_gw/local_gw" ]; then
  LOCAL_BIN="/opt/local_gw/local_gw"
elif [ -n "$(which local_gw 2>/dev/null)" ]; then
  LOCAL_BIN="$(which local_gw)"
else
  LOCAL_BIN="${PARENT_DIR}/local_gw"
fi

echo "[OTA] Local Binary Target: ${LOCAL_BIN}"

# 4. Download New Binary
DOWNLOAD_URL="https://github.com/${REPO_RELEASES}/releases/download/${TARGET_VERSION}/${ARCH_BIN}"
TMP_BIN="/tmp/local_gw.new"
rm -f "${TMP_BIN}"

echo "[OTA] Downloading binary from: ${DOWNLOAD_URL}"
if ! curl -fsSL -o "${TMP_BIN}" "${DOWNLOAD_URL}"; then
  echo "[OTA ERROR] Download failed from ${DOWNLOAD_URL}"
  exit 1
fi

chmod +x "${TMP_BIN}"

# 5. Verify Binary (Dry-run --version)
echo "[OTA] Verifying downloaded binary..."
if ! "${TMP_BIN}" --version; then
  echo "[OTA ERROR] Verification failed: new binary failed to execute --version"
  rm -f "${TMP_BIN}"
  exit 1
fi

# 6. Backup Current Binary
BACKUP_BIN="${LOCAL_BIN}.bak"
if [ -f "${LOCAL_BIN}" ]; then
  echo "[OTA] Creating backup of current binary: ${BACKUP_BIN}"
  cp -f "${LOCAL_BIN}" "${BACKUP_BIN}"
fi

# 7. Atomic Swap
echo "[OTA] Swapping binary into place: ${LOCAL_BIN}"
mv -f "${TMP_BIN}" "${LOCAL_BIN}"
chmod +x "${LOCAL_BIN}"

# 8. Restart Service
echo "[OTA] Restarting local_gw systemd service..."
if command -v systemctl >/dev/null 2>&1; then
  sudo systemctl restart local_gw || true
  sleep 3

  # 9. Health Check (Check if service is active)
  if systemctl is-active --quiet local_gw; then
    echo "[OTA SUCCESS] local_gw is running normally with version ${TARGET_VERSION}!"
    exit 0
  else
    echo "[OTA WARNING] local_gw failed to start after update! Rolling back..."
    if [ -f "${BACKUP_BIN}" ]; then
      mv -f "${BACKUP_BIN}" "${LOCAL_BIN}"
      sudo systemctl restart local_gw || true
      echo "[OTA ROLLBACK] Restored previous binary and restarted local_gw."
    fi
    exit 1
  fi
else
  echo "[OTA] systemctl not found; binary updated successfully. Please restart manually."
fi
