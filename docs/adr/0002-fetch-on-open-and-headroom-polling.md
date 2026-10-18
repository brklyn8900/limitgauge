---
title: "ADR-0002: Fetch on menu open behind a two-minute cache; background polls only for warnings, paced by headroom"
status: Accepted
date: 2026-10-18
---

# ADR-0002: Fetch on open and headroom polling

**Status:** Accepted

## Context

The menu bar shows an icon only, so nothing needs to be fresh until the user opens the menu.
A fetch takes about 0.2 s. The one thing that must happen without the user looking is a
warning before a limit is hit, and that needs the app to look on its own. Existing apps poll
on a timer, fixed or adapted to how often the menu is used, which is both too often while
idle and too seldom when a five-hour window is being spent quickly.

## Decision

1. **Menu open shows the cached snapshot at once.** If it is older than two minutes, a fetch
   runs in the background and the rows update in place. A Refresh item forces a fetch.
2. **Background polls exist only for warnings.** After every fetch, compute each limit's
   headroom: warning threshold minus current percent, in percentage points. The least
   headroom among limits that have not yet fired picks the next poll: over 40 points, 60 min;
   15 to 40, 30 min; under 15, 10 min.
3. Any fetch restarts the clock, so a user who opens the menu often pays for no extra polls.
4. No timer fires while the Mac sleeps. On wake, poll if the next poll is overdue.
5. The snapshot and its timestamp persist in `UserDefaults`, so the menu is populated at
   launch.

## Consequences

- The numbers are current when viewed, by construction. There is no staleness to explain.
- Request volume is a handful per hour at most, and lowest when it matters least.
- A warning can arrive up to one poll interval after the threshold was actually crossed. With
  the 10-minute step near the threshold this is accepted.
- The scheduler is a pure function of the snapshot and the clock, which keeps it testable
  without timers.

## Alternatives considered

- **Timer polling with a number in the menu bar.** Always slightly stale. Fetching on open is
  current by construction and simpler; the accepted cost is no information at a glance.
- **Poll every 30 minutes once the session limit is above 50 percent, otherwise hourly.**
  The first version of this rule. A fixed trigger on usage ignores both the threshold and the
  rate: the five-hour session limit can move 40 points in half an hour, while a weekly limit at
  51 percent cannot move meaningfully in that time, and the rule said nothing about the weekly
  limits. Replaced by headroom, which is the quantity a warning depends on.
- **Status line triggered polls.** Poll when Claude Code's status line script reports a turn
  and the last poll is older than a few minutes. Ties the schedule to Claude Code only and
  brings back the status line feed and its stale-write race. Dropped with the feed.
