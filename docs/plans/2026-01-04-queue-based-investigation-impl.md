# Queue-Based Investigation System - Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Replace direct webhook-to-Claude spawning with a queue-based system that processes investigations sequentially, catches up on missed issues, and notifies issue authors.

**Architecture:** Node.js server manages queue files and spawns a single bash worker. Worker processes queue FIFO, tracks investigated issues in JSON, backs off on consecutive failures.

**Tech Stack:** Node.js (server), Bash (worker), JSON files (state)

---

## Task 1: Create Queue Helper Library

**Files:**
- Create: `claude-investigator/queue.sh`

**Step 1: Create queue.sh with all helper functions**

Create file `claude-investigator/queue.sh`:

```bash
#!/usr/bin/env bash
# Queue management functions for investigation system
# All state files live in /data/

QUEUE_FILE="/data/queue.json"
INVESTIGATED_FILE="/data/investigated.json"
WORKER_LOCK="/data/worker.lock"

# Initialize state files if they don't exist
queue_init() {
    [ -f "$QUEUE_FILE" ] || echo '[]' > "$QUEUE_FILE"
    [ -f "$INVESTIGATED_FILE" ] || echo '{}' > "$INVESTIGATED_FILE"
}

# Check if issue is already investigated
# Usage: is_investigated "owner/repo" 42
is_investigated() {
    local repo="$1"
    local issue="$2"
    queue_init
    jq -e --arg repo "$repo" --argjson issue "$issue" \
        '.[$repo] // [] | index($issue) != null' "$INVESTIGATED_FILE" > /dev/null 2>&1
}

# Check if issue is already in queue
# Usage: is_queued "owner/repo" 42
is_queued() {
    local repo="$1"
    local issue="$2"
    queue_init
    jq -e --arg repo "$repo" --argjson issue "$issue" \
        '.[] | select(.repo == $repo and .issue == $issue)' "$QUEUE_FILE" > /dev/null 2>&1
}

# Add issue to queue (if not already queued or investigated)
# Usage: queue_add "owner/repo" 42
# Returns: 0 if added, 1 if skipped
queue_add() {
    local repo="$1"
    local issue="$2"
    queue_init

    if is_investigated "$repo" "$issue"; then
        echo "Issue $repo#$issue already investigated, skipping"
        return 1
    fi

    if is_queued "$repo" "$issue"; then
        echo "Issue $repo#$issue already in queue, skipping"
        return 1
    fi

    local timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    local tmp=$(mktemp)
    jq --arg repo "$repo" --argjson issue "$issue" --arg ts "$timestamp" \
        '. + [{"repo": $repo, "issue": $issue, "added": $ts}]' "$QUEUE_FILE" > "$tmp" \
        && mv "$tmp" "$QUEUE_FILE"
    echo "Added $repo#$issue to queue"
    return 0
}

# Get next item from queue (first item, FIFO)
# Usage: item=$(queue_peek) # Returns JSON object or empty
queue_peek() {
    queue_init
    jq -c '.[0] // empty' "$QUEUE_FILE"
}

# Remove first item from queue
# Usage: queue_pop
queue_pop() {
    queue_init
    local tmp=$(mktemp)
    jq '.[1:]' "$QUEUE_FILE" > "$tmp" && mv "$tmp" "$QUEUE_FILE"
}

# Mark issue as investigated
# Usage: mark_investigated "owner/repo" 42
mark_investigated() {
    local repo="$1"
    local issue="$2"
    queue_init
    local tmp=$(mktemp)
    jq --arg repo "$repo" --argjson issue "$issue" \
        '.[$repo] = ((.[$repo] // []) + [$issue] | unique)' "$INVESTIGATED_FILE" > "$tmp" \
        && mv "$tmp" "$INVESTIGATED_FILE"
    echo "Marked $repo#$issue as investigated"
}

# Get queue length
# Usage: len=$(queue_length)
queue_length() {
    queue_init
    jq 'length' "$QUEUE_FILE"
}

# Check if worker is running (PID alive)
# Usage: if worker_running; then ...
worker_running() {
    [ -f "$WORKER_LOCK" ] || return 1
    local pid=$(cat "$WORKER_LOCK" 2>/dev/null)
    [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null
}

# Acquire worker lock
# Usage: worker_lock_acquire
worker_lock_acquire() {
    echo $$ > "$WORKER_LOCK"
}

# Release worker lock
# Usage: worker_lock_release
worker_lock_release() {
    rm -f "$WORKER_LOCK"
}
```

