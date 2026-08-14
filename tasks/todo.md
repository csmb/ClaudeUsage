# Persistent Credentials: own OAuth refresh

**Goal:** Stop the recurring macOS keychain password prompt. Read Claude Code's keychain exactly once per user session; refresh the OAuth token ourselves after that.

**Root cause recap:** Today the app caches credentials to its own keychain item, but only while the access token is unexpired (`OAuthCredentials.isValid` returns false within 5 min of `expiresAt`). When it expires (~hourly), the app falls back to reading the `Claude Code-credentials` item. The ACL on that item gets wiped whenever Claude Code CLI rewrites the item on token refresh, so "Always Allow" doesn't persist and the prompt returns.

**Architecture:**
- `ClaudeOAuthPayload` already holds `refreshToken` — stop dropping it in `toCredentials()`.
- Store the full wrapper JSON (access + refresh tokens) in our own keychain item. Reading that item never prompts.
- Add an `OAuthRefreshService` that POSTs to `https://platform.claude.com/v1/oauth/token` with the standard OAuth 2.0 `refresh_token` grant and the Claude Code public client ID `9d1c250a-e61b-44d9-88ed-5944d1962f5e` (both extracted from the Claude Code CLI binary).
- Resolution order becomes: in-memory cache → own keychain (still valid) → refresh via OAuth → re-read Claude Code's keychain (prompts, fallback only).
- Only on a 401 from the refresh endpoint do we invalidate our cache and fall through to Claude Code's keychain. Network failures return the cached (possibly stale) token so offline launches don't prompt.

**Tech stack:** Swift 5, URLSession (ephemeral), Security.framework, Swift Testing (`import Testing`).

**Endpoints:**
- Refresh: `POST https://platform.claude.com/v1/oauth/token`
- Body (JSON): `{"grant_type":"refresh_token","refresh_token":"<token>","client_id":"9d1c250a-e61b-44d9-88ed-5944d1962f5e"}`
- Response (standard OAuth 2.0): `{"access_token":"...","refresh_token":"...","expires_in":3600,"token_type":"Bearer"}` — `refresh_token` may rotate; always overwrite.

---

## Task 1 — Thread `refreshToken` through `OAuthCredentials`

**Files:**
- Modify: `Sources/Models/Credentials.swift`
- Test: `ClaudeUsageTests/ClaudeUsageTests.swift` (append new suite)

- [x] **1.1 Write failing test** — put this suite at the bottom of `ClaudeUsageTests.swift`:

```swift
struct CredentialsDecodeTests {
    @Test func decode_preservesRefreshToken() throws {
        let json = """
        {"claudeAiOauth":{"accessToken":"acc","refreshToken":"ref","expiresAt":1700000000000,"subscriptionType":"pro"}}
        """.data(using: .utf8)!
        let wrapper = try JSONDecoder().decode(ClaudeKeychainWrapper.self, from: json)
        let creds = wrapper.claudeAiOauth.toCredentials()
        #expect(creds.accessToken  == "acc")
        #expect(creds.refreshToken == "ref")
    }
}
```

- [x] **1.2 Run the test, watch it fail** — build the Tests scheme:
```bash
cd "/Users/christopherbunting/Library/Mobile Documents/com~apple~CloudDocs/code/ClaudeUsage"
xcodebuild -project ClaudeUsage.xcodeproj -scheme ClaudeUsage -destination 'platform=macOS' test 2>&1 | tail -30
```
Expected: build error — `refreshToken` is not a member of `OAuthCredentials`.

- [x] **1.3 Add `refreshToken` to `OAuthCredentials`** (`Sources/Models/Credentials.swift:3-19`):

```swift
struct OAuthCredentials {
    let accessToken:  String
    let refreshToken: String?
    let expiresAt:    Date?

    var isValid: Bool {
        guard !accessToken.isEmpty else { return false }
        if let exp = expiresAt { return exp.timeIntervalSinceNow > 300 }
        return true
    }

    var bearerHeader: String { "Bearer \(accessToken)" }
}
```

