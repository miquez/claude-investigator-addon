# Changelog

## 0.6.0

- Feature: Add ttyd web terminal for interactive Claude OAuth authentication
- Fix: Update Tailscale to 1.92.4 (installed directly instead of outdated Alpine package)
- Access web terminal via HA sidebar to run `claude` and complete OAuth login

## 0.5.0

- Feature: Simplified credential handling
- Removed complex gnome-keyring setup

## 0.4.0

- Feature: Built-in Tailscale support for ADB over VPN
- Add tailscale_auth_key config option
- ADB timeout reduced to 10 seconds

## 0.3.0

- Feature: Add HTTP API server on port 8099 for triggering investigations
- Replace shell_command with rest_command approach

## 0.2.0

- Feature: Add Claude OAuth credentials support for subscription-based auth
- Credentials from laptop can be transferred to add-on config

## 0.1.1

- Fix: Use jq instead of bashio for config reading
- Fix: Add proper config loading feedback in logs

## 0.1.0

- Initial release