**Step 2: Verify syntax**

Run: `bash -n claude-investigator/queue.sh`
Expected: No output (no syntax errors)

**Step 3: Commit**

```bash
git add claude-investigator/queue.sh
git commit -m "feat: add queue helper library for investigation system"
```

---

## Task 2: Create Worker Script

**Files:**
- Create: `claude-investigator/worker.sh`
- Reference: `claude-investigator/investigate.sh` (for investigation logic)

**Step 1: Create worker.sh**

Create file `claude-investigator/worker.sh`:

```bash
#!/usr/bin/env bash
set -e

# Source queue helpers
source /queue.sh

echo "=== Investigation Worker Started ==="
echo "PID: $$"

# Acquire lock
worker_lock_acquire
trap 'worker_lock_release; echo "Worker exiting"' EXIT

# Failure tracking for backoff
CONSECUTIVE_FAILURES=0
MAX_FAILURES_BEFORE_BACKOFF=3
MAX_FAILURES_BEFORE_EXIT=6
BACKOFF_SECONDS=1800  # 30 minutes

# Main loop
while true; do
    # Get next item
    ITEM=$(queue_peek)

    if [ -z "$ITEM" ]; then
        echo "Queue empty, worker finished"
        break
    fi

    REPO=$(echo "$ITEM" | jq -r '.repo')
    ISSUE=$(echo "$ITEM" | jq -r '.issue')

    echo ""
    echo "=== Processing $REPO#$ISSUE ==="
    echo "Queue length: $(queue_length)"
    echo "Consecutive failures: $CONSECUTIVE_FAILURES"

    # Run investigation
    if /investigate-issue.sh "$REPO" "$ISSUE"; then
        echo "Investigation succeeded for $REPO#$ISSUE"
        mark_investigated "$REPO" "$ISSUE"
        queue_pop
        CONSECUTIVE_FAILURES=0
    else
        echo "Investigation failed for $REPO#$ISSUE"
        CONSECUTIVE_FAILURES=$((CONSECUTIVE_FAILURES + 1))

        # Move failed item to end of queue (so we try others first)
        queue_pop
        queue_add "$REPO" "$ISSUE" || true  # Re-add to end

        if [ $CONSECUTIVE_FAILURES -ge $MAX_FAILURES_BEFORE_EXIT ]; then
            echo "ERROR: $CONSECUTIVE_FAILURES consecutive failures, giving up"
            echo "Remaining items will be processed on next trigger"
            break
        elif [ $CONSECUTIVE_FAILURES -ge $MAX_FAILURES_BEFORE_BACKOFF ]; then
            echo "WARNING: $CONSECUTIVE_FAILURES consecutive failures, backing off for 30 minutes"
            sleep $BACKOFF_SECONDS
            CONSECUTIVE_FAILURES=0  # Reset after backoff
        fi
    fi
done

echo "=== Investigation Worker Finished ==="
```

**Step 2: Verify syntax**

Run: `bash -n claude-investigator/worker.sh`
Expected: No output (no syntax errors)

**Step 3: Commit**

```bash
git add claude-investigator/worker.sh
git commit -m "feat: add worker script for sequential queue processing"
```

---

## Task 3: Extract Investigation Logic from investigate.sh

**Files:**
- Modify: `claude-investigator/investigate.sh` → rename to `investigate-issue.sh`
- Modify: Update to fetch issue author and include in comment

**Step 1: Rename and update investigate.sh**

Rename file: `claude-investigator/investigate.sh` → `claude-investigator/investigate-issue.sh`

**Step 2: Add issue author fetch after repo setup (around line 36)**

After `git reset --hard origin/main || git reset --hard origin/master`, add:

```bash
# Fetch issue author for notification
echo "Fetching issue author..."
ISSUE_AUTHOR=$(gh issue view "$ISSUE" --repo "$REPO" --json author --jq '.author.login' 2>/dev/null || echo "")
if [ -n "$ISSUE_AUTHOR" ]; then
    echo "Issue author: @$ISSUE_AUTHOR"
else
    echo "Could not determine issue author"
fi
```

**Step 3: Update comment template in Claude prompt (around line 210)**

Change the comment template from:
```
gh issue comment $ISSUE --body '## Investigation Findings
```

To:
```
gh issue comment $ISSUE --repo $REPO --body '## Investigation Findings

@'"$ISSUE_AUTHOR"' _(investigation complete)_
```

Note: The `--repo $REPO` flag ensures it works when running from anywhere.

**Step 4: Remove the `set -e` at the top**

