# TinRelay upgrade-guide audit

Burn down these findings before treating `UPGRADING.md` as the authoritative
upgrade path. The audit covers the current direct-routing working tree atop
`ad66b5e79525dc30c908d96d9774b36c63209535` and earlier compatibility-affecting
history.

- [x] Make the direct-routing cutover race-free. Stop the collector first, stop
  the old bridge, and inspect the private pending binding only after the old
  bridge can no longer recreate it. If a binding remains, retain or restore the
  old binary and configuration long enough to settle it while collection stays
  stopped, then stop and inspect again before replacement. Replace the binary
  and service definition only at that quiescent boundary.

- [x] Require a successful foreground bridge check before restarting services.
  After `tinrelay-codex-bridge --install` and any required Codex or ChatGPT
  restart, run `tinrelay-codex-bridge check --ship "$SHIP"` with the same
  `--routing-file`, `--tinrelay`, and `--codex-home` values used by the service.
  Stop on any result other than a successful check.

- [x] Replace the local-only `tinrelay-mapping.json` assumption. Tell operators
  to move the exact mapping file used by their old service into
  `$HOME/.config/tinrelay/$SHIP/codex-addresses.json`, unless they intentionally
  retain an absolute `--routing-file`. Do not overwrite an existing address
  book; reconcile it explicitly and preserve private ownership and permissions.

- [x] Explain destination freezing for every event, not only ambiguous
  submissions. The bridge records the selected task before the first attempt;
  `NotReceived` retries that same task, and editing the address book affects only
  future unbound events. Preserve the binding on `ReceiptUnknown`; do not suggest
  deletion or manual retargeting as recovery.

- [x] Make old installation cleanup exact and correctly ordered. After the old
  bridge is definitively retired, remove obsolete service arguments and name the
  historical installed files:
  `$HOME/.local/libexec/tinrelay/tinrelay-notify-pending` and
  `$HOME/.local/libexec/tinrelay/tinrelay.icns`. Give the platform-appropriate
  stop, service-definition replacement, reload, and restart boundary rather than
  saying only to restart the service.

- [x] Clarify the rotation-limit recovery entry. Upgrading preserves the pending
  provisional identity and enables bounded retry evidence, but the operator must
  rerun the same `contact close` command; upgrading alone does not complete or
  report that operation.

- [x] Remove the local-renderer paragraph from `UPGRADING.md` or move it to the
  bridge/protocol documentation. It is not an operator action and conflicts with
  the file's stated action-only scope.
