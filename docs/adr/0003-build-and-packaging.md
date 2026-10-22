---
title: "ADR-0003: SwiftPM executable, Makefile bundle, Apple Development signing"
status: Accepted; the Keychain grant reasoning no longer applies since ADR-0004
date: 2026-10-18
---

# ADR-0003: Build and packaging

**Status:** Accepted. The Keychain grant in Context and Consequences no longer applies: since
[ADR-0004](0004-read-credentials-through-security-cli.md) the item is read through
`/usr/bin/security`, whose access does not depend on limitgauge's signature. A stable
signature still keeps notification permission and launch at login across rebuilds.

## Context

limitgauge is a menu bar app built from source and installed locally. It needs an `.app` bundle
with an `Info.plist` (menu bar only, no Dock icon) because notifications require a bundle
identifier, and a stable code signature: the Keychain grant for Claude Code's credentials
item is keyed to the signing identity, so an ad-hoc signature would bring the consent dialog
back on every rebuild.

## Decision

1. **SwiftPM executable target**, Swift 6, AppKit, no dependencies. No Xcode project; all
   build inputs are text files under version control.
2. **A `Makefile` assembles the bundle:** `make app` builds release, lays out
   `build/limitgauge.app/Contents/{MacOS,Resources,Info.plist}`, copies bundled icon assets,
   and codesigns. `make install` copies the bundle to `/Applications`. `make run` launches it.
3. **Sign with an Apple Development certificate** from a free personal team, identity
   selected by a `SIGN_IDENTITY` make variable. Falls back to ad-hoc signing with a printed
   warning when none is found.
4. **No sandbox, no restricted entitlements**, so no provisioning profile is needed.
5. **Version strings** are `YYYY.MM.DD.N` in `Info.plist`, bumped and tagged before an
   install when code changed since the last tag.

## Consequences

- Rebuilds keep the Keychain grant once a certificate is installed.
- No Xcode GUI needed; the command line tools and SDK are the only requirement.
- Notarization and distribution are out of scope. Adding them later means a Developer ID
  certificate and a notarization step in the Makefile, not a change of build system.

## Alternatives considered

- **Xcode project:** gives signing and bundle assembly for free, but a binary-ish
  `.pbxproj` in git and GUI-only settings. Not worth it for one target.
- **xcodegen or tuist:** generates the project from YAML. Extra tool for what a 30-line
  Makefile does.
- **SwiftUI `MenuBarExtra`:** its window style is a floating panel, not a menu. An AppKit
  `NSStatusItem` with an `NSMenu` behaves like a native menu.
  The bundle is needed either way for notifications.
