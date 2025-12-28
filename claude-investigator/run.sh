#!/usr/bin/env bash
set -e

echo "=== Claude Investigator Add-on Starting ==="

# Read config from HA options.json using jq
CONFIG_PATH=/data/options.json
if [ -f "$CONFIG_PATH" ]; then
    CLAUDE_CREDENTIALS=$(jq -r '.claude_credentials // empty' "$CONFIG_PATH")
    GITHUB_TOKEN=$(jq -r '.github_token // empty' "$CONFIG_PATH")
    TAILSCALE_AUTH_KEY=$(jq -r '.tailscale_auth_key // empty' "$CONFIG_PATH")
    TAILSCALE_PHONE_IP=$(jq -r '.tailscale_phone_ip // empty' "$CONFIG_PATH")
    PHONE_ADB_PORT=$(jq -r '.phone_adb_port // 5555' "$CONFIG_PATH")
    DEFAULT_APP_PACKAGE=$(jq -r '.default_app_package // "com.fivethreeone.tracker"' "$CONFIG_PATH")
    echo "Config loaded from $CONFIG_PATH"
else
    echo "WARNING: No config file found at $CONFIG_PATH"
    CLAUDE_CREDENTIALS="${CLAUDE_CREDENTIALS:-}"
    GITHUB_TOKEN="${GITHUB_TOKEN:-}"
    TAILSCALE_AUTH_KEY="${TAILSCALE_AUTH_KEY:-}"
    TAILSCALE_PHONE_IP="${TAILSCALE_PHONE_IP:-}"
    PHONE_ADB_PORT="${PHONE_ADB_PORT:-5555}"
    DEFAULT_APP_PACKAGE="${DEFAULT_APP_PACKAGE:-com.fivethreeone.tracker}"
fi

# Configure Claude Code credentials
if [ -n "$CLAUDE_CREDENTIALS" ]; then
    # Claude Code on Linux stores credentials via libsecret/keyring
    # We'll use a credentials file approach instead
    CLAUDE_CREDS_DIR="/data/.config/claude-code"
    mkdir -p "$CLAUDE_CREDS_DIR"
    echo "$CLAUDE_CREDENTIALS" > "$CLAUDE_CREDS_DIR/credentials.json"
    chmod 600 "$CLAUDE_CREDS_DIR/credentials.json"
    echo "Claude credentials configured"
else
    echo "WARNING: No Claude credentials configured - investigations will fail"
fi

# Configure GitHub CLI
if [ -n "$GITHUB_TOKEN" ]; then
    echo "$GITHUB_TOKEN" | gh auth login --with-token
    echo "GitHub CLI authenticated"
else
    echo "WARNING: No GitHub token configured"
fi

# Start Tailscale if auth key provided
if [ -n "$TAILSCALE_AUTH_KEY" ]; then
    echo "Starting Tailscale..."
    mkdir -p /data/tailscale
    tailscaled --state=/data/tailscale/tailscaled.state --socket=/var/run/tailscale/tailscaled.sock &
    sleep 2
    tailscale up --authkey="$TAILSCALE_AUTH_KEY" --hostname=claude-investigator --accept-routes
    echo "Tailscale connected"
    tailscale status
else
    echo "WARNING: No Tailscale auth key - ADB over Tailscale won't work"
fi

# Export environment for investigate.sh
export HOME=/data
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
echo "Starting investigation server on port 8099..."

# Start the HTTP server
exec node /server.js
