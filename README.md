# ClaudeUsage

A macOS menu bar app that shows your Claude Code usage across rate-limit windows.

## Features

- **Menu bar** — 5h and 7d usage shown inline, each color-coded independently
- **Color coding** — green → yellow → orange → red as utilization climbs
- **Usage cards** — 5-hour window, 7-day window, Opus (when applicable)
- **Countdown timers** — live reset countdown
- **Adaptive polling** — 30s at critical usage, 5 min at low
- **Offline cache** — shows last-known data with age indicator on open
- **Notifications** — alerts at 75%, 90%, 95% thresholds

## Security

| Property | Value |
|---|---|
| App Sandbox | Disabled (required to read Claude Code's Keychain item) |
| Keychain access | `SecItemCopyMatching` — macOS may prompt on first launch |
| Network | Outbound HTTPS to `api.anthropic.com` only |
| Shell commands | None — no `Process()`, `NSTask`, or `security` CLI calls |

## Build & Install

```bash
# Build
xcodebuild -project ClaudeUsage.xcodeproj -scheme ClaudeUsage -configuration Debug build

# Install (replace with your DerivedData path)
rm -rf /Applications/ClaudeUsage.app
cp -R ~/Library/Developer/Xcode/DerivedData/ClaudeUsage-*/Build/Products/Debug/ClaudeUsage.app /Applications/
```

Or open in Xcode and press `⌘R`.

## Troubleshooting

| Symptom | Fix |
|---|---|
| Menu bar shows "…" permanently | Open the popover and check the error banner |
| "Item not found" error | Make sure you are logged in to Claude Code (`claude login`) |
| "Rate limited" error | Wait 30s — the cooldown will re-enable the refresh button |
| Stale icon in Finder after update | Run `killall Finder && killall Dock` |