Change line 2 from `set -e` to `set -eo pipefail` but wrap the main logic so we can return proper exit codes. Actually, keep `set -e` but ensure we return meaningful exit codes for the worker.

The script should exit 0 on success, non-zero on failure. Currently it does this implicitly. Add explicit exit at the end:

```bash
echo "=== Investigation Complete ==="
echo "Results posted to: https://github.com/$REPO/issues/$ISSUE"
exit 0
```

**Step 5: Verify syntax**

Run: `bash -n claude-investigator/investigate-issue.sh`
Expected: No output (no syntax errors)

**Step 6: Commit**

```bash
git add claude-investigator/investigate-issue.sh
git rm claude-investigator/investigate.sh 2>/dev/null || true
git commit -m "refactor: rename investigate.sh to investigate-issue.sh, add author notification"
```

---

## Task 4: Create New Entry Point investigate.sh

**Files:**
- Create: `claude-investigator/investigate.sh` (new, thin wrapper)

**Step 1: Create new investigate.sh as CLI entry point**

Create file `claude-investigator/investigate.sh`:

```bash
#!/usr/bin/env bash
# CLI entry point for manual investigation
# Usage: investigate.sh <owner/repo> <issue_number>
#
# This script:
# 1. Adds the issue to the queue
# 2. Scans for other uninvestigated open issues
# 3. Starts worker if not already running

set -e

source /queue.sh

REPO="$1"
ISSUE="$2"

if [ -z "$REPO" ] || [ -z "$ISSUE" ]; then
    echo "Usage: investigate.sh <owner/repo> <issue_number>"
    exit 1
fi

echo "=== Investigation Trigger ==="
echo "Repository: $REPO"
echo "Issue: #$ISSUE"

# Initialize queue
queue_init

# Add triggered issue to queue
queue_add "$REPO" "$ISSUE" || true

# Catchup scan: find all open issues not yet investigated
echo ""
echo "=== Catchup Scan ==="
echo "Checking for uninvestigated open issues in $REPO..."

OPEN_ISSUES=$(gh issue list --repo "$REPO" --state open --json number --jq '.[].number' 2>/dev/null || echo "")

if [ -n "$OPEN_ISSUES" ]; then
    for issue_num in $OPEN_ISSUES; do
        if ! is_investigated "$REPO" "$issue_num" && ! is_queued "$REPO" "$issue_num"; then
            echo "Found uninvestigated issue: #$issue_num"
            queue_add "$REPO" "$issue_num" || true
        fi
    done
else
    echo "Could not fetch open issues (gh CLI error or no issues)"
fi

echo ""
echo "Queue length: $(queue_length)"

# Start worker if not running
if worker_running; then
    echo "Worker already running (PID $(cat $WORKER_LOCK)), it will pick up queued items"
else
    echo "Starting worker..."
    nohup /worker.sh >> /data/logs/worker-$(date +%Y%m%d-%H%M%S).log 2>&1 &
    echo "Worker started with PID $!"
fi

echo "=== Trigger Complete ==="
```

**Step 2: Verify syntax**

Run: `bash -n claude-investigator/investigate.sh`
Expected: No output (no syntax errors)

**Step 3: Commit**

```bash
git add claude-investigator/investigate.sh
git commit -m "feat: new investigate.sh entry point with queue and catchup"
```

---

## Task 5: Update server.js for Queue-Based Processing

**Files:**
- Modify: `claude-investigator/server.js`

**Step 1: Replace server.js with queue-aware version**

Replace entire contents of `claude-investigator/server.js`:

