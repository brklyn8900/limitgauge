---
title: "ADR-0005: A warning fires once per window, and counts once it is delivered"
status: Accepted
date: 2026-10-21
---

# ADR-0005: Warnings counted on delivery

**Status:** Accepted

## Context

The proposal's Warnings section says a warning posts once per limit and reset window, and a
new `resets_at` re-arms it. Three things about how that was built proved wrong:

- The usage endpoint shifts `resets_at` by under a second between fetches in the same window
  (21:10:00.462, then 21:09:59.776, captured 2026-10-21). Keyed on the raw value, every fetch
  was a new window, and a limit past its threshold warned again on each fetch.
- A warning was recorded as posted when it was decided, before anything was delivered. With
  notifications off in limitgauge or not allowed by macOS, that window's warning was lost.
- A limit whose window had reset while fetches failed kept its old percent: still red, still
  "Resets now", still lighting the warning dot.

The proposal is frozen, so these rules are recorded here.

## Decision

1. A warning's key is its limit and its reset time rounded to the nearest minute. Windows
   start on the minute, so rounding cannot merge two; truncating would split the captured
   pair. Keys saved before rounding are read back rounded.
2. A warning counts as fired once Notification Center accepts it. limitgauge checks its own
   switch and the macOS authorization before handing it over, and waits at most ten seconds.
   A warning that is not delivered stays due for its window and goes out after the next
   refresh or settings change, including when notifications are turned on. limitgauge is
   Notification Center's delegate and presents a warning in the foreground as in the
   background: a banner with sound, kept in Notification Center's list, even while it is the
   frontmost app, as it is while Settings is open. Without that, macOS silences it there while
   still accepting it. Accepted is not seen: with a Focus on, or limitgauge's alert style set
   to None, Notification Center accepts a warning that may never be seen, and it counts as
   fired.
3. The notification's identifier is derived from the key, so delivering the same warning
   twice replaces it instead of stacking a second one.
4. A limit whose window has reset since the last fetch is unknown: the menu shows a dash and
   an empty bar, it does not light the warning dot, and it does not warn. The dot is redrawn
   at that reset, and on wake, not only after the next refresh.

## Consequences

- One warning per limit per window, as the proposal intended, across fetches and relaunches.
- A warning missed while notifications were off arrives when they are turned back on, if its
  window is still open, with the current percent.
- Delivery is at least once: a delivery that lands after its ten-second wait, or a crash
  before the record is saved, offers the warning again, and the stable identifier makes that
  a replacement.
- Background pacing does not depend on delivery (ADR-0002 point 2), so an undelivered
  warning costs no extra polls.

## Alternatives considered

- **Count a warning when it is decided** (the first build). Simple, but loses the warning
  whenever delivery fails, silently.
- **Count it when decided, but keep polling every ten minutes until it is delivered.** Costs
  six requests an hour for up to a week with notifications off, for a warning nobody can see.
- **Treat notifications off as delivered.** The switch cannot tell "off for good" from "off
  for a meeting"; a warning still matters when it comes back on.
