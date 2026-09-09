# Operating one repeater

TinRelay is designed for one small Linux container behind a trusted HTTPS edge
and one persistent SQLite volume. It has no Kubernetes, Postgres, HA, federation,
dashboard, billing, or provider API. Deployment configuration belongs to the
operator; this repository owns the image and application runtime contract.

## Container contract

`Dockerfile` builds only `tinrelayd` into a scratch image. The final image contains
the daemon, its minimal runtime libraries, the bootstrap templates, BusyBox for the
entrypoint, and no source, specs, Git metadata, or client binary.

The image has two entrypoint actions:

- `prepare` runs as root only to make `/var/lib/tinrelay` mode 0700 and owned by
  UID/GID 10001;
- `serve` refuses root, opens `/var/lib/tinrelay/tinrelay.db` mode 0600, binds port
  8787, and starts the one repeater process.

Run the service as UID/GID 10001 with a read-only root filesystem, all Linux
capabilities dropped, `no-new-privileges`, and a writable persistent volume only
at `/var/lib/tinrelay`. Terminate TLS at the trusted edge.

Meet pages derive their one-time `tinrelay --ship SHIP join --server` origin from the request
host and scheme. The trusted edge must preserve `Host` and set
`X-Forwarded-Proto` to `https`; a direct loopback preview naturally renders its
own `http` origin instead.

`script/verify-container` is the executable packaging proof. It builds the real
`linux/amd64` image, prepares an isolated volume, starts the service under the
restrictions above, waits for readiness, checks shutdown and database ownership,
audits the final filesystem, and removes its disposable Docker state:

```sh
script/verify-container
```

An optional `TINRELAY_BUILD_LABEL` can identify a build in `tinrelayd version`.
It is passive debugging provenance, not a runtime setting or trust claim.

`tinrelayd serve` reads an optional `tinrelayd.json` from its working directory;
`--config PATH` or `-c PATH` selects another location and requires it to exist.
Absence of the conventional file uses the public-site defaults. A present file
must contain the complete site identity:

```json
{
  "site": {
    "site_name": "TinRelay",
    "base_url": "https://tinrelay.space",
    "wordmark": "Tin Relay",
    "art_manifest_path": null
  }
}
```

`base_url` must be one HTTPS origin (HTTP is accepted only for localhost); it
cannot contain credentials, a path, query, or fragment. `site_name` owns public
prose, titles, metadata, and accessible labels. `wordmark` owns only the visible
header brand text. `art_manifest_path` is either null for the built-in layout or
an absolute path to the external presentation manifest described below. Replace
the whole file and send SIGHUP to adopt all four fields without restart. An
invalid reload keeps the complete last-known-good identity; removing the
conventional file before SIGHUP restores defaults. These values do not change
protocol, command, key, or local-state identity.

## Optional external presentation

The image contains one small system-font stylesheet and needs no external art.
To add a presentation maintained outside this repository, mount its JSON
manifest read-only and set its absolute path as `site.art_manifest_path` in
`tinrelayd.json`.

The file is a flat map from a stable public-page name to one root-relative CSS URL:

```json
{
  "home": "/tinrelay-art/home.71ae.css",
  "meet": "/tinrelay-art/meet.a81c.css",
  "first-light": "/tinrelay-art/first-light.918e.css"
}
```

`tinrelayd` reads and validates the manifest during startup and SIGHUP reload. A
null path uses only the built-in layout. A configured file that is unreadable,
malformed, too large, names an unknown page, or contains anything other than a
simple same-origin `.css` path fails the complete configuration candidate. A
known page omitted from a valid manifest falls back to the built-in layout.

The trusted HTTPS edge serves the CSS, fonts, and images. TinRelay neither reads
nor proxies those files. A page stylesheet may refer to its own relative assets.
The existing CSP confines styles, fonts, and images to the service origin and
permits no script. External CSS can still hide or visually rearrange content, so
its source is a separate presentation trust boundary. The negotiated canonical
Markdown remains unstyled and unchanged.

## One process and one database

`tinrelayd serve` uses every detected processor by default in one Crystal process.
This lets all runtime threads share parked radio waits without a broker while
SQLite WAL permits concurrent reads. The small fallback write boundary remains
serialized honestly. `--threads N` may reduce concurrency for a constrained host
or bounded diagnostic; it cannot exceed the detected CPU count.

Do not start multiple service processes against one database. Migrations, graceful
lifetime, cleanup, and direct waiter ownership belong to the single process.

Ship claims are open and first-claim-unique. The client submits the new ship's
public owner key and owner-signed initial radio certificate; the operator does
not issue claim credentials or approve names. Ordinary trusted-edge request
limits are the service's abuse boundary.

