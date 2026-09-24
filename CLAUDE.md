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
    AppDelegate.swift       — Lifecycle: sleep/wake, polling start/stop, launch/exit logging
  Models/
    UsageData.swift         — UsageResponse, UsageWindow, UsageDataPoint, UtilizationLevel
    Credentials.swift       — OAuthCredentials, ClaudeKeychainWrapper (JSON shape)
    AppSettings.swift       — UserDefaults-backed settings (poll interval, notifications)
  Services/
    APIService.swift        — GET https://api.anthropic.com/api/oauth/usage (ephemeral URLSession, no redirects)
    KeychainService.swift   — Reads Claude Code's OAuth token by running /usr/bin/security (see its header)
    CacheService.swift      — ~/Library/Caches/<bundle>/usage_cache.json (24h TTL)
    HistoryService.swift    — ~/Library/Caches/<bundle>/usage_history.json (rolling 7-day log)
    LogFile.swift           — Append-only timestamped log in Caches, trimmed past 64 KB (used by both logs below)
    LifecycleLog.swift      — Launch/exit log: who quit the app, SIGTERM, runs that ended without an exit
  Managers/
    AppState.swift          — Central @MainActor ObservableObject: refresh logic, notifications, computed UI state
    PollingManager.swift    — Adaptive timer (30s–300s based on utilization)
  UI/
    StatusItemController.swift — NSStatusItem + NSPopover, observes AppState via Combine
    PopoverView.swift       — Usage cards, charts, countdown timers, refresh button, settings gear
    SettingsView.swift      — Poll interval, notification thresholds
Scripts/
  gen_icon.swift            — Icon generator
```

## Key Design Decisions

- **Keychain reads go through `/usr/bin/security`, deliberately.** The Claude Code CLI rewrites its item via security(1) on every token refresh, and macOS resets the item's partition list to the writer each time, revoking any "Always Allow" given to this app. `SecItemCopyMatching` therefore re-prompted every ~8h and after every rebuild. Reading via security(1), as the CLI itself does, never prompts and grants no access the item's ACL doesn't already allow. Don't switch back; see `tasks/lessons.md`.
- **Adaptive polling.** Poll interval adjusts based on utilization level: low=5m, medium=5m, high=3m, critical=2m. Configurable override in settings.
- **Color-coded per window.** Each usage window (5h, 7d) is colored independently by its own utilization level, both in the menu bar and in the popover cards.
- **Dark/light mode aware.** All accent colors have explicit dark and light variants.

## Auth Flow

1. User logs into Claude Code CLI (stores OAuth token in macOS keychain under service `"Claude Code-credentials"`)
2. App reads the item via `/usr/bin/security find-generic-password -w` (no prompt), then caches the token in memory
3. Token has `expiresAt` (unix ms) with 5-minute validity buffer; the app re-reads the item when the cached token nears expiry, or on a 401 (drop cache, re-read, retry once)
4. API requests use `Authorization: Bearer <token>` + `anthropic-beta: oauth-2025-04-20`

## API

- **Endpoint:** `GET https://api.anthropic.com/api/oauth/usage`
- **Response shape:** `{ five_hour: { utilization, resets_at }, seven_day: {...}, seven_day_opus: {...} }`
- **Error handling:** 401 → invalid credentials, 429 → rate limited (respects `Retry-After`); any other failure keeps the cached data and retries on the next tick

## Build & Run

```bash
# Build from command line
xcodebuild -project ClaudeUsage.xcodeproj -scheme ClaudeUsage -configuration Debug build

# Or open in Xcode
open ClaudeUsage.xcodeproj

# Unit tests (builds its own non-hardened copy; see Makefile)
make test
```

## Data Storage

| What | Where |
|------|-------|
| OAuth token | macOS system keychain (service: `Claude Code-credentials`) |
| Usage cache | `~/Library/Caches/<bundleID>/usage_cache.json` |
| Usage history | `~/Library/Caches/<bundleID>/usage_history.json` |
| Fetch / rate-limit log | `~/Library/Caches/<bundleID>/ratelimit_log.txt` |
| Launch / exit log | `~/Library/Caches/<bundleID>/lifecycle_log.txt` |
| Settings | `UserDefaults.standard` |
