# limitgauge design

Design document. Status: accepted 2026-10-18. Changes after acceptance go to
[ADRs](adr/), not to this file.

## Overview

limitgauge is a macOS menu bar app that shows the usage limits of a Claude subscription:
the same numbers as the Usage page in claude.ai settings, one click away. It shows the plan,
the current session limit, the weekly limit, the model-scoped weekly limit, when each resets,
cloud session credits, usage credits, and how the week's usage splits across surfaces.

It reads the data from the account usage endpoint that Claude Code uses, authenticated
with the token Claude Code keeps in the login Keychain. It never writes credentials, never
scans local logs, and never touches browser cookies.

The menu bar shows an icon only. The numbers live in the dropdown and are fetched when the
menu opens. A slow background poll exists for one purpose: a notification before a limit is
hit.

## Goals

- Every field of the claude.ai Usage page in the dropdown, with reset times in local time.
- Data that is current at the moment the user looks at it.
- A notification when a limit crosses a user-set threshold, once per limit per window.
- Zero setup beyond installing and allowing one Keychain read. No commands to run, no token to
  paste. Signing in to Claude Code is the sign-in.
- Harmless to Claude Code: the token is read, never refreshed or rewritten.
- Negligible load: one request per menu open at most every two minutes, one background poll
  per 10 to 60 minutes depending on headroom.

## Non-goals

- A live number in the menu bar. Icon only; the dropdown has the numbers.
- Cost estimates from local Claude Code logs. The endpoint has no token counts and no
  API-price figures; estimating them means scanning session logs, which this app does not do.
- Browser cookie import. If the Keychain token is not available, the app says so.
- Other providers in the first version.
- Distribution outside this machine. No notarization, no auto-update.

## Design

### Data source

Two GET requests against `api.anthropic.com`, each with `Authorization: Bearer <token>` and
`anthropic-beta: oauth-2025-04-20`:

- `/api/oauth/usage?cedar_ember=1`: the limits and credits. Fetched on menu open and on
  background polls.
- `/api/oauth/profile`: the plan tier. Fetched at launch and once a day; it almost never
  changes.

Field mapping, as observed on 2026-10-18:

| Row | Source |
|---|---|
| Plan | `profile.organization.rate_limit_tier` (`default_claude_max_5x`) |
| Current session | `usage.limits[kind=session]`: `percent`, `resets_at` |
| This week | `usage.limits[kind=weekly_all]` |
| Model week (Fable) | `usage.limits[kind=weekly_scoped]`, `scope.model.display_name` |
| Cloud session credits | `usage.iguana_necktie`: `limit_dollars`, `remaining_dollars`, `resets_at` |
| Usage credits | `usage.spend` (`balance`, `used`) and `usage.extra_usage` |
| Limit resets | `usage.cedar_ember.grants[]` |
| Weekly breakdown | `usage.seven_day_breakdown` |

The `limits[]` array is the stable-looking part. Several other keys are internal codenames
and will be renamed. Every row outside `limits[]` decodes as optional: a renamed key hides
its row and the rest of the menu keeps working. The endpoint is undocumented; the app treats
any decode failure as "field unavailable", never as a crash.

### Authentication

Claude Code stores its OAuth credentials as a generic password item named
`Claude Code-credentials` in the user's login Keychain, a JSON blob with an access token, a
refresh token and an expiry. limitgauge reads the item through the Security framework and
uses the access token.

Rules:

- Read only. The app never calls the token refresh endpoint and never writes the item. A
  refresh would rotate the refresh token and could log Claude Code out.
- On a 401, read the item again once: Claude Code may have rotated the token since the last
  read. If the second attempt also fails, the dropdown shows "Token expired. Run claude in a
  terminal to sign in again."
- The first read raises the macOS Keychain consent dialog. The user clicks Always Allow once.
  The grant is keyed to the app's code signature, which is why the build signs with a stable
  identity (ADR-0003).

Claude Code can recreate the Keychain item when it rotates the token, which can drop the
grant and bring the dialog back. If that turns out to be frequent, the fallback is a long-lived
token created by `claude setup-token` and stored in limitgauge's own Keychain item. It is not
built until the prompt proves to be a nuisance.

### Menu bar

An `NSStatusItem` with a template image, so it follows light and dark menu bars. No text.
A small red dot at the bottom right of the icon appears while any limit is past its warning
threshold, and can be turned off in Settings.

The icon is a user choice: `hourglass.circle` (default), `hourglass`, `drop.circle`,
`gauge.with.needle`, `chart.bar.fill`, `timer`, or the Anthropic mark bundled as an SVG
template.

### Dropdown

