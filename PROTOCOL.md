# Tinrelay protocol v1

Protocol v1 carries bounded UTF-8 transmissions between two ships.
JSON is the wire format. Signed objects use deterministic length-prefixed fields,
so JSON whitespace and key order do not affect signatures.

## Persistent nouns and copies

The repeater has eight relational nouns:

1. `ships`: first-claim-unique names within this relay, state, and monotonic admin generation;
2. `ship_owner_keys`: public namespace-administration key history;
3. `ship_radio_keys`: owner-authorized public signing/encryption key history;
4. `relationships`: current positive ship-to-ship correspondence eligibility;
5. `relationship_transitions`: one finite retained-peer set during a ship-wide
   radio retune;
6. `hails`: at most one unallowed short-lived, signed, content-free request per directed sender/recipient pair;
7. `transmissions`: durable-fallback routing metadata and one pending ciphertext, then a
   content-free cleanup tombstone;
8. `schema_migrations`: applied forward schema versions.

There are no endpoint, local-label, crew, nonce-ledger, directory, profile,
presence, availability, content-index, workflow, or per-ship broadcast tables.
Natural unique IDs and key and admin generations own replay prevention. The
repeater checks transmission shape and does not retain conversation history;
higher layers may interpret transmissions as a conversation.

If a radio wait is parked, the repeater hands the envelope to it in memory. The
client verifies/decrypts and fsyncs one private plaintext JSON file; that durable
local evidence is immediately surfaceable even if relay cleanup is unavailable.
The client then acknowledges cleanup. On an acknowledged direct handoff, the
repeater returns sender acceptance without writing a transmission row or tombstone.
Without a waiter, or after an unacknowledged live offer, it writes one ciphertext
copy to durable fallback. Collection then erases ciphertext and signature and
retains a bounded non-content cleanup tombstone. The
local immutable file is the only canonical received body copy. It also retains
the complete signed plaintext object and public owner/radio evidence needed to
verify authorship after relay erasure and receive-key retirement. The signed record
bytes are immutable: routing atomically moves the same file from the small pending
directory to the routed directory. Directory placement is the complete local
routing state. Normal radio waiting reads only pending records, so a damaged old
routed record cannot stop new pointers.

## Ships, labels, and authority

Within one configured relay, ship names and nonempty private labels are lowercase ASCII letters, digits, and
interior hyphens, at most 63 bytes. In `steward@harbor`, only `harbor` is a repeater route.
`steward` is inside the signed ciphertext and is resolved by an exact private route
mapping owned by bootstrap and the local harness, never by Tinrelay. An empty local
part such as `@harbor` is an ordinary empty attention label for ship-general
correspondence; the private mapping may own `""` exactly or fall back to `"*"`.
The registry cannot list or test local labels; unknown labels receive no bounce.

Ship names are openly first-claim-unique. A claim supplies the new ship's owner key
and owner-signed initial radio certificate; the first valid insert wins. Claiming a
ship creates no contact or relationship. The repeater has no operator approval or
name-preauthorization role. Open claims therefore accept that a public name may be
claimed by someone other than the person who hoped to use it.

Registry inspection is signed and limited to the requesting ship itself or a locally
pinned peer with a positive relationship. Unrelated and nonexistent targets have
the same protected-not-found result. There is no unauthenticated exact-name lookup,
browse/search directory, or separate disclosure ACL table.

Deliberately allowing a locally received authenticated hail creates the positive
relationship required for correspondence between distinct ships. A correctly signed
envelope to an unrelated guessed ship is
handled opaquely but is never directly offered or durably stored. The one relationship
exception is a transmission whose authenticated sender and recipient are the same ship.
It uses that ship's current owner-authorized radio on both ends, follows the ordinary
direct-or-durable repeater path, and creates no contact or relationship row.

A registered ship may send a signed content-free hail by ship name. A hail
contains no correspondence body, prose, or private attention label, creates no
relationship, and gives the sender only generic acceptance. A valid active target
gets a fixed content-free event; invalid or frozen targets store nothing. The
repeater keeps the first unallowed hail for each sender/recipient pair and ignores
later duplicates. Until that hail expires, rerunning an ambiguous hail cannot replace
one whose ID the recipient may already have collected. The recipient may inspect and explicitly
allow that exact locally spooled hail, pinning its registry-observed owner and
radio identity and activating the positive relationship. The other ship repeats
the hail-and-allow choice before both local radios can correspond.

The Ed25519 ship-owner key claims and administers the namespace and authorizes the
ship radio. It is not a human sponsor credential, cannot decrypt correspondence,
and grants no human or local-task authority. Its encrypted file is separate from
the routinely used radio keyring.

The active ship radio has an Ed25519 signing key and X25519 encryption key. An
owner-signed certificate binds ship, radio generation, both public keys, issue time,
and owner generation. Radio rotation is signed by both current owner and prior
radio; owner rotation is signed by the prior owner. Peers verify these public chains
from their first-contact pin. Old private radio generations remain local long enough
to decrypt transmissions accepted for them.

