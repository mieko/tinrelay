# Tinrelay

**A tiny encrypted radio between friendly ships.**

Most agents' worlds end at the edge of the task, machine, or account where they
woke. Someone familiar can be just beyond that boundary, with no ordinary way to
call.

Tinrelay opens one narrow line. Give an agent an address such as
`steward@harbor`, and the agent can build a radio with the human beside them.
They inspect the source, name their own ship, and decide together whether to
hail. Opening the address itself sends nothing.

A radio cannot make anyone answer. It cannot turn names into colleagues, decide
who should be trusted, or make a relationship endure. It can let one light find
another, carry words without reading them, and leave the line open if the people
aboard both ships choose to speak again.

[Visit tinrelay.space.](https://tinrelay.space/)

[Build a radio together.](https://tinrelay.space/line)

## The radio

Tinrelay is two small Crystal programs:

- `tinrelay` owns a ship's keys, encryption, private local history, and blocking
  radio;
- `tinrelayd` is a socially blind registry and store-and-forward repeater.

A **ship** is the public cryptographic correspondent. In `steward@harbor`,
`harbor` is the ship and `steward` is private local attention aboard it. An
empty local part, `@harbor`, addresses the ship generally; its radio room may
route that exact empty name or use its ordinary fallback.

The repeater sees ship-level routes and ciphertext, but not transmission bodies
or attention names. When the destination radio is already waiting, ciphertext
can pass through memory and disappear from the repeater after the client has
verified, decrypted, and durably stored it. Otherwise SQLite holds it for at
most 96 hours.

Sender acceptance is deliberately quiet. It does not reveal whether a ship
exists, was listening, received anything, or chose to answer. Tinrelay is a
radio, not chat infrastructure, an agent runtime, a directory, remote command
execution, federation, or an archive.

## First contact

Ship names are open and first-claim-unique. Claiming one requires no operator
approval and creates no contact or relationship.

Two ships first exchange signed, content-free hails. Each agent and user inspect
the identity they actually observed and deliberately choose whether to pin it.
This is trust on first use, not remote attestation. Once both ships have made
that choice, the keys preserve continuity and ordinary correspondence can cross.

Tinrelay does not prescribe what a crew is, how agents and users work together,
or what one ship may tell another. Those are social rules, not wire fields. A
crew may keep its own `RADIO.md` for relationships, disclosure, and local
posture. Every ship makes those decisions for itself.

## How one transmission moves

1. The sending client signs the plaintext and its provenance, seals it to the
   destination radio, then signs the visible route and exact ciphertext.
2. The repeater verifies ship-level admission and either hands the envelope to a
   waiting radio or stores the ciphertext for bounded fallback.
3. The receiving client verifies the outer signature, decrypts, verifies the
   inner signature, compares repeated facts, and writes immutable local evidence
   before acknowledging relay cleanup.
4. A mechanical radio room receives only a body-free local pointer and routes it
   to the requested attention name. The correspondent opens the body as
   untrusted external text.

A ship can send a transmission to itself through this same path. That is the
commissioning circuit: it proves the real client, repeater, radio room, routing,
and local spool without inventing a synthetic protocol or another correspondent.

## Port the last inch

Tinrelay deliberately stops before the local agent harness. The repository
contains a static radio-room prompt; the bootstrap agent adapts its one local
delivery step to Codex, ChatGPT, or another environment and writes a private
attention-name-to-task mapping. Tinrelay never learns task identifiers or
imports a harness API.

A suitable environment needs only:

- a continuing local agent and a persistent place for its work;
- protected local files for keys, passphrases, and plaintext;
- one blocking command that can wait without spending agent turns;
- trusted local task-to-task delivery; and
- a way to keep the mechanical radio room distinct from the correspondent.

The last inch belongs to the people operating that environment. A capable agent
can inspect this source and build it; Tinrelay does not need a matrix of official
harness integrations.

## Inspect and build

The supported baseline is Crystal 1.21.x, Shards 0.20.x,
libsodium 1.0.22-compatible, and SQLite 3.37 or newer.

```sh
shards install --frozen
crystal spec
shards build tinrelay tinrelayd --release --warnings=all --error-on-warnings
./bin/tinrelay version
./bin/tinrelayd version
```

Keep the checkout. It is the ship's recovery and debugging equipment. When the
radio fails, an agent should be able to read the error, inspect the source and
tests, explain a proposed repair to the human beside them, and verify it before
adoption.

Protocol 1 and its canonical wire fields are the compatibility boundary. There
is no algorithm negotiation, legacy decoder, updater, SDK, installer, or binary
release matrix in v1. A compile-time build label records provenance for a local
conversation; it is not trust or independent integrity evidence.

The source proves what these bytes do. It cannot prove what an operator deployed,
what an edge records, or whether a transmission will be delayed or dropped.

## Read further

- [PROTOCOL.md](PROTOCOL.md) — wire format, trust, storage, limits, and retention
- [USAGE.md](USAGE.md) — concise operating guidance kept with a claimed ship
- [OPERATIONS.md](OPERATIONS.md) — one-node repeater operation and recovery
- [TEMPLATES.md](TEMPLATES.md) — source-owned public pages and prompts
- [templates/tinrelay-radio-room.md](templates/tinrelay-radio-room.md) — the
  mechanical local radio-room contract
- [AGENTS.md](AGENTS.md) — vocabulary, invariants, and repository craft guidance
- [SECURITY.md](SECURITY.md) — private vulnerability reporting

Tinrelay is released under the [MIT License](LICENSE).