An `NSMenu` whose rows are custom views, in the order of the claude.ai Usage page:

1. Plan name.
2. Current session: progress bar, percent, "Resets in 2h 14m (7:00 PM)".
3. This week: same.
4. Model week: same, titled with the model's display name from the response.
5. Cloud session credits: remaining of limit, expiry.
6. Usage credits: used and balance.
7. Limit resets: the grants, or "No resets right now".
8. Weekly breakdown: percent per surface.
9. Footer: "Updated 12 s ago", Refresh, Settings, Quit.

A row whose field is missing from the response is hidden, not shown empty.

### Refresh model

Three triggers fetch usage; one snapshot serves them all.

- **Menu open.** The menu shows the cached snapshot immediately. If the snapshot is older
  than two minutes, a fetch starts in the background and the rows update in place when it
  lands, about 0.2 s later. Nothing the user would act on changes faster than that, even in
  the five-hour window.
- **Refresh item.** Forces a fetch.
- **Background poll.** Exists only to drive warnings. After every fetch, the app computes
  each limit's headroom, the warning threshold minus the current percent, in percentage
  points. The limit with the least headroom sets the next poll:

  | Least headroom | Next poll |
  |---|---|
  | more than 40 points | 60 min |
  | 15 to 40 points | 30 min |
  | under 15 points | 10 min |

  A limit that has already fired its warning is excluded until its window resets. Any fetch,
  including one from a click, restarts the clock. Timers do not fire while the Mac sleeps; on
  wake, the app polls if the next poll is overdue.

The cached snapshot and its timestamp persist across launches, so the menu is never empty at
startup.

### Warnings

One threshold per limit, in percent. Defaults: session 80, week 85, model week 80. When a
fetch shows a limit at or past its threshold, the app posts a macOS notification through
`UNUserNotificationCenter` naming the limit, the percent and the reset time.

A warning fires once per limit per window. The dedupe key is the limit kind and its
`resets_at`; a new `resets_at` re-arms it. Notifications are on by default: the app requests
the system permission at first launch, and Settings has a switch to turn them off. If the
permission was denied, Settings links to the Notifications pane of System Settings.

### Settings

A small window: thresholds, notifications on or off, icon, warning dot on or off, launch at
login through `SMAppService`. Stored in `UserDefaults` alongside the last snapshot.

### Verification

- Unit tests decode a redacted real response fixture into the model, including a fixture
  with the codename keys removed.
- The poll scheduler is a pure function of headroom and elapsed time, tested directly.
- The warning dedupe is a pure function of the previous and current snapshot, tested
  directly.
- Manual: open the menu next to the claude.ai Usage page and compare every row. Lower a
  threshold below the current percent and confirm one notification, then none on the next
  poll.

## Alternatives considered

- **An existing menu bar usage app.** Several exist. They poll on a timer and show a number
  in the menu bar, and none shows the full Usage page. Building our own gives fetch on open,
  the full set of fields, and the smallest exposure: one token, two endpoints.
- **Claude Code's status line as a data feed.** Claude Code hands its status line script the
  five-hour and weekly percentages after each turn. That covers two of the three limits, only
  while Claude Code is in use, and the script also runs on events other than turn end, so
  stale writes would race fresh fetches. The model-scoped limit and the credits are only on
  the endpoint. Not used.
- **Timer polling with a number in the menu bar.** Always slightly stale. Fetching on open
  is current by construction and simpler. The trade-off, accepted, is no information at a
  glance: the icon says nothing until it is clicked.
- **Refreshing the token ourselves.** Removes the "run claude" failure mode but risks
  invalidating Claude Code's refresh token. Rejected.

## Risks

- **Undocumented endpoint.** Keys are renamed or the shape changes. Mitigation: optional
  decoding per row, a fixture test that fails loudly when a real response stops decoding.
- **Keychain prompt recurrence.** Claude Code recreates the item and the grant is lost.
  Mitigation: stable signing identity; the `setup-token` fallback if needed.
- **Token expiry when Claude Code is idle.** The access token is short-lived and only Claude
  Code renews it. The menu says what to do. Accepted.
- **Usage endpoint rate limits.** Unknown. The two-minute cache and the headroom schedule
  keep requests to a handful per hour.

## Milestones

1. Proposal and ADRs.
2. Keychain reader and API client, with decoding tests against the fixture.
3. Menu bar item and dropdown, fetch on open with the two-minute cache.
4. Warnings, settings, headroom scheduler, wake handling.
5. Makefile bundle, signing, install, launch at login.

## Stack

Swift 6, AppKit, UserNotifications, ServiceManagement, Security. SwiftPM executable, no
dependencies. macOS 26. Build and packaging as in ADR-0003.
