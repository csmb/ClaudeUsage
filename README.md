# ClaudeUsage — macOS Menu Bar App

A clean, sandboxed macOS menu bar app that shows your Claude Code API usage.

## Security properties

| Property | Value |
|---|---|
| App Sandbox | **Enabled** |
| Keychain access | `SecItemCopyMatching` (triggers macOS consent dialog) |
| Network | Outbound HTTPS to `api.anthropic.com` only |
| Shell commands | **None** — no `Process()`, `NSTask`, or `security` CLI calls |

On first launch macOS will ask:

> **"ClaudeUsage" wants to access "Claude Code-credentials" in your keychain.**

Click **Always Allow**. That dialog is the correct, auditable behavior.

---

## Xcode Setup

### 1 · Create the project

1. Open **Xcode → File → New → Project**
2. Choose **macOS → App**
3. Fill in:
   - **Product Name:** `ClaudeUsage`
   - **Interface:** SwiftUI
   - **Language:** Swift
   - **Bundle Identifier:** `com.yourname.ClaudeUsage`
4. Save inside this directory (`~/ClaudeUsage/`) and click **Create**

### 2 · Add source files

1. Delete the generated `ContentView.swift`
2. Right-click the `ClaudeUsage` group → **Add Files to "ClaudeUsage"…**
3. Select the `Sources/` folder; tick **Create groups** and **Add to target: ClaudeUsage**
4. Click **Add**

### 3 · Configure entitlements

1. Target → **Signing & Capabilities** → **+ Capability** → **App Sandbox**
   - If App Sandbox isn't visible, go to Target → **Build Settings**, search `CODE_SIGN_ENTITLEMENTS`, and set the value to `ClaudeUsage.entitlements`
2. Tick only **Outgoing Connections (Client)** under Network
3. No file system access boxes should be checked

### 4 · Hide the Dock icon

In Target → **Info**, add: `Application is agent (UIElement)` = **YES**

### 5 · Build & Run (`⌘R`)

On first launch:
- macOS shows a Keychain consent dialog → click **Always Allow**
- A colored usage indicator appears in your menu bar

---

## Features

- **Menu bar** — both 5h and 7d windows shown, each color-coded independently
- **Color coding** — green → yellow → orange → red as usage climbs
- **Usage cards** — 5-hour window, 7-day window, Opus (if applicable)
- **Countdown timers** — live reset countdown (days/hours/mins when >24h out)
- **Adaptive polling** — 30s (critical) → 5 min (low usage)
- **Refresh cooldown** — 30s minimum between manual refreshes to avoid rate limiting
- **Offline cache** — shows last-known data with age indicator
- **Notifications** — alerts at 75%, 90%, 95% thresholds
- **Settings** — refresh interval, display mode, launch at login, notification toggles

---

## Verification

```bash
# No shell-based Keychain access
grep -r "security find"  Sources/   # → nothing
grep -r "NSTask"         Sources/   # → nothing
grep -r "Process()"      Sources/   # → nothing

# Sandbox is on
grep -A1 "app-sandbox" ClaudeUsage.entitlements
# → <true/>

# All network calls go to api.anthropic.com
grep -r "http" Sources/
# → only https://api.anthropic.com
```

---

## Troubleshooting

| Symptom | Fix |
|---|---|
| Menu bar shows "…" permanently | Open the popover and check the error banner |
| "Item not found" error | Make sure you are logged in to Claude Code |
| Keychain dialog never appears | Check that App Sandbox is enabled in entitlements |
| "Rate limited" error | Wait 30s — the cooldown will re-enable the refresh button |
| Stuck on cached data | Wait for the cooldown, then click ↻ |
