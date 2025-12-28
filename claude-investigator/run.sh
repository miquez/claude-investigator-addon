#!/usr/bin/env bash
set -e

# Use bashio for HA add-on logging if available
if command -v bashio &> /dev/null; then
    CONFIG_PATH=/data/options.json
    GITHUB_TOKEN=$(bashio::config 'github_token')
    TAILSCALE_PHONE_IP=$(bashio::config 'tailscale_phone_ip')
    PHONE_ADB_PORT=$(bashio::config 'phone_adb_port')
    DEFAULT_APP_PACKAGE=$(bashio::config 'default_app_package')
else
    # Fallback for local testing
    GITHUB_TOKEN="${GITHUB_TOKEN:-}"
    TAILSCALE_PHONE_IP="${TAILSCALE_PHONE_IP:-}"
    PHONE_ADB_PORT="${PHONE_ADB_PORT:-5555}"
    DEFAULT_APP_PACKAGE="${DEFAULT_APP_PACKAGE:-com.fivethreeone.tracker}"
fi

echo "=== Claude Investigator Add-on Starting ==="

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

echo "Claude Investigator ready. Waiting for investigation requests..."

# Keep container running
tail -f /dev/null
