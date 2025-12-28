# Claude Investigator Add-on for Home Assistant

Automated bug investigation using Claude Code CLI. When a GitHub issue is created, Claude investigates the codebase and posts findings as a comment.

## Installation

1. Add this repository to Home Assistant:
   - Go to **Settings → Add-ons → Add-on Store**
   - Click ⋮ (menu) → **Repositories**
   - Add: `https://github.com/miquez/claude-investigator-addon`

2. Install "Claude Investigator" from the add-on store

3. Configure the add-on:
   - `github_token`: Personal access token with `repo` scope
   - `tailscale_phone_ip`: (Optional) Phone's Tailscale IP for ADB access
   - `phone_adb_port`: (Optional) ADB port, default 5555
   - `default_app_package`: (Optional) Android package for logs, default `com.fivethreeone.tracker`

4. Start the add-on

## Home Assistant Configuration

Add to `configuration.yaml`:

```yaml
shell_command:
  investigate_bug: >-
    docker exec addon_local_claude_investigator
    /investigate.sh "{{ repo }}" "{{ issue }}"
```

Add automation in `automations.yaml`:

```yaml
- id: github_bug_investigation
  alias: "GitHub Bug Investigation"
  trigger:
    - platform: webhook
      webhook_id: github_issue_created
      allowed_methods:
        - POST
  condition:
    - condition: template
      value_template: "{{ trigger.json.action == 'opened' }}"
  action:
    - service: shell_command.investigate_bug
      data:
        repo: "{{ trigger.json.repository.full_name }}"
        issue: "{{ trigger.json.issue.number }}"
```

## GitHub Webhook Setup

For each repository you want to monitor:

1. Go to repo → **Settings → Webhooks → Add webhook**
2. Payload URL: `https://your-ha-domain.com/api/webhook/github_issue_created`
3. Content type: `application/json`
4. Events: Select **Issues** only
5. Save

## Usage

1. Create an issue in a monitored repository
2. Claude Investigator automatically:
   - Pulls the repository
   - Reads the issue
   - Searches the codebase
   - (Optional) Pulls device logs via ADB
   - Posts findings as a comment

## Requirements

- Home Assistant with Supervisor
- GitHub Personal Access Token
- (Optional) Tailscale for ADB access to Android device

## License

MIT
