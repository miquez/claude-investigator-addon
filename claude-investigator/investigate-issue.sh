#!/usr/bin/env bash
set -eo pipefail

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
# Configure git to use gh for credentials and mark repo as safe
gh auth setup-git
git config --global --add safe.directory "$REPO_PATH"
git fetch origin
git reset --hard origin/main || git reset --hard origin/master

# Fetch issue author for notification
echo "Fetching issue author..."
ISSUE_AUTHOR=$(gh issue view "$ISSUE" --repo "$REPO" --json author --jq '.author.login' 2>/dev/null || echo "")
if [ -n "$ISSUE_AUTHOR" ]; then
    echo "Issue author: @$ISSUE_AUTHOR"
else
    echo "Could not determine issue author"
fi

# Check ADB availability via Tailscale nc proxy (userspace networking workaround)
# Fail-fast: pre-check connectivity before starting socat
ADB_CONTEXT=""
ADB_AVAILABLE=false
LOCAL_ADB_PORT=15555

if [ -n "$PHONE_IP" ]; then
    echo "=== ADB Connection Check ==="
    echo "Target: $PHONE_IP:$PHONE_PORT"

    # Pre-check: test Tailscale connectivity before starting socat (3 attempts, 5s each)
    PRECHECK_OK=false
    for attempt in 1 2 3; do
        echo "Pre-check attempt $attempt/3..."
        if timeout 5 tailscale nc "$PHONE_IP" "$PHONE_PORT" </dev/null 2>&1 | head -c 1 | grep -q . || \
           timeout 5 tailscale nc "$PHONE_IP" "$PHONE_PORT" </dev/null 2>/dev/null; then
            # Connection succeeded or at least didn't error immediately
            PRECHECK_OK=true
            echo "Pre-check passed on attempt $attempt"
            break
        else
            echo "Pre-check attempt $attempt failed"
            [ $attempt -lt 3 ] && sleep 2
        fi
    done

    if [ "$PRECHECK_OK" = true ]; then
        # Start socat proxy
        echo "Starting Tailscale nc proxy on localhost:$LOCAL_ADB_PORT..."
        pkill -f "socat.*$LOCAL_ADB_PORT" 2>/dev/null || true
        socat TCP-LISTEN:$LOCAL_ADB_PORT,fork,reuseaddr EXEC:"tailscale nc $PHONE_IP $PHONE_PORT" &
        SOCAT_PID=$!
        sleep 2

        # Try ADB connection (3 attempts, 5s each)
        for attempt in 1 2 3; do
            echo "ADB connect attempt $attempt/3..."
            ADB_OUTPUT=$(timeout 5 adb connect "localhost:$LOCAL_ADB_PORT" 2>&1) || ADB_OUTPUT="timeout"
            echo "ADB output: $ADB_OUTPUT"

            if echo "$ADB_OUTPUT" | grep -qE "connected to|already connected"; then
                ADB_AVAILABLE=true
                echo "ADB connected successfully on attempt $attempt"
                break
            else
                echo "ADB attempt $attempt failed"
                [ $attempt -lt 3 ] && sleep 2
            fi
        done

        if [ "$ADB_AVAILABLE" = true ]; then
            ADB_CONTEXT="
## ADB Access (available via Tailscale proxy)
Phone is connected at localhost:$LOCAL_ADB_PORT (proxied to $PHONE_IP:$PHONE_PORT). You can:
- Pull app logs: adb -s localhost:$LOCAL_ADB_PORT logcat -d -t 500 | grep -i '$APP_PACKAGE'
- Check SharedPreferences: adb -s localhost:$LOCAL_ADB_PORT shell 'run-as $APP_PACKAGE cat /data/data/$APP_PACKAGE/shared_prefs/*.xml'
- Take screenshot: adb -s localhost:$LOCAL_ADB_PORT exec-out screencap -p > /tmp/screen.png && echo 'Screenshot saved to /tmp/screen.png'
- List app data: adb -s localhost:$LOCAL_ADB_PORT shell 'run-as $APP_PACKAGE ls -la /data/data/$APP_PACKAGE/'
- Access Room database: adb -s localhost:$LOCAL_ADB_PORT shell 'run-as $APP_PACKAGE cat /data/data/$APP_PACKAGE/databases/*.db' > /tmp/app.db
- Query Room DB (after pulling): sqlite3 /tmp/app.db 'SELECT * FROM tablename LIMIT 10;'
"
        else
            ADB_CONTEXT="
