# Stop the recurring keychain prompt — Option A: direct reads

**Goal:** Eliminate the repeating "Claude Usage wants to access key Claude Code-credentials" prompt by making the app read Claude Code's keychain item directly (it's the source of truth and stays fresh) and relying on a one-time **Always Allow**. Remove the self-refresh + own-keychain-cache machinery that is actually *causing* the repeats.

## Corrected root cause (supersedes the previous plan)

The previous plan assumed *"Claude Code CLI **replaces** the keychain item on refresh, wiping the Always-Allow grant."* Evidence contradicts this:

- The `Claude Code-credentials` item's creation date is still **2026-05-22** while its modified date is today → it is **updated in place, not recreated**. Its ACL / Always-Allow grant is **not** wiped by the CLI.
- Our own cache item (`csmb.ClaudeUsage.cached-credentials`) had `cdat == mdat == 17:28:57Z`, i.e. it was **created from scratch 7s after the prompt** — which only happens after `deleteFromOwnKeychain()` ran. That delete fires on a rejected OAuth refresh (or a double-401).

**Actual cause:** the app and the Claude Code CLI **share one OAuth refresh-token lineage, and the server rotates the refresh token on every use.** The CLI rotates it out from under us; our cached refresh token dies; the next refresh is rejected; the app wipes its cache and falls back to a prompting re-read of the CLI keychain. The self-refresh machinery guarantees this loop instead of preventing it.

## Approach (chosen: A)

Read `Claude Code-credentials` directly, memory-cache the decoded token to avoid hammering the keychain, and re-read when it expires / on a 401 / when the CLI rotates it (watcher). No own-keychain cache, no OAuth refresh endpoint.

### Known tradeoff (flagged, accepted)
If neither the Claude Code CLI nor its background daemon refreshes the token for a long stretch, the keychain token can go stale and the app can't refresh it itself — it will show "token expired, log in again" until something refreshes it. In practice the `~/.claude/daemon/` keeps it fresh. This is the deliberate cost of dropping self-refresh.

## Plan

- [ ] **Delete** `Sources/Services/OAuthRefreshService.swift` and remove its 4 references from `ClaudeUsage.xcodeproj/project.pbxproj`.
- [ ] **Rewrite `KeychainService.loadCredentials()`** → sync (`throws`, not `async`): memory cache → read `Claude Code-credentials` → decode → memory-cache → return. Delete `cachedService`/`cachedAccount`, `loadPayloadFromOwnKeychain`, `saveToOwnKeychain`, `savePayloadToOwnKeychain`, `deleteFromOwnKeychain`, `performRefresh`, `inFlightRefresh`. Keep `readRawData`, `KeychainError`, `CredentialWatcher`.
- [ ] Collapse `invalidateCredentials()` and `invalidateMemoryCache()` into a single `invalidateMemoryCache()` (no own cache to delete anymore).
- [ ] **APIService**: revert `await` on the `loadCredentials()` call (line ~106); simplify the 401 branch to: drop memory cache → one retry → else `throw .invalidCredentials`; fix the stale comment.
- [ ] **Credentials.swift**: revert `isValid` buffer 1800 → 300s and fix the comment (the "refresh well before expiry" rationale no longer applies; a wide buffer would wrongly reject still-valid tokens).
- [ ] **AppDelegate**: in the `CredentialWatcher` closure, call `KeychainService.invalidateMemoryCache()` before `appState.refresh()` so a CLI rotation is picked up promptly. (Keep the WIP `~/.claude` watch-path fix.)
- [ ] **Verify**: `xcodebuild build` compiles; `xcodebuild test` passes (the `decode_preservesRefreshToken` test still holds); run the app, confirm one **Always Allow** grant and a successful usage fetch, then confirm subsequent polls don't reprompt within the session.

## Verification boundary
I can prove: builds, tests pass, app fetches usage with a single grant, no reprompt on subsequent polls this session. I cannot fully prove "no reprompt across CLI token rotation over hours" in one session — that requires observing over time. I'll state this honestly rather than overclaim.

## Review

**Done (WIP stashed as `stash@{0}` first).**

- Deleted `Sources/Services/OAuthRefreshService.swift` + its 4 refs in `project.pbxproj` (`plutil -lint` OK).
- `KeychainService`: now memory-cache → direct read of `Claude Code-credentials`. Removed own-keychain cache, OAuth refresh, and all helpers; kept `readRawData`, `KeychainError`, `CredentialWatcher`. Folded in the `~/.claude` watcher-path fix (the committed watcher pointed at `~/.config/claude`, which does **not** exist on this machine → the watcher was dead).
- `APIService`: 401 branch now drops memory cache + retries once, else surfaces re-auth (removed the own-cache wipe).
- `AppDelegate`: watcher closure invalidates the memory cache before refreshing, so a CLI rotation is picked up. Safe against event storms because `AppState.refresh()` is gated by `canRefresh` (cooldown + rate-limit).
- `Credentials.swift`: untouched — committed buffer was already 300s (the 1800s value was only in the stashed WIP).

**Verification**
- ✅ `xcodebuild build` → **BUILD SUCCEEDED** (also pruned stale `OAuthRefreshService.o`).
- ✅ `xcodebuild test` → **TEST SUCCEEDED** (UI tests launch the app, so it runs with these changes).
- ⚠️ `decode_preservesRefreshToken` unit test is **not in the scheme's test plan** (pre-existing gap) so it doesn't run in the normal cycle. It only exercises the untouched `Credentials.swift`, so it's unaffected. Worth wiring into the test plan later.
- ⏳ "No reprompt across CLI token rotation over hours": can't be proven in-session. Requires installing the new build to `/Applications`, granting **Always Allow** once, and watching over time. The stable app signature + in-place-updated (not recreated) keychain item mean the grant should persist.

**Two findings surfaced along the way**
1. Commit 668ebde's root-cause premise ("CLI *replaces* the keychain item, wiping the grant") is contradicted by the item's preserved creation date — it's updated in place.
2. The `CredentialWatcher` was watching a non-existent directory (`~/.config/claude`), so it never fired. Now fixed.

**Follow-ups (not done, out of scope unless asked)**
- Add `ClaudeUsageTests` to the scheme's test plan so the unit test actually runs.
- Install the rebuilt app to `/Applications` (replaces the May-2 build) and grant Always Allow once.
- Drop `stash@{0}` once satisfied.