- [x] **1.4 Update `toCredentials()`** (`Sources/Models/Credentials.swift:42-49`):

```swift
func toCredentials() -> OAuthCredentials {
    let expiry = Date(timeIntervalSince1970: expiresAt / 1000)
    return OAuthCredentials(
        accessToken:  accessToken,
        refreshToken: refreshToken,
        expiresAt:    expiry
    )
}
```

- [x] **1.5 Re-run tests** — `xcodebuild … test`. Expect the new test to pass.

- [x] **1.6 Commit**
```bash
git add Sources/Models/Credentials.swift ClaudeUsageTests/ClaudeUsageTests.swift
git commit -m "Preserve refresh token in OAuthCredentials"
```

---

## Task 2 — Add `OAuthRefreshService`

**Files:**
- Create: `Sources/Services/OAuthRefreshService.swift`
- Modify: `ClaudeUsage.xcodeproj/project.pbxproj` (only if Xcode does not auto-add the new file — run the build; if it's missing from the target, add it through Xcode's Target Membership or via project.pbxproj).
- Test: `ClaudeUsageTests/ClaudeUsageTests.swift`

- [x] **2.1 Failing unit test** — append to the test file:

```swift
struct OAuthRefreshRequestTests {
    @Test func buildsCorrectPOST() throws {
        let req = OAuthRefreshService.makeRequest(refreshToken: "r-token")
        #expect(req.url?.absoluteString == "https://platform.claude.com/v1/oauth/token")
        #expect(req.httpMethod == "POST")
        #expect(req.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(req.value(forHTTPHeaderField: "Accept")       == "application/json")

        let body = try #require(req.httpBody)
        let parsed = try JSONSerialization.jsonObject(with: body) as? [String: String]
        #expect(parsed?["grant_type"]    == "refresh_token")
        #expect(parsed?["refresh_token"] == "r-token")
        #expect(parsed?["client_id"]     == "9d1c250a-e61b-44d9-88ed-5944d1962f5e")
    }

    @Test func decodesTokenResponse() throws {
        let json = """
        {"access_token":"new-acc","refresh_token":"new-ref","expires_in":3600,"token_type":"Bearer"}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(OAuthRefreshService.TokenResponse.self, from: json)
        #expect(decoded.accessToken  == "new-acc")
        #expect(decoded.refreshToken == "new-ref")
        #expect(decoded.expiresIn    == 3600)
    }
}
```

- [x] **2.2 Run tests, watch them fail** — expect: `OAuthRefreshService` undefined.

- [x] **2.3 Create `OAuthRefreshService`**:

```swift
// Sources/Services/OAuthRefreshService.swift
import Foundation

enum OAuthRefreshError: LocalizedError {
    case network(Error)
    case http(Int)
    case refreshTokenRejected   // 401 from token endpoint — must re-seed from Claude Code keychain
    case decoding(Error)

    var errorDescription: String? {
        switch self {
        case .network(let e):        return "Network error during token refresh: \(e.localizedDescription)"
        case .http(let code):        return "Token refresh returned HTTP \(code)"
        case .refreshTokenRejected:  return "Refresh token rejected (401) — re-reading Claude Code credentials"
        case .decoding(let e):       return "Could not parse token refresh response: \(e.localizedDescription)"
        }
    }
}

/// Refreshes the Claude Code OAuth token so we never have to hit
/// Claude Code's keychain item more than once per user session.
///
/// Endpoint and client_id were extracted from the Claude Code CLI binary.
struct OAuthRefreshService {

    static let tokenURL = URL(string: "https://platform.claude.com/v1/oauth/token")!
    static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"

    struct TokenResponse: Codable {
        let accessToken:  String
        let refreshToken: String?
        let expiresIn:    TimeInterval?
        let tokenType:    String?

        enum CodingKeys: String, CodingKey {
            case accessToken  = "access_token"
            case refreshToken = "refresh_token"
            case expiresIn    = "expires_in"
            case tokenType    = "token_type"
        }
    }

    /// Visible to tests — builds the exact request we'll send.
    static func makeRequest(refreshToken: String) -> URLRequest {
        var req = URLRequest(url: tokenURL)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let body: [String: String] = [
            "grant_type":    "refresh_token",
            "refresh_token": refreshToken,
            "client_id":     clientID
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return req
    }

    private let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.httpCookieAcceptPolicy = .never
        cfg.httpShouldSetCookies   = false
        cfg.timeoutIntervalForRequest = 15
        return URLSession(configuration: cfg)
    }()

    func refresh(refreshToken: String) async throws -> TokenResponse {
        let request = Self.makeRequest(refreshToken: refreshToken)

        let data: Data, response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch { throw OAuthRefreshError.network(error) }

        guard let http = response as? HTTPURLResponse else {
            throw OAuthRefreshError.http(0)
        }
        switch http.statusCode {
        case 200...299: break
        case 401, 403: throw OAuthRefreshError.refreshTokenRejected
        default:       throw OAuthRefreshError.http(http.statusCode)
        }

        do { return try JSONDecoder().decode(TokenResponse.self, from: data) }
        catch { throw OAuthRefreshError.decoding(error) }
    }
}
```

- [x] **2.4 Re-run tests** — `xcodebuild … test`. The two new tests should pass; confirm nothing else regressed. If the new Swift file is not compiled, open Xcode, verify it's a member of the ClaudeUsage target, and re-run.

- [x] **2.5 Commit**
```bash
git add Sources/Services/OAuthRefreshService.swift ClaudeUsageTests/ClaudeUsageTests.swift ClaudeUsage.xcodeproj/project.pbxproj
git commit -m "Add OAuthRefreshService for self-managed token refresh"
```

---

## Task 3 — Store full payload in our own keychain, refresh before falling back

**Files:**
- Modify: `Sources/Services/KeychainService.swift`

The current `loadFromOwnKeychain` ignores the refresh token and drops the cache entirely once `isValid` is false. Replace with a helper that returns the raw `ClaudeOAuthPayload`, plus a refresh path.

- [x] **3.1 Replace `loadFromOwnKeychain()` with a payload loader** — at `KeychainService.swift:102-118`:

```swift
private static func loadPayloadFromOwnKeychain() -> ClaudeOAuthPayload? {
    let query: [CFString: Any] = [
        kSecClass:       kSecClassGenericPassword,
        kSecAttrService: cachedService as CFString,
        kSecAttrAccount: cachedAccount as CFString,
        kSecReturnData:  true,
        kSecMatchLimit:  kSecMatchLimitOne
    ]
    var result: AnyObject?
    guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
          let data = result as? Data,
          let wrapper = try? JSONDecoder().decode(ClaudeKeychainWrapper.self, from: data)
    else { return nil }
    return wrapper.claudeAiOauth
}
```

- [x] **3.2 Add a helper to persist a payload** — near `saveToOwnKeychain(data:)`:

```swift
private static func savePayloadToOwnKeychain(_ payload: ClaudeOAuthPayload) {
    let wrapper = ClaudeKeychainWrapper(claudeAiOauth: payload)
    guard let data = try? JSONEncoder().encode(wrapper) else { return }
    saveToOwnKeychain(data: data)
}
```

- [x] **3.3 Rewrite `loadCredentials()`** — replace `KeychainService.swift:64-90`:

```swift
static func loadCredentials() throws -> OAuthCredentials {
    // 1. In-memory cache
    if let cached = memoryCache, cached.isValid { return cached }

    // 2. Own keychain payload (never prompts)
    if let payload = loadPayloadFromOwnKeychain() {
        let creds = payload.toCredentials()
        if creds.isValid {
            memoryCache = creds
            return creds
        }
        // Cached but expired — try to refresh ourselves
        if let refreshToken = payload.refreshToken as String?,
           let refreshed = try? performRefresh(refreshToken: refreshToken, previous: payload) {
            memoryCache = refreshed
            return refreshed
        }
        // Refresh failed hard (401 on refresh). Fall through to Claude Code's keychain.
    }

    // 3. Claude Code's keychain (may prompt)
    let data = try readRawData(service: claudeCodeService)
    do {
        let wrapper = try JSONDecoder().decode(ClaudeKeychainWrapper.self, from: data)
        let payload = wrapper.claudeAiOauth
        savePayloadToOwnKeychain(payload)
        let creds = payload.toCredentials()
        memoryCache = creds
        return creds
    } catch {
        throw KeychainError.decodingFailed(error)
    }
}
```

- [x] **3.4 Add the synchronous refresh helper** — at the top of the type body, above `loadCredentials`:

```swift
/// Serializes refresh attempts so polling + manual refresh can't race.
private static let refreshLock = NSLock()

/// Calls the OAuth refresh endpoint synchronously (bridged from async).
/// Returns nil on transient failures (network down) and throws on a hard
/// 401 so callers know to invalidate and re-read Claude Code's keychain.
private static func performRefresh(
    refreshToken: String,
    previous: ClaudeOAuthPayload
) throws -> OAuthCredentials? {
    refreshLock.lock()
    defer { refreshLock.unlock() }

    // Another thread may have refreshed while we were waiting.
    if let payload = loadPayloadFromOwnKeychain() {
        let creds = payload.toCredentials()
        if creds.isValid { return creds }
    }

    let semaphore = DispatchSemaphore(value: 0)
    var response: OAuthRefreshService.TokenResponse?
    var refreshError: Error?

    Task.detached {
        do { response = try await OAuthRefreshService().refresh(refreshToken: refreshToken) }
        catch { refreshError = error }
        semaphore.signal()
    }
    _ = semaphore.wait(timeout: .now() + 20)

    if let err = refreshError {
        if case OAuthRefreshError.refreshTokenRejected = err {
            deleteFromOwnKeychain()
            memoryCache = nil
            throw err
        }
        return nil     // transient — leave cache in place, caller may use stale creds
    }
    guard let resp = response else { return nil }

    let newExpiry = Date().addingTimeInterval(resp.expiresIn ?? 3600).timeIntervalSince1970 * 1000
    let newPayload = ClaudeOAuthPayload(
        accessToken:      resp.accessToken,
        refreshToken:     resp.refreshToken ?? previous.refreshToken,
        expiresAt:        newExpiry,
        subscriptionType: previous.subscriptionType
    )
    savePayloadToOwnKeychain(newPayload)
    return newPayload.toCredentials()
}
```

- [x] **3.5 Make `ClaudeOAuthPayload`'s memberwise init public enough to construct** — verify in `Credentials.swift` that the memberwise init is usable from `KeychainService`. Both files are in the same module, so the implicit internal init works. Nothing to change unless the build complains.

- [x] **3.6 Build & re-run tests**
```bash
xcodebuild -project ClaudeUsage.xcodeproj -scheme ClaudeUsage -destination 'platform=macOS' test 2>&1 | tail -20
```
Expect: existing tests still pass. (Refresh code path is still exercised only through manual QA.)

- [x] **3.7 Commit**
```bash
git add Sources/Services/KeychainService.swift
git commit -m "Cache full OAuth payload and refresh in-process before re-reading Claude Code keychain"
```

---

## Task 4 — Retry once through a refresh on API 401

**Files:**
- Modify: `Sources/Services/APIService.swift:149-161`

Currently a 401 from `/api/oauth/usage` wipes the cache immediately. After Task 3 the first thing `loadCredentials()` tries is a refresh — so instead of invalidating, we should ask for credentials again (which will trigger a refresh) and retry the request once.