## ADB Access (unavailable)
Phone at $PHONE_IP:$PHONE_PORT not reachable. DO NOT attempt any adb commands. Investigate using codebase only.
"
            echo "ADB connection failed after 3 attempts - continuing without device access"
            kill $SOCAT_PID 2>/dev/null || true
        fi
    else
        ADB_CONTEXT="
## ADB Access (unavailable)
Phone at $PHONE_IP:$PHONE_PORT not reachable via Tailscale (pre-check failed). DO NOT attempt any adb commands. Investigate using codebase only.
"
        echo "Tailscale pre-check failed after 3 attempts - skipping ADB entirely"
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

6. When analyzing, focus on ROOT CAUSE not symptoms:
   - Look for similar WORKING code to compare against
   - Trace data flow: where does the bad value originate?
   - State hypothesis clearly: "X causes this because Y"

7. Assess your confidence before deciding next steps:
   - Did you identify specific file(s) and line(s)?
   - Do you understand WHY the bug happens (not just what)?
   - Is the fix localized (3 files or fewer)?
   - Is the intended behavior unambiguous from the issue?

   If ALL are true -> create a draft PR (see section below)
   If ANY are false -> comment with findings only, suggest manual next steps
$ADB_CONTEXT
## Backend Database Access
Production PostgreSQL (use sparingly, READ ONLY):
- Connection: psql "postgresql://swarm_visualizer_user:1nlk2RVUmnpg2G2HO4QmaMhncX3ysg40@dpg-d41s9rer433s73cv4t00-a.frankfurt-postgres.render.com/swarm_visualizer?options=-c%20search_path=tracker,public"
- Example queries:
  - List tables: \dt
  - Check user data: SELECT * FROM users LIMIT 5;
  - Check workouts: SELECT * FROM workouts ORDER BY created_at DESC LIMIT 10;
- IMPORTANT: Only SELECT queries allowed. No DROP, DELETE, UPDATE, INSERT.

## GUARDRAILS - NEVER DO THESE
- NEVER git push to main or master (feature branches only)
- NEVER run adb install or adb uninstall
- NEVER run SQL that modifies data (only SELECT queries)
- NEVER attempt adb commands if ADB was marked unavailable above

## Creating a Draft PR (when confident)

If you meet ALL confidence criteria above, prepare a fix:

1. Create a branch:
   git checkout -b fix/issue-$ISSUE

2. Make the fix, following existing patterns in the codebase

3. Commit:
   git add -A
   git commit -m "fix: <brief description> (closes #$ISSUE)"

4. Push the branch:
   git push -u origin fix/issue-$ISSUE

5. Create draft PR:
   gh pr create --draft --title "fix: <description>" --body "Fixes #$ISSUE

   ## Summary
   <1-2 sentences>

   ## Changes
   - <file>: <what changed>

   ---
   _Automated fix by Claude Investigator_"

## Output Format

After investigation, post your findings as a comment on the issue using the gh CLI.
Include the draft PR link if you created one.

gh issue comment $ISSUE --repo $REPO --body '## Investigation Findings

@'"$ISSUE_AUTHOR"' _(investigation complete)_

**Relevant Files:**
- \`path/to/file.kt:123\` - Brief description of relevance

**Root Cause:**
X causes this because Y

**Fix Prepared:** [Draft PR #N](link)
_(or "Manual fix needed - see suggested steps below" if not confident enough)_

**Suggested Next Steps:**
1. [First action - e.g., "Review and merge the draft PR" or manual steps]
2. [Second action]

---
_Automated investigation by Claude Investigator_
_Investigation completed: $(date -u +"%Y-%m-%d %H:%M UTC")_'

IMPORTANT: You must actually run the gh issue comment command to post your findings.
Do not just output what you would post - actually execute the command.
PROMPT_EOF

# Ensure claude user can access everything needed
chown -R claude:claude /data "$PROMPT_FILE"
chmod 644 "$PROMPT_FILE"

# Run Claude as non-root user with allowed tools via stdin
# Using -p (print mode) with --allowedTools for headless execution
cat "$PROMPT_FILE" | su -s /bin/bash -c "cd '$REPO_PATH' && HOME=/data claude -p --allowedTools 'Bash,Read,Write,Edit,Glob,Grep'" claude 2>&1 | tee "$LOG_FILE"

rm -f "$PROMPT_FILE"

echo "=== Investigation Complete ==="
echo "Results posted to: https://github.com/$REPO/issues/$ISSUE"
