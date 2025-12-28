#!/usr/bin/env bash
set -e

echo "=== Claude Investigator Add-on Starting ==="

# Read config from HA options.json using jq
CONFIG_PATH=/data/options.json
if [ -f "$CONFIG_PATH" ]; then
    GITHUB_TOKEN=$(jq -r '.github_token // empty' "$CONFIG_PATH")
    TAILSCALE_PHONE_IP=$(jq -r '.tailscale_phone_ip // empty' "$CONFIG_PATH")
    PHONE_ADB_PORT=$(jq -r '.phone_adb_port // 5555' "$CONFIG_PATH")
    DEFAULT_APP_PACKAGE=$(jq -r '.default_app_package // "com.fivethreeone.tracker"' "$CONFIG_PATH")
    echo "Config loaded from $CONFIG_PATH"
else
    echo "WARNING: No config file found at $CONFIG_PATH"
    GITHUB_TOKEN="${GITHUB_TOKEN:-}"
    TAILSCALE_PHONE_IP="${TAILSCALE_PHONE_IP:-}"
    PHONE_ADB_PORT="${PHONE_ADB_PORT:-5555}"
    DEFAULT_APP_PACKAGE="${DEFAULT_APP_PACKAGE:-com.fivethreeone.tracker}"
fi

# Configure GitHub CLI
if [ -n "$GITHUB_TOKEN" ]; then
    echo "$GITHUB_TOKEN" | gh auth login --with-token
    echo "GitHub CLI authenticated"
else
    echo "WARNING: No GitHub token configured"
fi

# Export environment for investigate.sh
export GITHUB_TOKEN
export TAILSCALE_PHONE_IP
export PHONE_ADB_PORT
export DEFAULT_APP_PACKAGE

# Set up Claude config directory
export XDG_CONFIG_HOME=/data/.config
export XDG_DATA_HOME=/data/.local/share
export XDG_STATE_HOME=/data/.local/state
export XDG_CACHE_HOME=/data/.cache
mkdir -p "$XDG_CONFIG_HOME" "$XDG_DATA_HOME" "$XDG_STATE_HOME" "$XDG_CACHE_HOME"

echo "Configuration:"
echo "  - Phone IP: ${TAILSCALE_PHONE_IP:-not set}"
echo "  - ADB Port: $PHONE_ADB_PORT"
echo "  - App Package: $DEFAULT_APP_PACKAGE"
echo ""
echo "Claude Investigator ready. Waiting for investigation requests..."

# Keep container running
tail -f /dev/null
