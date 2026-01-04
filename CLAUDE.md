# Claude Investigator Add-on

Home Assistant add-on that automatically investigates GitHub issues using Claude Code CLI.

## Architecture

- `claude-investigator/investigate.sh` - Main investigation script, spawned per issue
- `claude-investigator/server.js` - HTTP server receiving webhook triggers
- `claude-investigator/run.sh` - Container entrypoint (starts Tailscale, ttyd, server)
- `claude-investigator/Dockerfile` - Alpine-based image with Claude Code, ADB, gh CLI

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

## Key behaviors

- Runs Claude in print mode (`-p`) with `--allowedTools 'Bash,Read,Write,Edit,Glob,Grep'`
- ADB access via Tailscale proxy (optional, fail-fast with 3 retries)
- Posts findings as issue comments
- Creates draft PRs when confidence criteria are met
- Guardrails prevent pushes to main, app reinstalls, and destructive SQL

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

## Testing changes

1. Push changes to main
2. In Home Assistant: Settings -> Add-ons -> Claude Investigator -> Rebuild
3. Check add-on logs for errors
4. Trigger a test investigation via webhook or shell command

## Local infrastructure

See `.claude-local.md` (gitignored) for IPs, SSH commands, and Home Assistant URLs.
