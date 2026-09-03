CREATE TABLE ships (
  name TEXT PRIMARY KEY,
  claimed_at INTEGER NOT NULL,
  state TEXT NOT NULL CHECK (state IN ('active', 'frozen', 'revoked')),
  admin_generation INTEGER NOT NULL DEFAULT 0
) STRICT;

CREATE TABLE ship_owner_keys (
  ship TEXT NOT NULL REFERENCES ships(name),
  generation INTEGER NOT NULL,
  public_key BLOB NOT NULL,
  state TEXT NOT NULL CHECK (state IN ('active', 'rotated', 'revoked')),
  valid_from INTEGER NOT NULL,
  revoked_at INTEGER,
  authorization_signature BLOB,
  PRIMARY KEY (ship, generation)
) STRICT;

CREATE UNIQUE INDEX one_active_owner_key_per_ship
  ON ship_owner_keys(ship) WHERE state = 'active';

CREATE TABLE ship_radio_keys (
  ship TEXT NOT NULL REFERENCES ships(name),
  generation INTEGER NOT NULL,
  signing_public_key BLOB NOT NULL,
  encryption_public_key BLOB NOT NULL,
  state TEXT NOT NULL CHECK (state IN ('active', 'rotated', 'revoked')),
  issued_at INTEGER NOT NULL,
  owner_generation INTEGER NOT NULL,
  owner_signature BLOB NOT NULL,
  prior_radio_signature BLOB,
  revoked_at INTEGER,
  PRIMARY KEY (ship, generation),
  FOREIGN KEY (ship, owner_generation) REFERENCES ship_owner_keys(ship, generation)
) STRICT;

CREATE UNIQUE INDEX one_active_radio_key_per_ship
  ON ship_radio_keys(ship) WHERE state = 'active';

CREATE TABLE relationships (
  ship_a TEXT NOT NULL REFERENCES ships(name),
  ship_b TEXT NOT NULL REFERENCES ships(name),
  state TEXT NOT NULL CHECK (state IN ('active', 'transitioning')),
  transition_until INTEGER,
  PRIMARY KEY (ship_a, ship_b),
  CHECK (ship_a < ship_b)
) STRICT;

CREATE TABLE relationship_transitions (
  owner_ship TEXT NOT NULL REFERENCES ships(name),
  peer_ship TEXT NOT NULL REFERENCES ships(name),
  from_generation INTEGER NOT NULL,
  to_generation INTEGER NOT NULL,
  expires_at INTEGER NOT NULL,
  PRIMARY KEY (owner_ship, peer_ship),
  FOREIGN KEY (owner_ship, to_generation)
    REFERENCES ship_radio_keys(ship, generation)
) STRICT;

CREATE INDEX relationship_transitions_peer
  ON relationship_transitions(peer_ship, expires_at);

CREATE TABLE hails (
  id TEXT PRIMARY KEY,
  sender_ship TEXT NOT NULL,
  sender_signing_generation INTEGER NOT NULL,
  recipient_ship TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  expires_at INTEGER NOT NULL,
  signature BLOB NOT NULL,
  collected_at INTEGER,
  allowed_at INTEGER,
  FOREIGN KEY (sender_ship, sender_signing_generation)
    REFERENCES ship_radio_keys(ship, generation),
  FOREIGN KEY (recipient_ship) REFERENCES ships(name)
) STRICT;

CREATE INDEX hails_delivery ON hails(recipient_ship, created_at);
CREATE INDEX hails_expiry ON hails(expires_at);
CREATE UNIQUE INDEX one_pending_hail_per_pair
  ON hails(sender_ship, recipient_ship) WHERE allowed_at IS NULL;

CREATE TABLE transmissions (
  id TEXT PRIMARY KEY,
  thread_id TEXT NOT NULL,
  reply_to TEXT,
  sender_ship TEXT NOT NULL,
  sender_signing_generation INTEGER NOT NULL,
  recipient_ship TEXT NOT NULL,
  recipient_encryption_generation INTEGER NOT NULL,
  created_at INTEGER NOT NULL,
  expires_at INTEGER NOT NULL,
  accepted_at INTEGER NOT NULL,
  state TEXT NOT NULL CHECK (state IN ('pending', 'collected', 'expired')),
  ciphertext BLOB,
  signature BLOB,
  envelope_digest BLOB NOT NULL,
  FOREIGN KEY (sender_ship, sender_signing_generation) REFERENCES ship_radio_keys(ship, generation),
  FOREIGN KEY (recipient_ship, recipient_encryption_generation) REFERENCES ship_radio_keys(ship, generation)
) STRICT;

CREATE INDEX pending_delivery ON transmissions(recipient_ship, state, accepted_at);
CREATE INDEX transmissions_cleanup ON transmissions(state, expires_at);
