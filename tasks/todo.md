# Stop the recurring keychain prompt — root cause (proven 2026-09-22)

Previous plan (direct reads, commit 50ee794) is in git history. Its premise, that
the CLI never touches the grant because the item is updated in place, was only
half right. The trusted-app list survives. The partition list does not.

## Root cause

Every "Always Allow" on `Claude Code-credentials` is revoked the next time the
Claude Code CLI writes that item, so no amount of caching or signing on our side
can make it stick.

1. The CLI (2.1.280) rewrites the item on every token refresh (~every 8h, plus
   extra writes) by piping `add-generic-password -U -a <user> -s "Claude Code-credentials" -X <hex>`
   into `/usr/bin/security -i`.
2. A data write re-encrypts the item into a new SSGroup. Apple's
   `ItemImpl::updateSSGroup` copies the old ACL but explicitly strips the
   partition + integrity entries ("We can't copy these over to the new item;
   they're going to be reset"), and securityd's `createClientPartitionID` then
   seeds the list with ONLY the writer's partition: `apple-tool:` for security(1).
3. Our read (`SecItemCopyMatching`) passes the trusted-app check (our DR is
   still listed) but fails the partition check, so securityd shows the
   "enter the login keychain password" XARA prompt.
4. The grant is keyed to `cdhash:<hash>` because the app is self-signed
   (no Apple-issued Team ID), so every rebuild also needs a fresh grant.

## Evidence

- `security dump-keychain -a`: trusted apps = [Claude Usage (DR), /usr/bin/security];
  partition list = `apple-tool:` only.
- securityd log (`/usr/bin/log show --predicate 'eventMessage CONTAINS "XARA partition"'`):
  - 09-21 18:37:35 CLI write → 18:37:53 our read prompts
  - 09-21 19:57:16 Always Allow → `adding XARA partition 'cdhash:02e063da…'`
  - 09-22 02:32:49 and 10:29:44 CLI writes (grant wiped)
  - 09-22 11:00:56 wake → our read prompts; 11:01:10 Always Allow
  - 09-22 11:01:25 CLI write (`SecKeychainItemModifyContent`, "no previous integrity
    acl exists; making a new one") → grant wiped 15 s after it was given
- Apple source: `OSX/libsecurity_keychain/lib/Item.cpp` (updateSSGroup),
  `securityd/src/acls.cpp` (createClientPartitionID), `securityd/src/clientid.cpp`
  (partitionIdForProcess: self-signed → `cdhash:`).

## Why the earlier fixes all failed

Each fix changed *when* we re-read the item, never *whether* a read after a CLI
write prompts: memory cache (09bb355), self-signed cert (stable DR, but the
partition is still cdhash-based), own refresh + own cache (668ebde, which also
fought the CLI's refresh-token rotation), direct reads (50ee794), watcher removal
(uncommitted).

## Options (A chosen 2026-09-22)

- **A (recommended):** read via `/usr/bin/security find-generic-password -w`, the
  same path the CLI uses. security(1) is the one reader whose partition every CLI
  write re-seeds, so there are zero prompts across refreshes, rebuilds and CLI
  updates. This reverses the documented "no shell-outs" rule. That rule protects
  nothing for this item, because any same-user process can already read it
  silently through security(1).
- **B:** keychain-free. Tee `rate_limits` from `~/.claude/statusline.sh` into a
  cache file the app reads. No token at all, but only fresh while a Claude Code
  session is running, and there is no 7-day Opus window.
- **C:** own OAuth session plus own keychain item. Largest change. Relies on
  Claude Code's client ID, which is unsupported. Still re-prompts once per
  rebuild unless the app is signed with an Apple-issued certificate.

## Plan (A)

- [x] `KeychainService.readItem`: runs `/usr/bin/security find-generic-password -s … -a <NSUserName()> -w`
      (argument array, no shell, 5 s watchdog; exit 44 → `.itemNotFound`, other
      exits → `.securityToolFailed`, a signal → `.timedOut`).
- [x] `decodeSecurityOutput`: handles security(1)'s hex form for non-printable values.
- [x] Rewrote the header in `KeychainService.swift`, the design decision in
      CLAUDE.md / AGENTS.md, and the README security table.
- [x] Tests: 7 new (4 decode, 3 real round-trips through security(1) in a throwaway keychain).
- [x] Housekeeping: deleted the stale `csmb.ClaudeUsage.cached-credentials` item;
      installed the fixed build to `/Applications` (the login item points there).

## Review

**Found along the way**
- `waitUntilExit()` spins the main run loop. Called from the main actor, it let
  XCTest start the tests *inside* a half-finished refresh, which deadlocked the
  test host. The code now waits on `terminationHandler` with a semaphore, and a
  regression test checks that no other main-run-loop work runs during a read.
- The unit tests had not run since the bundle rename (ef06310). `TEST_HOST`
  pointed at `ClaudeUsage.app`, the module is `Claude_Usage`, and library
  validation blocks the ad-hoc test bundle from loading into the hardened,
  team-less app. Fixed the first two. `make test` works around the third by
  building a separate non-hardened copy, so the app you run keeps Hardened Runtime.
- `Process` passes arguments in file-system representation (NFD). The test helper
  stores values with `-X <hex>` so fixtures are byte-exact.

**Verification**
- ✅ `make test`: 19/19 pass (the 12 older tests ran for the first time since the
  rename), no warnings.
- ✅ `make build`: succeeded with no warnings; signed "ClaudeUsage Signing" with Hardened Runtime.
- ✅ Live run from `/Applications` (new cdhash, partition list `apple-tool:` only,
  which is the exact state that always prompted before): no XARA/prompt events in
  securityd's log, `security` read at 12:48:21, API `status=200` at 12:48:22.
- ⏳ Not observable in-session: the next CLI token refresh (~6:30 PM) followed by
  the app's re-read. It is the same state as the live run above, so no prompt is expected.
- ⏭️ UI tests not run; XCUITest can raise an Automation permission prompt.

**Follow-ups (not done)**
- Old-code builds still on disk: DerivedData `Release/Claude Usage.app` and the
  iCloud `build/` folder. Harmless unless opened by hand.
