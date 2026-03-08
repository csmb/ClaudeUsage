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
   - **Bundle Identifier:** `com.yourname.ClaudeUsage` (anything you like)
4. Choose a save location and click **Create**

### 2 · Add source files

1. Delete the generated `ContentView.swift` (move to Trash)
2. In the Project Navigator, right-click the `ClaudeUsage` group → **Add Files to "ClaudeUsage"…**
3. Select the `Sources/` folder from this repo; tick **Create groups** and **Add to target: ClaudeUsage**
4. Click **Add**

You should now see these groups in the navigator:
```
ClaudeUsage/
  Sources/
    App/      (ClaudeUsageApp.swift, AppDelegate.swift)
    Models/   (UsageData.swift, Credentials.swift, AppSettings.swift)
    Services/ (KeychainService.swift, APIService.swift, CacheService.swift)
    Managers/ (AppState.swift, PollingManager.swift)
    UI/       (StatusItemController.swift, PopoverView.swift, SettingsView.swift)
```

### 3 · Configure entitlements

1. In the Project Navigator, select the project → **ClaudeUsage** target → **Signing & Capabilities**
2. Click the **+** button → search for **App Sandbox** → add it
3. Tick only **Outgoing Connections (Client)** under Network
4. Do **NOT** tick any file system access checkboxes
5. Xcode auto-creates a `.entitlements` file — replace its contents with those from `ClaudeUsage.entitlements` in this repo (or just confirm the two keys match)

### 4 · Configure Info.plist

In **Target → Info**, add a new row:

| Key | Type | Value |
|---|---|---|
| `Application is agent (UIElement)` | Boolean | `YES` |

This hides the app from the Dock and ⌘-Tab switcher.

### 5 · Build & Run

Press **⌘R**. The first time:
- macOS shows a Keychain consent dialog → click **Always Allow**
- A colored usage indicator appears in your menu bar
- Click it to open the usage popover

---

## Features

- **Menu bar icon** — color-coded: green → yellow → orange → red
- **Usage cards** — 5-hour window, 7-day window, and Opus (if applicable)
- **Countdown timers** — live seconds-resolution reset countdown
- **Adaptive polling** — 30 s (critical) → 5 min (low usage)
- **Offline cache** — shows last-known data with age indicator
- **Notifications** — alerts at 75 %, 90 %, 95 % thresholds
- **Settings** — refresh interval, display mode, launch at login, notification toggles

---

## Verification checklist

```bash
# Confirm no shell-based Keychain access
grep -r "security find"    Sources/   # should return nothing
grep -r "NSTask"           Sources/   # should return nothing
grep -r "Process()"        Sources/   # should return nothing

# Confirm sandbox is on
grep -A1 "app-sandbox" ClaudeUsage.entitlements
# expected: <true/>

# Confirm all network calls go to api.anthropic.com
grep -r "http" Sources/
# expected: only "https://api.anthropic.com"
```

---

## Troubleshooting

| Symptom | Fix |
|---|---|
| Menu bar shows "..." permanently | Click the menu bar item, check the error banner in the popover |
| "Item not found" error | Make sure you are logged in to Claude Code (`claude --version` works) |
| Keychain dialog never appears | The app may not be sandboxed; check entitlements |
| Stuck on cached data | Click the ↻ button in the popover to force refresh |
