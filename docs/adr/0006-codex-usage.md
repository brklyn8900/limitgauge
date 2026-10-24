---
title: "ADR-0006: Read Codex limits through its local app server"
status: Implemented locally; human acceptance pending
date: 2026-10-23
---

# ADR-0006: Codex usage through the existing sign-in

## Context

The same menu should show Codex subscription limits without another login, pasted token,
status-line hook, or estimated token-to-quota conversion. Codex exposes the actual account
limits through its documented `account/rateLimits/read` app-server method.

## Decision

1. Start a short-lived local `codex app-server --stdio` when a fetch is due. Complete the
   initialize/initialized handshake and read account limits. Never create a thread or turn,
   initiate login/logout, or redeem credits. LimitGauge never reads or stores Codex credentials.
2. Keep authentication owned by Codex. Its helper may refresh its existing sign-in or update
   its own state. This differs from ADR-0001's Claude-specific never-refresh contract; do not
   claim that starting Codex is entirely free of Codex-managed writes or network requests.
3. Prefer the multi-bucket result when present, otherwise use the legacy single bucket.
   Render only returned windows with their durations. Missing windows are not zero usage;
   malformed required values fail the read and preserve the last good snapshot.
4. Reuse the existing UsageService cache, headroom scheduler, backoff and delivery tracker.
   Each provider gets its own service and storage namespace. Existing Claude preference keys
   remain intact. Codex warning identities include its provider, bucket and window.
5. Give each provider its own menu header with last-success age and error. The shared red dot
   reflects either provider and clears expired warnings without waiting for a fetch. One
   separately adjustable Codex threshold applies to every reported Codex window.
6. Bound the helper's lifetime and output; close and reap it after each read. Never log raw
   responses, helper stderr, account identifiers, or tokens. Store only the displayed usage,
   plan, timestamp and warning records.

## Consequences

- The app remains lightweight: no daemon owned by LimitGauge, no extra account setup and no
  new dependencies. A missing Codex installation does not interrupt Claude.
- Codex CLI must be discoverable. Its protocol and account availability can change; errors
  are visible and stale readings retain their timestamps.
- The helper startup adds work to each due Codex fetch, traded for a clean idle state between
  polls. The same two-minute menu cache and 10/30/60-minute headroom pacing limit that work.
- Codex credits, reset redemption and historical token analytics are outside this change.

## Verification

Synthetic decoder and subprocess tests cover schema and helper behavior. Service tests cover
cache isolation, in-flight coalescing, backoff, persistence and warning deduplication. A live
read on 2026-10-23 using Codex CLI 0.164.0 completed without a model turn and returned a
weekly-only window, confirming that a second window must remain optional. No raw live
response was saved.

The final `make test` run passed 127 tests across 21 suites, including malformed initialization,
closed stdin, notification flooding, immediate reply/exit and TERM-resistant cleanup. Independent
review found no remaining blocking defects. The ad-hoc signed release bundle built and ran
locally; both provider caches received fresh readings and the app had no helper child after
completion. Native UI automation timed out, so rendered-menu inspection and human visual
acceptance remain pending. The installed Applications copy was not replaced.
