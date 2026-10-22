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

1. **Menu open shows the cached snapshot at once.** If the last fetch attempt, successful or
   not, is older than two minutes, a fetch runs in the background and the rows update in
   place. A poll that sent no request (point 3) is not counted, so the first menu open after
   one fetches. A Refresh item forces a fetch.
2. **Background polls exist only for warnings.** After every successful fetch, compute each
   limit's headroom: warning threshold minus current percent, in percentage points. The least
   headroom among limits still below their threshold picks the next poll: over 40 points,
   60 min; 15 to 40, 30 min; under 15, 10 min. A limit at or past its threshold has nothing
   left to warn about until its window resets, so it leaves the pacing; the next poll comes
   one minute after that reset if that is sooner.
3. **After a failed fetch, polls back off**, never sooner than the last snapshot's own pace.
   No network, a 5xx or an unreadable response: 10 minutes after the first failure, doubling
   up to 60. A 429: 30 minutes, then 60. Failures only the user can fix (no credentials, a
   rejected token, a locked, refused or timed-out Keychain read, an unreadable Keychain item, a
   failing `security` tool): 60 minutes. A poll does not resend a token the endpoint has
   rejected, and does not run a Keychain read again after one found the keychain locked
   (exit 36), was refused or timed out, so a Keychain dialog cannot return on every poll;
   opening the menu or Refresh does both. The first success returns to headroom pacing.
4. Any fetch attempt restarts the clock, so a user who opens the menu often pays for no extra
   polls.
5. No timer fires while the Mac sleeps. On wake the timer is re-armed for the same time, so
   an overdue poll runs at once. Its fetch waits for the network to come back instead of
   failing as offline. Every fetch waits that way, up to its 30-second limit, so offline a
   menu open or Refresh shows "Updating…" for up to 30 seconds before the error.
6. The snapshot and its timestamp persist in `UserDefaults`, so the menu is populated at
   launch.

## Consequences

- The numbers are current when viewed, by construction, as long as the fetch succeeds. When
  it fails, the menu keeps the last snapshot with the error and its age, and a limit whose
  window has reset since shows as "Reset since the last update" (ADR-0005 point 4).
- Request volume is a handful per hour at most, and lowest when it matters least. A failure
  never polls faster than success would. An expired token while Claude Code is idle costs
  one rejected request, then a Keychain read an hour and no requests. A refused Keychain read
  costs one read, then nothing until the user opens the menu.
- A warning can arrive up to one poll interval after the threshold was actually crossed. With
  the 10-minute step near the threshold this is accepted.
- The scheduler is a pure function of the snapshot, the run of consecutive failures and the
  thresholds. It does not read the clock, and every due time it returns is at least a minute
  after the last attempt, so no state can make it poll in a loop. It lives in the core
  library and is tested without timers.

## Alternatives considered

- **Timer polling with a number in the menu bar.** Always slightly stale. Fetching on open is
  current by construction and simpler; the accepted cost is no information at a glance.
- **Poll every 30 minutes once the session limit is above 50 percent, otherwise hourly.**
  The first version of this rule. A fixed trigger on usage ignores both the threshold and the
  rate: the five-hour session limit can move 40 points in half an hour, while a weekly limit at
  51 percent cannot move meaningfully in that time, and the rule said nothing about the weekly
  limits. Replaced by headroom, which is the quantity a warning depends on.
- **Retry a failed fetch on the headroom schedule.** A failure leaves no fresh snapshot to
  pace from, and a 429 or a dead token would be retried as often as a healthy fetch.
- **Status line triggered polls.** Poll when Claude Code's status line script reports a turn
  and the last poll is older than a few minutes. Ties the schedule to Claude Code only and
  brings back the status line feed and its stale-write race. Dropped with the feed.
