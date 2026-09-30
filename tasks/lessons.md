# Lessons

## Crashes: read the .ips reports, then measure the graph, one variable at a time

The app "quit" six times over a week. Every one was the same SwiftUI abort
(`AG::data::table::grow_region` precondition failure) after 13–37 hours: memory
growth, not a quit. The lifecycle log can't see an `abort()`; it only notes the
missing exit on the next launch.

- Crash reports live in `~/Library/Logs/DiagnosticReports/` (older ones in
  `Retired/`); match their pid and launch time to lifecycle_log.txt.
  `/Library/Logs/DiagnosticReports/JetsamEvent-*.ips` gives the memory size.
- SwiftUI graph growth shows up in `vmmap --summary <pid>` as the
  `AttributeGraph_0x…` malloc zone's allocation count. The Debug build has
  `get-task-allow`, so vmmap and footprint work without sudo.
- The popover's content isn't built until it is first shown. Every run has to
  follow the same protocol (launch, open once via System Events, then sample),
  or a fresh never-opened run looks "fixed".
- `open App.app` activates an app that's already running instead of launching
  a new one. Check the pid's start time before trusting a measurement.

**Rule:** anything the popover's once-a-second redraw passes to Swift Charts as
an axis value or an identity must not change with the clock. Charts keeps the
views for every axis value it has shown.

## Keychain prompts: inspect the partition list and securityd logs before theorizing

Five or six fixes for the repeating keychain prompt failed because each one was
built on an inferred cause (read frequency, signing, item recreation, refresh
tokens). None of them looked at the state that actually decides the prompt.

- The decisive state is the item's **partition list**, not only its trusted-app
  list. Read it with `security dump-keychain -a ~/Library/Keychains/login.keychain-db`
  (no secrets without `-d`) and look at the `partition_id` entry.
- securityd logs every decision. Run
  `/usr/bin/log show --info --predicate 'eventMessage CONTAINS "XARA partition"'`
  (the zsh builtin `log` shadows the system tool, so use the full path) together with
  `process == "security" AND eventMessage CONTAINS "integrity acl"` to see each write.
- `cdat`/`mdat` say nothing about ACL or partition changes. "Updated in place" does
  not mean "grant preserved".
- A data write to a legacy keychain item re-seeds its partition list with the
  writer's partition only. An app that reads an item some other tool rewrites will
  always be re-prompted after each rewrite.
- `security create-keychain` makes legacy v256 keychains with no partition support,
  so it cannot reproduce partition behaviour.

**Rule:** for any "keychain keeps prompting" report, capture the ACL dump and the
securityd XARA log lines first, and name the exact event that removes the grant
before proposing a fix.
