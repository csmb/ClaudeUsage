# CLAUDE.md — ClaudeUsage

macOS menu bar app that shows Claude Code API usage (5-hour, 7-day, and 7-day Opus windows) with color-coded percentages, time-series charts, countdown timers, and threshold notifications.

## Stack

- **Language:** Swift (SwiftUI + AppKit hybrid)
- **Target:** macOS 13+ (Ventura), no sandbox
- **UI:** Menu bar popover (LSUIElement — no Dock icon), SwiftUI `Settings` scene for preferences
- **Charts:** Swift Charts (`AreaMark` + `LineMark`)
- **Build:** Xcode project (`ClaudeUsage.xcodeproj`), no SPM dependencies

## Architecture

```
Sources/
  App/
    ClaudeUsageApp.swift    — @main entry point, NSApplicationDelegateAdaptor
    AppDelegate.swift       — Lifecycle: sleep/wake, polling start/stop, credential watcher
  Models/
    UsageData.swift         — UsageResponse, UsageWindow, UsageDataPoint, UtilizationLevel
    Credentials.swift       — OAuthCredentials, ClaudeKeychainWrapper (JSON shape)
    AppSettings.swift       — UserDefaults-backed settings (display mode, poll interval, notifications)
  Services/
    APIService.swift        — GET https://api.anthropic.com/api/oauth/usage (ephemeral URLSession, no redirects)
    KeychainService.swift   — Reads Claude Code OAuth token via Security framework (SecItemCopyMatching)
    CacheService.swift      — ~/Library/Caches/<bundle>/usage_cache.json (24h TTL)
    HistoryService.swift    — ~/Library/Caches/<bundle>/usage_history.json (rolling 7-day log)
  Managers/
    AppState.swift          — Central @MainActor ObservableObject: refresh logic, notifications, computed UI state
    PollingManager.swift    — Adaptive timer (30s–300s based on utilization), circuit breaker after 5 failures
  UI/
    StatusItemController.swift — NSStatusItem + NSPopover, observes AppState via Combine
    PopoverView.swift       — Usage cards, charts, countdown timers, refresh button, settings gear
    SettingsView.swift      — Display mode, poll interval, notification thresholds, login items
Scripts/
  gen_icon.swift            — Icon generator
```

## Key Design Decisions

- **No shell-outs for keychain access.** Uses native `SecItemCopyMatching` so macOS shows a proper consent dialog. Never uses `Process()`, `NSTask`, or `/usr/bin/security`.
- **Adaptive polling.** Poll interval adjusts based on utilization level: low=5m, medium=2m, high=1m, critical=30s. Configurable override in settings.
- **Credential watcher.** Monitors `~/.config/claude/` for file changes to detect token refreshes without aggressive polling.
- **Color-coded per window.** Each usage window (5h, 7d) is colored independently by its own utilization level, both in the menu bar and in the popover cards.
- **Dark/light mode aware.** All accent colors have explicit dark and light variants.

## Auth Flow

1. User logs into Claude Code CLI (stores OAuth token in macOS keychain under service `"Claude Code-credentials"`)
2. App reads token via `SecItemCopyMatching` — macOS shows keychain consent dialog on first access
3. Token has `expiresAt` (unix ms) with 5-minute validity buffer
4. `CredentialWatcher` monitors `~/.config/claude/` to detect token refreshes
5. API requests use `Authorization: Bearer <token>` + `anthropic-beta: oauth-2025-04-20`

## API

- **Endpoint:** `GET https://api.anthropic.com/api/oauth/usage`
- **Response shape:** `{ five_hour: { utilization, resets_at }, seven_day: {...}, seven_day_opus: {...} }`
- **Error handling:** 401 → invalid credentials, 429 → rate limited (respects `Retry-After`), circuit breaker after 5 consecutive failures

## Build & Run

```bash
# Build from command line
xcodebuild -project ClaudeUsage.xcodeproj -scheme ClaudeUsage -configuration Debug build

# Or open in Xcode
open ClaudeUsage.xcodeproj
```

## Data Storage

| What | Where |
|------|-------|
| OAuth token | macOS system keychain (service: `Claude Code-credentials`) |
| Usage cache | `~/Library/Caches/<bundleID>/usage_cache.json` |
| Usage history | `~/Library/Caches/<bundleID>/usage_history.json` |
| Settings | `UserDefaults.standard` |
