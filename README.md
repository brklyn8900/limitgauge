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

Open limitgauge from Applications. On the first fetch macOS asks whether limitgauge may read
the item named "Claude Code-credentials"; choose Always Allow. It runs as an icon in the menu
bar; there is no Dock icon.

## Use

- Click the icon. The dropdown shows your plan, each limit with its percent and reset time,
  credits, and how the week splits across Claude Code, chats and other surfaces.
- Numbers refresh when you open the menu. A red dot on the icon means a limit is past its
  warning threshold.
- Settings: warning thresholds per limit, notifications, the warning dot, icon, launch at
  login.
