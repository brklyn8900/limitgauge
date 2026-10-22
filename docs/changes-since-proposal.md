# Changes since the proposal

The [proposal](proposal.md) is kept as written. These parts of it no longer hold:

- **Keychain access.** The consent dialog, the Always Allow step, and the `claude setup-token`
  fallback are gone. limitgauge reads the item through `/usr/bin/security`, which the item
  already trusts. See [ADR-0004](adr/0004-read-credentials-through-security-cli.md).
- **The idle session row.** The proposal hides a row whose field is missing from the response.
  The endpoint drops the session limit while no five-hour window is open, so the menu shows
  **Current session** at 0% instead of hiding the row.
- **Poll pacing.** The proposal leaves out a limit whose warning has fired. limitgauge leaves
  out every limit at or past its threshold, warned or not, so a warning that could not be
  delivered doesn't hold polling at 10 minutes. See
  [ADR-0002](adr/0002-fetch-on-open-and-headroom-polling.md).
- **The menu cache and the poll clock.** The proposal times the two-minute menu cache from the
  snapshot. limitgauge times it, and the poll clock, from the last fetch attempt, failed or
  not, so a failing endpoint isn't asked again on every menu open. A poll that sent no request
  moves only the poll clock. See [ADR-0002](adr/0002-fetch-on-open-and-headroom-polling.md).
- **The warning key.** The proposal keys a warning on the limit and its `resets_at`. The
  endpoint shifts `resets_at` by under a second between fetches, so the key rounds it to the
  nearest minute. See [ADR-0005](adr/0005-warnings-counted-on-delivery.md).
- **When a warning counts.** A warning counts as sent once it is delivered, not when it is
  due. One that can't be delivered, because notifications are off or not allowed, goes out
  once they are on, if its window is still open: at once when you turn on limitgauge's switch,
  and at the next refresh when you allow notifications in System Settings. See
  [ADR-0005](adr/0005-warnings-counted-on-delivery.md).
- **Test fixtures.** The proposal calls for a redacted real response. The fixtures are
  synthetic, in the real response's shape, so no account's usage is in the repository.
- **The Anthropic mark.** It is not one of the icon choices. It was dropped on trademark
  grounds.