```javascript
const http = require('http');
const { spawn, execSync } = require('child_process');
const url = require('url');
const fs = require('fs');
const path = require('path');

const PORT = 8099;
const QUEUE_FILE = '/data/queue.json';
const INVESTIGATED_FILE = '/data/investigated.json';
const WORKER_LOCK = '/data/worker.lock';

// Initialize state files
function initState() {
    if (!fs.existsSync(QUEUE_FILE)) {
        fs.writeFileSync(QUEUE_FILE, '[]');
    }
    if (!fs.existsSync(INVESTIGATED_FILE)) {
        fs.writeFileSync(INVESTIGATED_FILE, '{}');
    }
}

// Read JSON file safely
function readJson(file, defaultValue) {
    try {
        return JSON.parse(fs.readFileSync(file, 'utf8'));
    } catch {
        return defaultValue;
    }
}

// Write JSON file
function writeJson(file, data) {
    fs.writeFileSync(file, JSON.stringify(data, null, 2));
}

// Check if issue is investigated
function isInvestigated(repo, issue) {
    const investigated = readJson(INVESTIGATED_FILE, {});
    return (investigated[repo] || []).includes(issue);
}

// Check if issue is in queue
function isQueued(repo, issue) {
    const queue = readJson(QUEUE_FILE, []);
    return queue.some(item => item.repo === repo && item.issue === issue);
}

// Add to queue
function addToQueue(repo, issue) {
    if (isInvestigated(repo, issue) || isQueued(repo, issue)) {
        return false;
    }
    const queue = readJson(QUEUE_FILE, []);
    queue.push({
        repo,
        issue,
        added: new Date().toISOString()
    });
    writeJson(QUEUE_FILE, queue);
    return true;
}

// Get open issues from GitHub
function getOpenIssues(repo) {
    try {
        const output = execSync(
            `gh issue list --repo "${repo}" --state open --json number --jq '.[].number'`,
            { encoding: 'utf8', timeout: 30000 }
        );
        return output.trim().split('\n').filter(Boolean).map(Number);
    } catch (e) {
        console.error(`Failed to fetch open issues for ${repo}:`, e.message);
        return [];
    }
}

// Check if worker is running
function isWorkerRunning() {
    if (!fs.existsSync(WORKER_LOCK)) return false;
    try {
        const pid = parseInt(fs.readFileSync(WORKER_LOCK, 'utf8').trim());
        process.kill(pid, 0); // Check if process exists
        return true;
    } catch {
        return false;
    }
}

// Start worker
function startWorker() {
    const logFile = `/data/logs/worker-${new Date().toISOString().replace(/[:.]/g, '-')}.log`;
    const logStream = fs.openSync(logFile, 'a');

    const child = spawn('/worker.sh', [], {
        detached: true,
        stdio: ['ignore', logStream, logStream],
        env: process.env
    });
    child.unref();

    console.log(`Worker started with PID ${child.pid}, logging to ${logFile}`);
    return child.pid;
}

// Handle investigate request
function handleInvestigate(repo, issue, res) {
    initState();

    const added = addToQueue(repo, issue);
    console.log(`Issue ${repo}#${issue}: ${added ? 'added to queue' : 'already queued/investigated'}`);

    // Catchup scan
    console.log(`Scanning for uninvestigated issues in ${repo}...`);
    const openIssues = getOpenIssues(repo);
    let catchupCount = 0;

    for (const issueNum of openIssues) {
        if (addToQueue(repo, issueNum)) {
            console.log(`Catchup: added ${repo}#${issueNum}`);
            catchupCount++;
        }
    }

    const queue = readJson(QUEUE_FILE, []);
    console.log(`Queue length: ${queue.length}, catchup added: ${catchupCount}`);

    // Start worker if needed
    let workerStatus;
    if (isWorkerRunning()) {
        workerStatus = 'already_running';
        console.log('Worker already running');
    } else if (queue.length > 0) {
        startWorker();
        workerStatus = 'started';
    } else {
        workerStatus = 'not_needed';
    }

    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({
        status: 'queued',
        repo,
        issue,
        queue_length: queue.length,
        catchup_added: catchupCount,
        worker: workerStatus
    }));
}

const server = http.createServer((req, res) => {
    const parsedUrl = url.parse(req.url, true);

    if (req.method === 'POST' && parsedUrl.pathname === '/investigate') {
        let body = '';
        req.on('data', chunk => { body += chunk; });
        req.on('end', () => {
            try {
                const data = JSON.parse(body);
                const repo = data.repo;
                const issue = parseInt(data.issue);

                if (!repo || !issue) {
                    res.writeHead(400, { 'Content-Type': 'application/json' });
                    res.end(JSON.stringify({ error: 'Missing repo or issue' }));
                    return;
                }

                handleInvestigate(repo, issue, res);
            } catch (e) {
                console.error('Error:', e);
                res.writeHead(400, { 'Content-Type': 'application/json' });
                res.end(JSON.stringify({ error: e.message }));
            }
        });
    } else if (req.method === 'GET' && parsedUrl.pathname === '/health') {
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ status: 'ok' }));
    } else if (req.method === 'GET' && parsedUrl.pathname === '/queue') {
        initState();
        const queue = readJson(QUEUE_FILE, []);
        const investigated = readJson(INVESTIGATED_FILE, {});
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({
            queue_length: queue.length,
            queue,
            investigated,
            worker_running: isWorkerRunning()
        }));
    } else {
        res.writeHead(404, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ error: 'Not found' }));
    }
});

