---
title: "ADR-0004: Read Claude Code's Keychain item through /usr/bin/security"
status: Accepted
date: 2026-10-18
---

# ADR-0004: Read the credentials item through the security tool

**Status:** Accepted. Supersedes point 2 of [ADR-0001](0001-usage-endpoint-with-claude-code-token.md).

## Context

ADR-0001 reads `Claude Code-credentials` through the Security framework. That raises the
macOS consent dialog, and the Always Allow grant does not last: Claude Code recreates the
item on every token refresh, which rewrites its access list, and the dialog comes back,
asking for the login password each time. ADR-0003's stable signature does not help, because
the grant is lost on the item's side, not ours.

Claude Code itself never calls the Security framework. It stores the item with
`security add-generic-password` and reads it with `security find-generic-password -w`
(confirmed in the 2.1.302 binary). The item's access list therefore trusts
`/usr/bin/security`, and a read through that tool returns without a dialog, including right
after a refresh. Verified on this machine: exit 0 in 25 ms, no prompt.

## Decision

1. `ClaudeCodeCredentials.read()` runs `/usr/bin/security find-generic-password -s
   "Claude Code-credentials" -w` and parses its stdout. The path is absolute; no PATH lookup.
2. Exit codes map onto the existing errors: 44 is `notFound`; 36 (interaction not allowed)
   and 128 (user cancelled) are `accessDenied`; anything else carries the exit code.
3. The read is asynchronous and runs off the main actor. Its five-second deadline runs on its
   own clock, independent of the tool's output, so it fires even while the tool is blocked.
   At the deadline the tool is sent SIGTERM, then SIGKILL a second later if it is still
   running, and the read is reported as `timedOut`, shown like a refusal. A stuck Keychain
   dialog cannot hang the service or the menu.
4. Everything else in ADR-0001 stands: read-only, no refresh, one re-read on 401.
5. The `claude setup-token` fallback from the proposal is not built. Its only purpose was
   escaping the dialog, and this removes the dialog.

## Consequences

- No consent dialog, on first run or after refreshes. No second credential anywhere.
- Exposure is unchanged: any process running as the user could already run the same
  command without a prompt. The token crosses a private pipe and stays in memory.
- The app depends on the `security` tool's command-line behaviour and exit codes, which
  have been stable for many macOS releases, and on Claude Code continuing to store the item
  through the same tool. If Claude Code moves to the framework, the dialog returns and the
  setup-token fallback becomes relevant again.
- The Keychain ACL no longer depends on the signing identity, so ADR-0003's stable
  signature matters only for notifications and launch-at-login.

## Alternatives considered

- **Keep the framework read and add a `claude setup-token` fallback** (proposal). Adds a
  Settings field, a second Keychain item, and a token the user must mint and renew, to
  work around a dialog that the tool read does not raise. Rejected.
- **Browser cookies or an OAuth flow of our own.** Rejected in ADR-0001 for exposure and
  refresh-conflict reasons; nothing changed.
