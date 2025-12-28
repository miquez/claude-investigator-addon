#!/usr/bin/env bash
set -e

# Arguments
REPO="$1"
ISSUE="$2"

if [ -z "$REPO" ] || [ -z "$ISSUE" ]; then
    echo "Usage: investigate.sh <owner/repo> <issue_number>"
    exit 1
fi

echo "=== Starting Investigation ==="
echo "Repository: $REPO"
echo "Issue: #$ISSUE"

# Configuration from environment
PHONE_IP="${TAILSCALE_PHONE_IP:-}"
PHONE_PORT="${PHONE_ADB_PORT:-5555}"
APP_PACKAGE="${DEFAULT_APP_PACKAGE:-com.fivethreeone.tracker}"
REPO_PATH="/data/repos/$REPO"

# Ensure repo is cloned and up to date (use gh for auth)
if [ ! -d "$REPO_PATH" ]; then
    echo "Cloning repository..."
    mkdir -p "$(dirname "$REPO_PATH")"
    gh repo clone "$REPO" "$REPO_PATH"
fi

cd "$REPO_PATH"
echo "Pulling latest changes..."
# Configure git to use gh for credentials
gh auth setup-git
git fetch origin
git reset --hard origin/main || git reset --hard origin/master

# Check ADB availability via Tailscale nc proxy (userspace networking workaround)
ADB_CONTEXT=""
ADB_TARGET=""
if [ -n "$PHONE_IP" ]; then
    echo "=== ADB Debug Info ==="
    echo "Target: $PHONE_IP:$PHONE_PORT"
    echo "Tailscale status:"
    tailscale status 2>&1 | head -5 || echo "tailscale status failed"

    # Use tailscale nc as proxy (required for userspace networking)
    LOCAL_ADB_PORT=15555
    echo "Setting up Tailscale nc proxy on localhost:$LOCAL_ADB_PORT..."
    pkill -f "socat.*$LOCAL_ADB_PORT" 2>/dev/null || true
    socat TCP-LISTEN:$LOCAL_ADB_PORT,fork,reuseaddr EXEC:"tailscale nc $PHONE_IP $PHONE_PORT" &
    SOCAT_PID=$!
    sleep 2

    echo "Attempting ADB connection via proxy..."
    ADB_OUTPUT=$(timeout 10 adb connect "localhost:$LOCAL_ADB_PORT" 2>&1) || ADB_OUTPUT="timeout"
    echo "ADB connect output: $ADB_OUTPUT"

    if echo "$ADB_OUTPUT" | grep -qE "connected to|already connected"; then
        ADB_CONTEXT="
## ADB Access (available via Tailscale proxy)
Phone is connected at localhost:$LOCAL_ADB_PORT (proxied to $PHONE_IP:$PHONE_PORT). You can:
- Pull logs: adb -s localhost:$LOCAL_ADB_PORT logcat -d -t 500 | grep -i '$APP_PACKAGE'
- Check prefs: adb -s localhost:$LOCAL_ADB_PORT shell 'run-as $APP_PACKAGE cat /data/data/$APP_PACKAGE/shared_prefs/*.xml'
- Get screenshot: adb -s localhost:$LOCAL_ADB_PORT exec-out screencap -p > /tmp/screen.png
- List files: adb -s localhost:$LOCAL_ADB_PORT shell 'run-as $APP_PACKAGE ls -la /data/data/$APP_PACKAGE/'
"
        echo "ADB connected successfully via Tailscale proxy"
    else
        ADB_CONTEXT="
## ADB Access (unavailable)
Phone at $PHONE_IP:$PHONE_PORT not reachable via Tailscale proxy. Investigate using codebase only.
"
        echo "ADB connection failed - continuing without device access"
        # Clean up socat if connection failed
        kill $SOCAT_PID 2>/dev/null || true
    fi
else
    ADB_CONTEXT="
## ADB Access (not configured)
No phone IP configured. Investigate using codebase only.
"
fi

# Log file for this investigation
LOG_FILE="/data/logs/investigation-${REPO//\//-}-$ISSUE-$(date +%Y%m%d-%H%M%S).log"
PROMPT_FILE="/tmp/claude-prompt-$$.txt"

echo "Running Claude investigation..."
echo "Log file: $LOG_FILE"

# Write prompt to temp file (handles complex quoting)
cat > "$PROMPT_FILE" << PROMPT_EOF
You are investigating issue #$ISSUE in the $REPO repository.

## Instructions
1. First, read the issue details:
   gh issue view $ISSUE

2. Search the codebase for relevant code using grep, glob, and read tools.
   Focus on files mentioned in the issue or related to the described behavior.

3. Check recent commits that might be related:
   git log --oneline -20
   git log --oneline --all --grep='<relevant keywords>'

4. If the repo has a CLAUDE.md file, read it for project context.

5. Form a hypothesis about the root cause based on your findings.
$ADB_CONTEXT
## Output Format

After investigation, post your findings as a comment on the issue using the gh CLI:

gh issue comment $ISSUE --body '## Investigation Findings

**Issue:** #$ISSUE

**Relevant Files:**
- \`path/to/file.kt:123\` - Brief description of relevance

**Analysis:**
[Your detailed analysis]

**Likely Root Cause:**
[Your hypothesis]

**Suggested Next Steps:**
1. [First action]
2. [Second action]

---
_Automated investigation by Claude Investigator on Home Assistant_
_Investigation completed: $(date -u +"%Y-%m-%d %H:%M UTC")_'

IMPORTANT: You must actually run the gh issue comment command to post your findings.
Do not just output what you would post - actually execute the command.
PROMPT_EOF

# Ensure claude user can access everything needed
chown -R claude:claude /data "$PROMPT_FILE"
chmod 644 "$PROMPT_FILE"

# Run Claude as non-root user (--dangerously-skip-permissions requires it)
PROMPT=$(cat "$PROMPT_FILE")
su -s /bin/bash -c "cd '$REPO_PATH' && HOME=/data claude --dangerously-skip-permissions \"\$PROMPT\"" claude 2>&1 | tee "$LOG_FILE"

rm -f "$PROMPT_FILE"

echo "=== Investigation Complete ==="
echo "Results posted to: https://github.com/$REPO/issues/$ISSUE"
