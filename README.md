# limitgauge

A macOS menu bar app that shows your Claude subscription's usage limits: session, week and
model week with their reset times, credits, and the weekly breakdown. The same numbers as the
Usage page in claude.ai settings, one click away, plus a notification before you hit a limit.

It reads the account usage endpoint with the token Claude Code already keeps in your
Keychain. Nothing to configure, nothing to paste, and it never writes credentials. Details in
the [proposal](docs/proposal.md); decisions in the [ADRs](docs/adr/).

## Install

Requires macOS 26, Xcode 26 or its command line tools, and a Claude Code sign-in on this
machine. From a checkout:

    make install

Open limitgauge from Applications. It runs as an icon in the menu bar, with no Dock icon. At
first launch, macOS asks whether limitgauge may send notifications.

limitgauge raises no Keychain dialog. If macOS asks for access to the "Claude
Code-credentials" item, don't approve it. Choose Deny. limitgauge doesn't need that access,
and the dialog means something outside limitgauge changed, most likely how Claude Code stores
the item ([ADR-0004](docs/adr/0004-read-credentials-through-security-cli.md)).

## Use

- Click the icon. The dropdown shows your plan, each limit with its percent and reset time,
  credits, and how the week splits across Claude Code, chats and other surfaces.
- Numbers refresh when you open the menu. A red dot on the icon means a limit is past its
  warning threshold.
- While no five-hour window is open, the endpoint reports no session limit. The menu then
  shows **Current session** at 0% with no reset time.
- Settings: warning thresholds per limit, notifications, the warning dot, icon, launch at
  login.

## Your token and the network

limitgauge reads Claude Code's OAuth access token by running
`/usr/bin/security find-generic-password -s "Claude Code-credentials" -w`, the same command
Claude Code uses to read the item. It sends the token only to `api.anthropic.com`. It keeps
the token in memory and never writes it to disk or to the log. It never refreshes the token
either. When the token expires, the menu tells you to run `claude`, which gets a new one.

The usage endpoint, `/api/oauth/usage`, is undocumented. Anthropic can change or remove it
without notice, and limitgauge then shows an error instead of numbers.

Opening the menu fetches when the last fetch attempt is more than two minutes old, and
**Refresh** fetches at once. Between those, limitgauge polls in the background only to send
warnings. The limit closest to its warning threshold sets the next poll:

| Points left below the threshold | Next poll |
|---|---|
| more than 40 | 60 min |
| 15 to 40 | 30 min |
| under 15 | 10 min |

A limit already past its threshold doesn't count. limitgauge polls one minute after that limit
resets, if that comes sooner. Any fetch restarts the clock, so opening the menu often adds no
polls. After a failed fetch, polls back off. A network error or a server error waits 10
minutes, then doubles up to 60. A rate limit waits 30 minutes, then 60. A failure only you can
fix, such as a missing sign-in, waits 60 minutes. After a locked, refused or unanswered Keychain
read, polls stop reading the Keychain until you open the menu or press **Refresh**.
[ADR-0002](docs/adr/0002-fetch-on-open-and-headroom-polling.md) has the full rules.

## Develop

`make test` runs the tests. `make run` builds the bundle, quits a running limitgauge, and
opens the new build from `build/limitgauge.app`.

Run limitgauge only from its bundle. `swift run` and `.build/release/limitgauge` crash at
launch, because Notification Center needs the bundle's identifier.

## Changes since the proposal

The [proposal](docs/proposal.md) is kept as written. These parts of it no longer hold:

- **Keychain access.** The consent dialog, the Always Allow step, and the `claude setup-token`
  fallback are gone. limitgauge reads the item through `/usr/bin/security`, which the item
  already trusts. See [ADR-0004](docs/adr/0004-read-credentials-through-security-cli.md).
- **The idle session row.** The proposal hides a row whose field is missing from the response.
  The endpoint drops the session limit while no five-hour window is open, so the menu shows
  **Current session** at 0% instead of hiding the row.
- **The Anthropic mark.** It is not one of the icon choices. It was dropped on trademark
  grounds.
