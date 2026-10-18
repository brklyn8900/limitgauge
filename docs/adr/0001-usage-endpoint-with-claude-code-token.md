---
title: "ADR-0001: Read the account usage endpoint with Claude Code's Keychain token, read-only"
status: Accepted
date: 2026-10-18
---

# ADR-0001: Usage endpoint with Claude Code's token

**Status:** Accepted

## Context

The app needs the numbers on the claude.ai Usage page ([proposal](../proposal.md)): three
rate limits with reset times, two kinds of credits, and the weekly breakdown. Three sources
were available:

- The account usage endpoint (`/api/oauth/usage`, `/api/oauth/profile`), undocumented, which
  returns every field on the page.
- Claude Code's status line input, documented, which carries only the five-hour and weekly
  percentages and only while a Claude Code session is running.
- The rate-limit response headers Claude Code parses, which are not model-scoped.

Calling the endpoint needs an OAuth access token. Claude Code keeps one in the login Keychain
item `Claude Code-credentials`, next to a refresh token.

## Decision

1. Read usage and profile from the endpoint. Nothing else is a data source.
2. Authenticate with the access token from Claude Code's Keychain item, read through the
   Security framework.
3. Never refresh and never write. On 401, re-read the item once, then show the user a
   message to sign in with Claude Code.
4. Decode `limits[]` as the required part of the response and every other row as optional,
   so a renamed codename key hides a row rather than failing the fetch.

## Consequences

- Full coverage of the Usage page, including the model-scoped weekly limit and the credits,
  with one request per refresh plus a daily profile request for the plan tier.
- The app depends on an undocumented endpoint. A fixture test against a real response is the
  early warning when it changes.
- Signing in to Claude Code is the only sign-in. If Claude Code has been idle long enough for
  the access token to expire, the app is blind until Claude Code runs again. Accepted over
  the alternative of holding a refresh token of our own.
- One macOS Keychain consent dialog on first read, and possibly again after Claude Code
  recreates the item. The signature must be stable (ADR-0003).

## Alternatives considered

- **Status line feed, with endpoint polls for the rest.** Free per-turn updates for two
  limits, but stale writes from the script's non-turn invocations race the endpoint, and the
  merge rule adds state for a problem that fetch-on-open does not have. Rejected.
- **Refreshing Claude Code's token.** Rotating the refresh token from a second process risks
  logging Claude Code out. Rejected.
- **Browser cookies against claude.ai.** Reading them means decrypting the browser's Safe
  Storage key, which unlocks the entire cookie jar for every site, not just claude.ai. Far
  more exposure than one token for one endpoint. Rejected.