server.listen(PORT, '0.0.0.0', () => {
    console.log(`Investigation server listening on port ${PORT}`);
    initState();
});
```

**Step 2: Verify syntax**

Run: `node --check claude-investigator/server.js`
Expected: No output (no syntax errors)

**Step 3: Commit**

```bash
git add claude-investigator/server.js
git commit -m "feat: update server.js with queue management and catchup scanning"
```

---

## Task 6: Update Dockerfile for New Files

**Files:**
- Modify: `claude-investigator/Dockerfile`

**Step 1: Update COPY commands**

Find lines 53-56:
```dockerfile
COPY run.sh /run.sh
COPY investigate.sh /investigate.sh
COPY server.js /server.js
RUN chmod +x /run.sh /investigate.sh
```

Replace with:
```dockerfile
COPY run.sh /run.sh
COPY investigate.sh /investigate.sh
COPY investigate-issue.sh /investigate-issue.sh
COPY worker.sh /worker.sh
COPY queue.sh /queue.sh
COPY server.js /server.js
RUN chmod +x /run.sh /investigate.sh /investigate-issue.sh /worker.sh /queue.sh
```

**Step 2: Commit**

```bash
git add claude-investigator/Dockerfile
git commit -m "build: add new queue scripts to Dockerfile"
```

---

## Task 7: Update CLAUDE.md Documentation

**Files:**
- Modify: `CLAUDE.md`

**Step 1: Update the "How it works" section**

Replace the existing "How it works" section with:

```markdown
## How it works

1. GitHub webhook triggers Home Assistant automation on issue creation
2. HA calls the add-on's `/investigate` endpoint
3. Server adds issue to queue, scans for other uninvestigated issues
4. If no worker running, spawns worker process
5. Worker processes queue sequentially (one investigation at a time)
6. Each investigation: clones/updates repo, optionally connects to phone via ADB/Tailscale
7. Claude Code runs in print mode with limited tools to investigate
8. Findings posted as issue comment (mentioning issue author); draft PR created if confident
9. Worker continues until queue empty or hits failure backoff
```

**Step 2: Add new section about queue system**

Add after "Key behaviors":

```markdown
## Queue System

- **State files** in `/data/`:
  - `queue.json` - pending investigations
  - `investigated.json` - completed issues per repo
  - `worker.lock` - running worker PID

- **Catchup scanning**: Every trigger also scans for all uninvestigated open issues in that repo

- **Failure handling**: 3 consecutive failures → 30 min backoff; 6 failures → worker exits

- **Endpoints**:
  - `POST /investigate` - trigger investigation (queues + starts worker)
  - `GET /queue` - view queue status and investigated issues
  - `GET /health` - health check
```

**Step 3: Commit**

```bash
git add CLAUDE.md
git commit -m "docs: update CLAUDE.md with queue system documentation"
```

---

## Task 8: Final Integration Test

**Step 1: Build and deploy to Home Assistant**

Push changes:
```bash
git push origin main
```

**Step 2: Rebuild add-on**

In Home Assistant: Settings → Add-ons → Claude Investigator → Rebuild

**Step 3: Verify endpoints**

From HA terminal or curl:
```bash
# Health check
curl http://localhost:8099/health

# Queue status (should be empty initially)
curl http://localhost:8099/queue

# Trigger investigation
curl -X POST http://localhost:8099/investigate \
  -H "Content-Type: application/json" \
  -d '{"repo":"your/repo","issue":1}'

# Check queue again
curl http://localhost:8099/queue
```

**Step 4: Verify investigation completes**

- Check add-on logs for worker output
- Check GitHub issue for comment with `@author` mention
- Check `/data/investigated.json` for completed issue

**Step 5: Final commit (version bump)**

```bash
# Update version in config.yaml
# Update CHANGELOG.md
git add -A
git commit -m "bump: version 0.10.0 - queue-based investigation system"
git push origin main
```

---

## Summary

| Task | Description | Files |
|------|-------------|-------|
| 1 | Queue helper library | `queue.sh` (new) |
| 2 | Worker script | `worker.sh` (new) |
| 3 | Extract investigation logic | `investigate-issue.sh` (renamed + modified) |
| 4 | New entry point | `investigate.sh` (new) |
| 5 | Update server | `server.js` (modified) |
| 6 | Update Dockerfile | `Dockerfile` (modified) |
| 7 | Update docs | `CLAUDE.md` (modified) |
| 8 | Integration test | Manual verification |
