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
   "Claude Code-credentials" -w` and parses `claudeAiOauth.accessToken` from its stdout. The
   path is absolute; no PATH lookup. The item's `expiresAt` is not read: the endpoint is the
   judge of expiry, and a skewed clock must not block a valid token.
2. The tool exits with the low byte of the Security framework's status. 44 (item not found)
   is `notFound`; 36 (interaction not allowed), 51 (authorization failed) and 128 (user
   cancelled) are `refused`; any other code is `failed`, with the code. A tool that cannot be
   launched is `launchFailed`, and an item without an access token is `malformed`. Each has
   its own message: sign in with Claude Code, unlock the keychain, the security tool failed,
   or the item's format is not recognised. Only a missing item tells the user to sign in.
3. The read is asynchronous and runs off the main actor. Its five-second deadline runs on its
   own clock, independent of the tool's output, so it fires even while the tool is blocked.
   At the deadline the tool is sent SIGTERM, then SIGKILL a second later if it is still
   running, and the read is reported as `timedOut`, shown like a refusal. A stuck Keychain
   dialog cannot hang the service or the menu.
4. Everything else in ADR-0001 stands: read-only, no refresh, one re-read on 401.
5. The `claude setup-token` fallback from the proposal is not built. Its only purpose was
   escaping the dialog, and this removes the dialog.
6. A failed read is logged once per refresh, with the failure and its exit code. The token
   and the tool's output are never logged: stdout is parsed in memory and dropped, and
   stderr is discarded.

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
- **Skip the request once the item's `expiresAt` has passed.** Trusts that the local clock
  agrees with the one that stamped the item, and a clock that is ahead blocks a valid token
  with no way past it. The endpoint's 401 gives the same answer without a clock. Rejected.