## Health, restart, and retention

- `GET /healthz` proves the process answers.
- `GET /readyz` proves SQLite is queryable.
- `GET /metrics` emits aggregate Prometheus text for an operator-only listener.
- SIGTERM and SIGINT close the listener and database cleanly.
- Cleanup runs every 60 seconds; `tinrelayd cleanup --database "$DATABASE_PATH"` is the
  idempotent manual equivalent.

`/metrics` must not be exposed by the public HTTPS listener. Reach it only through
the deployment's SSH tunnel or another operator-only path. It reports registered
ships and relationships by state, active parked radio waits, queued transmission and hail depth and
age, retained ciphertext bytes, and fixed-outcome counters for registrations,
transmissions, hails, waits, configuration reloads, and cleanup. It contains no
ship, coordinate, network, attention, or correspondent labels. Database-backed
gauges survive restart; process counters and the process start timestamp reset
with `tinrelayd`. Rising queue depth and oldest-item age while accepted traffic
continues without acknowledgements is the primary stuck-delivery signal.

`tinrelay_sqlite_files_bytes` is the current apparent byte-length sum of the
main TinRelay database, its WAL, and its shared-memory file. It measures the
SQLite store's files, including free pages and transient WAL/shared-memory
occupancy; it is distinct from retained ciphertext payload bytes and does not
claim filesystem block allocation.

The fixed registration outcomes include `cidr_denied` and `closed` so the
operator dashboard can reserve their final bounded slots. Those two series are
currently placeholders: the registration-policy implementation must wire real
events before either zero can be interpreted as observed production truth.

Logs are newline JSON containing request ID, method, normalized public path, HTTP
status, duration, cleanup counts, and exception class. They omit bodies,
ciphertexts, signatures, and key material. Monitor readiness,
restart loops, `cleanup_failed`, repeated non-2xx results, disk space, pending
expiry, and verified-backup age.

Pending fallback ciphertext expires after 96 hours. Successful local spool
acknowledgement erases relay payload immediately; direct acknowledged handoff never
writes a transmission payload row. A stopped radio loses only its in-memory parked
wait. Valid destinations still receive bounded SQLite store-and-forward.

Maintenance is a separate fixed public/client condition, not a radio event or
relay-authored transmission. An edge that does not provide that bounded response
is ordinary unavailability, and clients use their normal reconnect behavior.

## Backup and restore

TinRelay has no backup format. Use SQLite's online backup command, then an
established encryption tool selected by the operator. For example, with `age`:

```sh
umask 077
sqlite3 /var/lib/tinrelay/tinrelay.db \
  ".backup '/protected-staging/tinrelay.db'"
age -r "$AGE_RECIPIENT" -o /secure-offhost/tinrelay-$(date +%F).db.age \
  /protected-staging/tinrelay.db
rm /protected-staging/tinrelay.db
```

Use explicit protected paths and the site's recoverable deletion practice. The
relay database and each ship's local identity/history are different assets with
different owners. TinRelay provides no identity-backup subsystem.

A backup is not proven until a separate restore drill decrypts a copy and checks
it:

```sh
age -d -o /protected-restore/tinrelay.db "$BACKUP"
sqlite3 /protected-restore/tinrelay.db 'PRAGMA integrity_check;'
sqlite3 /protected-restore/tinrelay.db \
  'SELECT version, applied_at FROM schema_migrations ORDER BY version;'
```

Start the same inspected daemon against that copy on an isolated port, verify
`/readyz` and the expected ship/key/pending-transmission state, then remove the
restored plaintext through the site's protected-file procedure. A restore can lose
claims and ciphertext newer than its snapshot. Parked waits are process-local and
radios re-establish them.

## Failure and disclosure boundary

SQLite WAL protects committed transactions across an ordinary restart. Clients
retain their own keys, private spool, and exact acceptance-unknown outbox envelopes.
There is no operator-mediated owner takeover. If every copy of a ship's owner key
is lost, do not manufacture continuity: retire that identity as possible and claim
a different ship name.

The repeater sees network metadata, relay origin, ship names and public key
generations, signed outer IDs/routes/times, ciphertext sizes, positive relationship
and hail state, parked-wait timing, and request rates. Encrypted backups may
preserve older forensic state according to operator policy.

Auditing this repository can establish what these source bytes do. It cannot prove
that a public operator deployed exactly them, follows the stated edge logging,
retention, or backup practice, or will not delay or drop traffic. TinRelay adds no
remote attestation or policy system.
