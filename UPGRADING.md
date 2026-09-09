# Upgrading TinRelay

This file records only upgrades that require action because a release or commit
changes local client state or configuration compatibility, or server file or
database compatibility.

Each entry identifies the previous compatible commit and the exact action an
operator or user must take. Ordinary code, protocol-compatible behavior,
documentation, dependency, and presentation changes are not listed here.

## Registration-event schema 002

The last commit without the registration-events schema is
`fd313d05b52eb57eade2d3c4b8afd53fb1a66bbe`.

Before starting a newer server against an existing database, make a consistent
SQLite backup using the exact procedure in [OPERATIONS.md](OPERATIONS.md#backup-and-restore).
Startup applies migration `002`; after that succeeds, an older binary rejects the
newer schema. Restoring the backup after traffic resumes loses every write the
repeater accepted after that backup.

## Clients without rotation-limit support

The last commit without rotation-limit client support is
`0f7864f42fca0babf1979e45d1dea794063ea7e0`.

An older client treats the repeater's exact timed radio-retune refusal as generic
unavailability. It may retain the unaccepted provisional radio identity and refuse an
owner rotation until that retune is resolved. Do not delete or replace the keyring.
After the server's 24-hour window reopens, repeat the same `contact close` command so
the client reuses and resolves the pending identity, or upgrade the client first to
receive the bounded retry time while preserving that prior uncertain identity.