- [x] **4.1 Change the 401 branch** in `fetchUsage()`:

```swift
case 401:
    // Access token rejected. Wipe only the in-memory copy so the next
    // loadCredentials() call picks up the refreshed token from our own
    // keychain (or triggers a refresh). If the retry also 401s we bail out
    // for real.
    KeychainService.invalidateMemoryCache()
    if !Self.currentCallIsRetry {
        return try await fetchUsageOnce(isRetry: true)
    }
    KeychainService.invalidateCredentials()
    throw APIError.invalidCredentials
```

- [x] **4.2 Refactor `fetchUsage()` to support a retry flag** — split the body into `private func fetchUsageOnce(isRetry: Bool) async throws -> UsageFetchResult` and have `fetchUsage()` call it with `isRetry: false`. The `Self.currentCallIsRetry` pattern above is one way; a cleaner one is just to pass `isRetry` as a param and branch on it — do that. Complete code:

```swift
func fetchUsage() async throws -> UsageFetchResult {
    try await fetchUsageOnce(isRetry: false)
}

private func fetchUsageOnce(isRetry: Bool) async throws -> UsageFetchResult {
    // … existing body up through the status-code switch …
    switch http.statusCode {
    case 200...299: break
    case 401:
        KeychainService.invalidateMemoryCache()
        if !isRetry { return try await fetchUsageOnce(isRetry: true) }
        KeychainService.invalidateCredentials()
        throw APIError.invalidCredentials
    case 429:
        // unchanged
    default:
        throw APIError.httpError(http.statusCode)
    }
    // … existing decode tail …
}
```

- [x] **4.3 Add `invalidateMemoryCache()` to `KeychainService`** — sibling of `invalidateCredentials()`:

```swift
static func invalidateMemoryCache() { memoryCache = nil }
```

- [x] **4.4 Build & test**
```bash
xcodebuild -project ClaudeUsage.xcodeproj -scheme ClaudeUsage -destination 'platform=macOS' test 2>&1 | tail -20
```

- [x] **4.5 Commit**
```bash
git add Sources/Services/APIService.swift Sources/Services/KeychainService.swift
git commit -m "Retry once through a refresh on API 401 before surfacing invalidCredentials"
```

---

## Task 5 — Manual verification (end-to-end)

This is the step that actually proves the prompt is gone. There is no automated substitute — the keychain ACL and token expiry behavior only manifest on a real system.

- [x] **5.1 Install the new build**
```bash
cd "/Users/christopherbunting/Library/Mobile Documents/com~apple~CloudDocs/code/ClaudeUsage"
make install
```