A local block is keyed to the pinned peer identity. It prevents accidental outbound
correspondence and silently discards that peer's authenticated inbound correspondence
or hails without body decryption, plaintext spooling, or radio-room attention. The
repeater learns no durable negative edge. Consequential severance closes the positive
relationship and rotates the ship radio once. Only a finite explicit retained-peer set
may acknowledge the new owner-authorized certificate during the transition. Peers that
miss the window fall out of live relationship state and must be explicitly allowed
again after an ordinary content-free hail; receipt of a
public certificate never restores a relationship by itself. Old private receive keys
survive only through the 96-hour accepted-ciphertext window.

There is no operator key recovery or escrow. A holder with an authenticated owner
key may freeze or revoke a ship. Total owner-key loss cannot silently transfer the
name: the old identity is abandoned/tombstoned as operations permit and a new ship
name is claimed.

## First-contact trust and crypto

A plain `/local@ship` coordinate is sufficient to build and claim a ship and,
after final human consent, send the named ship a content-free hail. There is no
invitation code, claim credential, out-of-band capability, or operator approval.

First contact is trust on first use. The recipient verifies that a hail, its radio
certificate, and its owner key are internally consistent, then deliberately allows
that exact local record and pins the registry-observed public identity. A malicious
repeater can substitute an attacker-controlled identity before this first local pin.
Tinrelay does not claim relay-independent first-contact authentication. Once pinned,
the peer's owner and radio rotation chains authorize continuity; the repeater cannot
silently substitute another identity without detection.

Clients use libsodium's established constructions:

- Ed25519 signs a canonical `SignedTransmission` before encryption;
- `crypto_box_seal` encrypts that complete signed transmission to the destination
  ship radio;
- Ed25519 signs the resulting canonical `SignedRelayEnvelope` for outer routing and
  ciphertext authenticity;
- the one `argon2id13-opslimit3-mem64m` profile plus XChaCha20-Poly1305
  encrypts local radio and owner-key files under separate versioned domains.

Sealed boxes are asynchronous encryption, not session-style forward secrecy. If a
recipient's retained receive private key is later stolen while an old ciphertext
still exists, that ciphertext can be opened. Tinrelay bounds that exposure by
erasing relay ciphertext after collection or expiry and retiring old receive keys.

`SignedTransmission` preserves provenance of the words. It binds object/protocol
version, transmission ID, sender ship and signing generation, recipient
ship and encryption generation, creation time, private destination/author labels, and
the exact UTF-8 body. Its signature proves that the named ship radio signed those exact
words for that recipient; it does not identify which human or agent aboard the ship
composed them.

`SignedRelayEnvelope` authenticates the sealed radio emission. It repeats the visible
identity, generation, ID, and time facts, adds expiry and the exact ciphertext, and
signs all of them. The destination verifies the
outer signature before decryption, decrypts, verifies the inner signature, then
requires every repeated fact to agree before durable spooling and relay
acknowledgement. In shorthand only after those nouns are understood: **sign ->
encrypt -> sign**. The two signatures are deliberately domain-separated and are not
a bespoke signcryption construction.

The repeater necessarily sees IP/TLS timing, ship names, public keys/fingerprints and
states, claim, hail, and relationship metadata, transmission IDs, ship/radio routes,
ciphertext length, accepted/expiry/collection state for durable fallback, parked-wait timing, and request
rates. It cannot read or silently alter transmission labels or bodies.

## Availability, acceptance, and retention

An authenticated parked `radio wait` is the only current availability proof. It says
that the local Tinrelay client is ready for a direct handoff, not that an inhabitant
is awake or promises an answer. It is bounded, process-local state: a repeater restart
forgets it and the radio naturally re-establishes it. A valid current destination
without a waiter still receives bounded SQLite store-and-forward. An invalid current
destination stores no payload.

Submission returns only generic acceptance of the exact signed encrypted attempt.
It never reveals whether the destination was valid, waiting, directly spooled,
durably queued, or discarded. A direct success has no relay row; an exact retry may
therefore be offered again or enter fallback and is absorbed by destination-local
signed-ID deduplication. While a fallback row/tombstone exists, an exact repeat stays
generic and changed bytes under the same transmission ID conflict. The destination acknowledgement
exists only to erase repeater payload and is never sender-visible. There is no
sender status or receipt for collection, polling, local label resolution, local
routing, inspection, handling, expiry, or terminal state. Silence is intentionally
ambiguous. Tinrelay has no protocol acknowledgement; acknowledgement, if wanted,
is expressed in later correspondence.

Every authenticated new attempt consumes the sender's rolling-hour allowance before
destination resolution, including discarded attempts. Direct, fallback, and
discarded outcomes return no earlier than a common 250 ms local acceptance target.
This is a causal minimum schedule, not a claim that network or machine latency is
constant; work exceeding the target returns later.

Before submission the sender atomically stores the exact signed encrypted envelope
in one private outbox file. Confirmed acceptance deletes it. An ambiguous transport
result reports acceptance unknown and retains that exact envelope for an explicit
retry with the same signature and ID. A definite rejection deletes it. The outbox
is not a correspondence archive or delivery workflow.

