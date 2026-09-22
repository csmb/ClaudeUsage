# Lessons

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