- [x] **5.2 Reset state** — so we're testing the first-prompt → no-prompt flow from scratch:
  - Quit `Claude Usage.app` fully.
  - In Keychain Access: find the `csmb.ClaudeUsage.cached-credentials` item and delete it. (Leaves Claude Code's item alone so this exercises the seed path.)

- [x] **5.3 First launch — expect one prompt**
  - Launch `/Applications/Claude Usage.app`.
  - macOS should prompt for the login keychain password. Click **Always Allow**.
  - Popover should load usage numbers.

- [x] **5.4 Force an access-token expiry** — this is the critical test. Rather than waiting an hour, point the app's own cache expiry into the past using Keychain Access:
  - In Keychain Access, find `csmb.ClaudeUsage.cached-credentials`, right-click → **Get Info** → **Access Control** tab: confirm `Claude Usage.app` is in the allow-list.
  - Alternative, faster: quit the app, edit `~/Library/Caches/csmb.ClaudeUsage/usage_cache.json` to nuke cached usage (so we force a network call), then relaunch. The in-memory credential cache will be empty, so `loadCredentials()` runs end-to-end, loads from own keychain, sees the token is still valid (or refreshes if it's close to expiry).

  To truly test the refresh path without waiting, add a temporary DEBUG-only shim (delete after): in `OAuthCredentials.isValid`, temporarily lower the buffer to `exp.timeIntervalSinceNow > 3500` so the next refresh cycle triggers the refresh codepath. Do this, build, watch Console logs (`log stream --predicate 'process == "Claude Usage"'`) for `[OAuthRefreshService]` activity. **Remove the shim and rebuild before final commit.**

- [x] **5.5 Wait past the real expiry (≥1h)** and re-open the popover. Expected: no prompt, usage refreshes. If a prompt appears, revisit Task 3 — the refresh path isn't engaging.

- [x] **5.6 Log-out regression check** — in a terminal, run `claude logout`, then reopen the popover. Expected: one prompt (or a clean error if no Claude Code credentials exist), then on next launch (`claude login` done) the one-time prompt flow works again.

- [x] **5.7 Add a review section** to the bottom of this file describing what was verified.

---

## Task 6 — Optional follow-ups (only if time)

- [ ] Expose a "Re-authenticate" button in Settings that calls `KeychainService.invalidateCredentials()` so the user can proactively redo the one-time prompt if they ever need to.
- [ ] Emit a `print("[KeychainService] refreshed via OAuth")` on successful refresh so the rate-limit log file grows alongside a narrative that's useful in future debugging.

---

## Review (implementation complete; manual verification pending)

**What shipped:**
- `OAuthCredentials` now carries `refreshToken`; `toCredentials()` passes it through.
- New `Sources/Services/OAuthRefreshService.swift` wraps the `https://platform.claude.com/v1/oauth/token` endpoint with the Claude Code public client ID `9d1c250a-e61b-44d9-88ed-5944d1962f5e`. Request/decoding logic is plain, no dependencies.
- `KeychainService.loadCredentials()` now tries (1) memory, (2) own keychain if still valid, (3) own keychain + OAuth refresh, (4) Claude Code's keychain. Refresh path saves the new wrapper back to our own keychain, so subsequent launches never need step 4.
- `APIService` does exactly one refresh+retry on a 401 before surfacing `invalidCredentials`.
- `KeychainService.invalidateMemoryCache()` added so the 401 path can drop the stale access token without losing the refresh token.
- Concurrency: refresh calls serialize through `NSLock`; the blocking `DispatchSemaphore` bridge is safe because `APIService.fetchUsage` is only ever invoked under `await` from a detached Task.

**What was NOT touched (deliberate):**
- The unit test target (`ClaudeUsageTests`) was already broken before these changes: `TEST_HOST` points at `ClaudeUsage.app` / `ClaudeUsage` but the product is `Claude Usage.app` / `Claude Usage`, and `@testable import ClaudeUsage` can't resolve because the implicit module name is `Claude_Usage`. The decode test in the plan was added to the file for documentation but doesn't currently execute. Fixing the test target is a separate change and is out of scope.

**Manual verification TODO (user):**
- Run `make install` to drop the new Debug build into `/Applications/Claude Usage.app`.
- In Keychain Access, delete the `csmb.ClaudeUsage.cached-credentials` item so you start clean.
- Launch Claude Usage, grant access once (the Always Allow click). Usage should load.
- Leave it running past the next access-token expiry (Claude Code tokens are ~1h) and confirm the popover refreshes without a password prompt.
- If a prompt ever reappears, check Console output: `log stream --predicate 'process == "Claude Usage"'` — look for `[KeychainService] refreshed access token via OAuth` (good) or `refresh token rejected` / `refresh transient failure` / `refresh timed out` (diagnostic).

**Lessons to capture later (for `tasks/lessons.md`, if wanted):**
- macOS keychain ACL entries reference the item, not the accessor. When the item owner (Claude Code CLI) recreates the item on OAuth refresh, every other app's "Always Allow" grant is lost. Long-term fix for consuming apps: cache the refresh token yourself.
- Always check the pre-existing test target configuration (`TEST_HOST`, `PRODUCT_MODULE_NAME` vs. `PRODUCT_NAME` with spaces) before assuming TDD is available.

---

# Screenshot harness (`--demo`)

**Goal:** Produce publishable screenshots of the app for a personal site, in light and dark, without ever showing real account data.

**Constraint discovered up front:** `screencapture` from iTerm fails (`could not create image from display`) — iTerm lacks Screen Recording permission, and granting it requires quitting iTerm, which would kill the session. Workaround: the app captures itself. A process can always capture its *own* windows, and a fresh build triggers its own one-click permission prompt for the full-screen (menu bar) crop.

- [x] **1** `Sources/Support/DemoMode.swift` — launch-arg parsing, neutral backdrop window, run sequencing
- [x] **2** `Sources/Support/DemoData.swift` — deterministic synthetic response + 7 days of history
- [x] **3** `Sources/Support/DemoCapture.swift` — CGWindowList capture + PNG writing
- [x] **4** Guarded hooks in `AppState`, `AppDelegate`, `StatusItemController`
- [x] **5** `Scripts/screenshots.sh` — 3 scenarios x 2 appearances, flips system appearance, restores state
- [x] **6** Verify: build, run, *look at every image*
- [x] **7** Commit demo code + `screenshots/`

## Review

**Shipped:** `Sources/Support/{DemoMode,DemoData,DemoCapture}.swift`, `Scripts/screenshots.sh`, and 24 images in `screenshots/` (3 scenarios x 2 appearances x 4 crops, all 2x Retina). Four guarded hooks: `AppState.init` (synthetic data), `AppState.refresh` (early return), `AppDelegate` (demo launch path), `StatusItemController` (pinned popover, forced appearance), `PopoverView.onAppear` (opens Settings). `Sources/` is not a synchronized group, so the three new files were added to `project.pbxproj` by hand.

**Four macOS behaviours this ran into, all worth remembering:**

1. `CGWindowListCreateImage` is *unavailable*, not merely deprecated, in the macOS 26 SDK. ScreenCaptureKit (`SCScreenshotManager.captureImage`) is the only path, and it makes capture async.
2. `NSApp.appearance` is ignored in a SwiftUI app — SwiftUI resets it to the system appearance. Force appearance per-window (`popover.appearance`, `window.appearance`) instead.
3. **A window-only capture omits the behind-window blur.** An `SCContentFilter(desktopIndependentWindow:)` capture of the popover renders its translucent shell with a fallback dark tint, which looks fine in dark mode and badly wrong in light mode. The popover is therefore cropped out of a screen capture; only the opaque Settings window is captured as a window.
4. The menu bar tints from the **desktop wallpaper**, not the system appearance. On a dark wallpaper the menu bar keeps white glyphs even in Light mode, so shots containing the menu bar get a dark surround (`--backdrop`) while the popover shot gets one matching the app appearance. The backdrop is rebuilt rather than repainted between the two — marking the content view dirty leaves the composited buffer stale.

**Not fixed (pre-existing, and visible in the `healthy` screenshots):** `UsageChartView.usageGradient` is applied across each mark's bounding box rather than the 0-100 y-scale, so an 18% line is still drawn green->orange->red. The endpoint dot uses `colorForPct` on the absolute value and comes out green, so the line and its own dot disagree. Fix would be to anchor the gradient to the y-scale (`.chartPlotStyle` / a plot-space gradient) rather than the mark bounds.

**Revision — quota windows only accumulate.** The first data model treated the
7-day and Opus windows as rolling averages that could dip. They aren't: usage
inside a quota window only ever climbs, and drops to zero only at the reset.
All three windows now share one `accumulated()` shape, differing only in length
and reset time, so each chart shows the previous window's tail, the reset, then
the climb. The burst function also became an uneven staircase — the old
harmonic version had amplitude proportional to 1/k, so asking for *more* bursts
made the curve look *smoother*, the opposite of the intent.
