# limitgauge

<p align="center">
	<img src="docs/images/menu-warning.png" width="324" alt="The limitgauge menu: plan, current session, this week, and Fable this week with reset times, credits, and the week by surface. Fable this week is past its threshold, so its bar is red and the icon has a red dot.">
</p>

limitgauge shows your Claude and Codex plan usage limits in the macOS menu bar. The Claude
section shows the current session, this week, and the weekly model limit, each with its reset
time, plus credits and the split across Claude Code, chats, and Cowork. These are the same
numbers as the Usage page in claude.ai settings. The Codex section shows the quota windows
reported for your signed-in account, with their percentages and reset times.

When a limit passes a threshold you set, limitgauge sends a notification and puts a red dot on
its icon. It reads the sign-in that Claude Code already keeps in your Keychain, so you have
nothing to configure and no token to paste. For Codex, it asks the local Codex CLI app server
for the limits of the account already signed in with ChatGPT. Each provider has its own
cached readings, update time, and failure message.

limitgauge is unofficial and not affiliated with Anthropic or OpenAI.

## Why limitgauge

The Claude reader never raises a Keychain dialog, never refreshes or rewrites Claude Code's
sign-in, and calls only two read-only endpoints on `api.anthropic.com`. The Codex reader uses
its documented local app-server protocol and never handles a Codex token itself. In the
background, each provider checks hourly while its limits are far from their thresholds and
every 10 minutes when one gets close.

## Requirements

- macOS 26 or later.
- Xcode 26, or its command line tools.
- Claude Code, signed in with your Claude subscription on this Mac, for Claude usage.
- Codex CLI, signed in with ChatGPT on this Mac, for Codex usage. API-key billing is not the
  subscription quota shown here. Either provider can work while the other is unavailable.

## Install

limitgauge has no prebuilt download. Build it from source:

	git clone https://github.com/eladefrati/limitgauge.git
	cd limitgauge
	make install

`make install` builds the app, signs it, and copies it to `/Applications`. Open **limitgauge**
from Applications. It runs in the menu bar and has no Dock icon. On first launch, macOS asks
whether limitgauge can send notifications.

If your keychain has an Apple Development certificate, `make install` signs with the first
one it finds. To use a different one, run `make install SIGN_IDENTITY="<certificate name>"`.
Without a certificate, `make install` signs the build ad hoc, and macOS can reset the
notification permission and **Launch at login** each time you rebuild.

limitgauge raises no Keychain dialog. If macOS asks for access to the "Claude
Code-credentials" item, choose **Deny**. limitgauge doesn't need that access. The dialog means
something outside limitgauge changed, most likely how Claude Code stores the item
([ADR-0004](docs/adr/0004-read-credentials-through-security-cli.md)).

## Read your limits

- Click the icon. The menu shows separate Claude and Codex sections with their plan, last
  successful update time, limits, and reset times. Claude also shows credits and the week by
  surface.
- limitgauge fetches new numbers when you open the menu, if the last fetch is more than two
  minutes old. **Refresh** fetches at once.
- A red dot on the icon means a limit is past its warning threshold.
- For Claude, while no five-hour window is open, **Current session** shows 0% and no reset time.
- Compact view shows only weekly bars; all existing warning checks remain active, including
  limits hidden by the compact layout.
- Codex shows the windows and buckets actually returned by the service, labeled by duration.
  A missing window is not treated as 0%. If a refresh fails, the last readings remain visible
  with their age and the error; expired windows show as unknown until refreshed.
- If the session limit comes back in a shape limitgauge can't read, **Current session** shows a
  dash and "Couldn't read this limit" until a fetch reads it.

Between fetches, limitgauge checks in the background only to send warnings. The closer a limit
is to its threshold, the sooner the next check: every 60, 30, or 10 minutes. After a failed
fetch, the checks space out.
[ADR-0002](docs/adr/0002-fetch-on-open-and-headroom-polling.md) has the full rules.

## Set thresholds and the icon

<p align="center">
	<img src="docs/images/settings.png" width="400" alt="limitgauge Settings: warning thresholds for the current session, this week, and Fable this week, the notification switch, the menu bar icon, the red dot switch, and Launch at login.">
	<img src="docs/images/icon-styles.png" width="400" alt="The menu bar icon picker: Hourglass in circle, Hourglass, Drop in circle, Gauge, Bars, and Timer.">
</p>