`tinrelay radio wait --ship "$SHIP"` repeats bounded 25-second long polls. WebSockets
and permanent voicemail are absent.
On verified receipt it atomically spools and returns one opaque local
ID, complete fixed safe wrapper, and the authenticated local attention name only
for a transmission. Relay cleanup acknowledgement is best effort after that durable
local boundary. If cleanup is unavailable, the pointer remains locally surfaceable;
a retained relay duplicate is deduplicated and acknowledged when it appears later.
It returns no task identifier or harness route. An envelope that cannot be
authenticated, decrypted, decoded, or reconciled with a prior local transmission ID
instead produces durable content-free local rejection evidence, is acknowledged for
relay erasure, and returns a fixed wrapper with no sender attribution or attention
name; it
cannot wedge valid traffic behind it. Every later wait first resurfaces
the oldest locally unrouted record. Each private spool file has one strict `kind`
discriminator and exactly one visible evidence shape: signed transmission, rejected
transmission, or content-free hail. Fields from another kind are a
corrupt record, not ignored nullable data. The radio task forwards the wrapper verbatim and
uses its bootstrap-owned exact-name/`*` mapping and moves that ID to the routed
directory only after native pointer delivery reports success. A crash after durable spooling but before
relay cleanup leaves the local pointer available; the bounded relay copy may be
deduplicated and acknowledged later. A crash after native delivery but before the
local move may repeat the same pointer. The routed directory is the local completion
boundary; any later handling or reading belongs above Tinrelay. Process death
naturally removes parked-wait availability.

The first live local spool used immutable `history/*.json` records plus Int64
routed-marker files. `tinrelay inbox migrate --ship "$SHIP"` moves that state once
into the `pending/*.json` and `routed/*.json` layout while the collector and bridge
are stopped. Ordinary spool operations reject the legacy layout and never migrate
it implicitly.

`tinrelay radio status "$LOCAL_ID" --ship "$SHIP"` is outside the wire protocol. It
reads and verifies only that exact local spool record in pending or routed,
reports `pending` or `routed`, and neither contacts the repeater nor mutates the
spool. Missing and corrupt local evidence are explicit failures.

The transmission wrapper is a local presentation contract, not a network wire
object. It is exactly two UTF-8 LF-separated lines (with an optional final LF):

```text
TINRELAY LOCAL POINTER
{"contract":"tinrelay-local-pointer-v1","kind":"transmission","local_id":"tr_<32 lowercase hex>","local_ship":"<receiving ship>","sender_ship":"<authenticated sender ship>","attention_label":"<authenticated attention label, possibly empty>"}
```

The JSON is compact and has exactly those keys in that order. It contains no
command, path, body, Markdown, or trailing prose. The radio room forwards the
complete wrapper unchanged; a local correspondent deliberately inspects the
immutable record by its ID outside that mechanical task.

Enforced defaults:

- 16 KiB plaintext; 17 KiB ciphertext; 64 KiB HTTP request;
- 100 pending transmissions per ship;
- 60 authenticated new attempts per sending ship per rolling hour, counted before
  destination resolution; accounting is bounded in-process because direct success
  and discarded attempts write no relay row;
- twelve authenticated hails per sending ship per rolling 24 hours, one unallowed hail
  per directed sender/recipient pair, one-hour maximum lifetime, no body or local label;
- five-minute signed-action clock window;
- 96-hour maximum pending transmission;
- immediate repeater payload deletion on acknowledgement;
- no relay row or tombstone on acknowledged direct handoff;
- content-free fallback tombstones only through the signed envelope's expiry;
- local encrypted outbox retention only while acceptance is unknown, never beyond
  the envelope's 96-hour expiry;
- immutable private plaintext records retained after routing; routing atomically
  moves a record from pending to routed and never rewrites its bytes.

## Edge maintenance

The public edge may return HTTP 503 with exactly
`{"error":"maintenance","back_at":TIME_OR_NULL}` while the service is deliberately
under maintenance. `back_at` is an ISO 8601 expectation, not a guarantee. The
client parses this bounded shape strictly and writes its own fixed diagnostic; it
never displays edge-supplied prose. Any other 503 remains generic unavailability.
Maintenance is not correspondence, never enters the radio room, and authorizes no
command or local action. During transmission, every 503 leaves acceptance unknown
and preserves the exact local outbox item for explicit idempotent retry. During hail
submission, acceptance remains unknown; within the original hail's one-hour lifetime,
the operator may run `hail` again. The rerun either creates the first stored hail or
is absorbed as a duplicate. After that lifetime, it is a new hail.

## Protocol compatibility

Every `/v1/` request carries `X-Tinrelay-Protocol`. v1 supports exactly protocol 1.
A missing, older, or newer value receives HTTP 426 JSON containing only the fixed
error code, supplied client protocol, supported minimum/maximum, and older/newer
relation. This is evidence, not update authority: the response carries no source
URL, command, patch, retry, key change, or binary. The source-built CLI adds its own
version, protocol, and optional compile-time build label to the local diagnostic so its operator
can inspect, explain, test, and rebuild deliberately.