Choose **Settings…** from the menu to set:

- a warning threshold for each Claude limit, in percent,
- a separate **Codex limits** threshold, applied to each reported Codex window,
- a custom global **Menu shortcut** to open or close the menu: click Record shortcut and press your combination with Command, Control, or Option; Escape cancels and Clear removes it (no Accessibility permission needed),
- **Detailed** or **Compact** view (compact overlays solid Claude All and Fable weekly fills in one track, with the longer fill underneath, plus one Codex weekly bar; hover for reset times and update details),
- a separate Fable color for the overlaid weekly limit,
- a bar color for each provider: pastel Blue, Teal, Green, Amber, Purple, and Pink, plus Black, Gray, and Light gray (warnings stay red),
- whether limitgauge sends notifications,
- the menu bar icon, from six styles, and whether it shows the red dot,
- whether limitgauge opens at login.

## Your token and the network

limitgauge reads Claude Code's OAuth access token with this command, the same one Claude Code
uses for the Keychain item:

	/usr/bin/security find-generic-password -s "Claude Code-credentials" -w

It sends the token only to `api.anthropic.com`, in the `Authorization` header of `GET`
requests to two endpoints:

| Endpoint | What limitgauge reads | How often |
|---|---|---|
| `/api/oauth/usage` | Your limits, credits, and the week by surface | On each fetch |
| `/api/oauth/profile` | Your plan name | At most once a day |

The Claude reader makes no other network requests. It keeps the token in memory only and never writes
it to disk or to the log. It never refreshes the token or changes the Keychain item. When the
token expires, the menu tells you to run `claude` in a terminal, which signs you in again.

Neither endpoint is part of Anthropic's documented API. Anthropic can change or remove them
without notice. Depending on the change, limitgauge then shows an error instead of numbers, or
a row goes missing from the menu with no error. See
[ADR-0001](docs/adr/0001-usage-endpoint-with-claude-code-token.md).

### Codex usage

limitgauge launches a short-lived `codex app-server --stdio`, completes the initialization
handshake, and calls `account/rateLimits/read`. It reads percentages, window durations, reset
times, bucket labels, and the plan when supplied. It does not start a coding turn, redeem a
reset credit, log in, or log out. The process is closed after the read; a deadline prevents a
stuck helper from stopping future refreshes.

Codex owns authentication and its service requests. limitgauge does not read `auth.json`,
copy tokens, or implement token refresh. Codex itself may refresh its existing sign-in or
update its own state; the Claude reader's never-refresh promise does not apply to Codex.

The reader discovers Codex in `/opt/homebrew/bin`, `/usr/local/bin`, the Codex application
bundle, or the app's `PATH`. It never invokes a shell. If it cannot find Codex, the menu
explains how to enable the provider. Missing sign-in, a timeout, or an unreadable response
shows a message instead of a fabricated usage value. Raw responses and helper stderr are
not logged or cached.

See the [official app-server documentation](https://learn.chatgpt.com/docs/app-server) and
[ADR-0006](docs/adr/0006-codex-usage.md).

## What limitgauge stores

In its preferences, under `io.github.eladefrati.limitgauge`, limitgauge keeps its settings, the
last usage numbers, your plan name, and a record of the warnings it sent. The profile response
also holds your account email. limitgauge keeps only the plan name from it. Codex's account
identifier and other response metadata are discarded. Codex readings and warning records use
separate preference keys, preserving the existing Claude cache and warnings. limitgauge does
not cache raw responses.

limitgauge logs failures to the macOS unified log, never the token or a response body. To watch
the log, run `make log`.

## Uninstall

1. In **Settings…**, turn off **Launch at login**.
2. Quit limitgauge from its menu.
3. Delete `/Applications/limitgauge.app`.
4. To delete its stored settings and numbers too, run
   `defaults delete io.github.eladefrati.limitgauge`.

## Develop

`make test` runs the tests. `make run` builds the app, quits a running limitgauge, and opens the
new build from `build/limitgauge.app`.

Run limitgauge only from its app bundle. `swift run` and `.build/release/limitgauge` crash at
launch, because Notification Center needs the bundle's identifier.

The [proposal](docs/proposal.md) is the original design, kept as written. The
[ADRs](docs/adr/) record the decisions since, and
[changes since the proposal](docs/changes-since-proposal.md) lists where limitgauge differs
from the proposal.

## License

MIT. See [LICENSE](LICENSE).
