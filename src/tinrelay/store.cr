module Tinrelay
  class PreparedRelayEnvelope
    getter envelope : SignedRelayEnvelope
    getter ciphertext : Bytes
    getter signature : Bytes
    getter pairing_proof : Bytes?
    getter digest : Bytes
    getter accepted_at : Int64

    def initialize(@envelope, @ciphertext, @signature, @pairing_proof,
                   @digest, @accepted_at)
    end
  end

  class Store
    MAX_PENDING_PER_SHIP       = 100
    MAX_TRANSMISSIONS_PER_HOUR =  60
    MAX_HAILS_PER_DAY          =   3
    MAX_CIPHERTEXT_BYTES       = 17 * 1024
    MAX_PENDING_SECONDS        = FALLBACK_LIFETIME_SECONDS
    MAX_CAPABILITY_SECONDS     = 24 * 60 * 60
    AUTH_SKEW_SECONDS          = 5 * 60
    UUID                       = /\A[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/

    getter database : Database

    def initialize(@database)
      @fallback_write_mutex = Mutex.new
    end

    def claim(claim : ShipClaim, now : Int64 = Time.utc.to_unix,
              allow_bootstrap : Bool = false) : Nil
      ship = Names.ship!(claim.ship)
      certificate = claim.radio_certificate
      raise Invalid.new("claim ship and radio certificate differ") unless certificate.ship == ship
      raise Invalid.new("initial key generations must be 1") unless certificate.generation == 1 && certificate.owner_generation == 1
      owner_key = Crypto.unb64(claim.owner_public_key, "owner public key")
      unless Crypto.verify(certificate.unsigned_bytes, Crypto.unb64(certificate.owner_signature), owner_key)
        raise Unauthorized.new("initial radio certificate is not signed by the ship owner")
      end

      database.db.transaction do |transaction|
        connection = transaction.connection
        if allow_bootstrap
          raise Conflict.new("bootstrap claim is permanently closed") unless connection.scalar("SELECT COUNT(*) FROM ships").as(Int64) == 0
        else
          has_admission = !!claim.ship_claim_admission_id ||
                          !!claim.ship_claim_admission_secret
          raise Unauthorized.new("claim requires one ship admission") unless has_admission
          consume_admission(
            connection, claim.ship_claim_admission_id,
            claim.ship_claim_admission_secret, ship, now
          )
        end

        connection.exec(
          "INSERT INTO ships(name, claimed_at, state) VALUES (?, ?, 'active')",
          ship, now
        )
        connection.exec(
          <<-SQL, ship, owner_key, now
            INSERT INTO ship_owner_keys(
              ship, generation, public_key, state, valid_from
            ) VALUES (?, 1, ?, 'active', ?)
          SQL
        )
        insert_radio_key(connection, certificate)
      end
    rescue ex : SQLite3::Exception
      raise Conflict.new("ship name is already claimed") if ex.message.try(&.includes?("UNIQUE constraint failed: ships.name"))
      raise ex
    end

    def create_admission(id : String, ship : String, secret_hash : Bytes,
                         expires_at : Int64,
                         now : Int64 = Time.utc.to_unix) : Nil
      require_uuid!(id, "admission id")
      Names.ship!(ship)
      raise Invalid.new("invalid admission secret hash length") unless secret_hash.size == 32
      raise Invalid.new("admission expiry must be within 24 hours") unless expires_at.in?((now + 1)..(now + MAX_CAPABILITY_SECONDS))
      database.db.exec(
        "INSERT INTO admissions(id, ship, ship_claim_admission_secret_hash, expires_at) VALUES (?, ?, ?, ?)",
        id, ship, secret_hash, expires_at
      )
    rescue ex : SQLite3::Exception
      raise Conflict.new("admission id already exists") if ex.message.try(&.includes?("UNIQUE constraint failed"))
      raise ex
    end

    def revoke_admission(id : String, now : Int64 = Time.utc.to_unix) : Bool
      require_uuid!(id, "admission id")
      database.db.exec(
        "UPDATE admissions SET revoked_at = COALESCE(revoked_at, ?) WHERE id = ?",
        now, id
      ).rows_affected == 1
    end

    def create_invitation(request : InvitationCreate,
                          now : Int64 = Time.utc.to_unix) : Nil
      require_uuid!(request.id, "invitation id")
      raise Invalid.new("invitation expiry must be within 24 hours") unless request.expires_at.in?((now + 1)..(now + MAX_CAPABILITY_SECONDS))
      secret_hash = Crypto.unb64(
        request.relationship_admission_secret_hash,
        "relationship admission secret hash"
      )
      raise Invalid.new("invalid relationship admission secret hash length") unless secret_hash.size == 32
      database.db.transaction do |transaction|
        connection = transaction.connection
        verify_radio_action(connection, request.auth, "invitation.create", request.payload, now)
        connection.exec(
          "INSERT INTO invitations(id, created_by_ship, relationship_admission_secret_hash, expires_at) VALUES (?, ?, ?, ?)",
          request.id, request.auth.ship, secret_hash, request.expires_at
        )
      end
    rescue ex : SQLite3::Exception
      raise Conflict.new("invitation id already exists") if ex.message.try(&.includes?("UNIQUE constraint failed"))
      raise ex
    end

    def revoke_invitation(request : InvitationRevoke,
                          now : Int64 = Time.utc.to_unix) : Nil
      require_uuid!(request.id, "invitation id")
      database.db.transaction do |transaction|
        connection = transaction.connection
        verify_radio_action(connection, request.auth, "invitation.revoke", request.payload, now)
        owner = connection.query_one?("SELECT created_by_ship FROM invitations WHERE id = ?", request.id, as: String) ||
                raise NotFound.new("invitation not found")
        raise Unauthorized.new("invitation belongs to another ship") unless owner == request.auth.ship
        connection.exec("UPDATE invitations SET revoked_at = COALESCE(revoked_at, ?) WHERE id = ?", now, request.id)
      end
    end

    def accept_invitation(request : InvitationAccept,
                          now : Int64 = Time.utc.to_unix) : String
      require_uuid!(request.id, "invitation id")
      creator = database.db.transaction do |transaction|
        connection = transaction.connection
        verify_radio_action(connection, request.auth, "invitation.accept", request.payload, now)
        row = connection.query_one?(
          "SELECT created_by_ship, relationship_admission_secret_hash, expires_at, used_by_ship, revoked_at FROM invitations WHERE id = ?",
          request.id, as: {String, Bytes?, Int64, String?, Int64?}
        ) || raise Unauthorized.new("invitation is invalid")
        raise Expired.new("invitation expired") if row[2] <= now
        raise Unauthorized.new("invitation is invalid") if row[4]
        raise Invalid.new("a ship cannot accept its own invitation") if row[0] == request.auth.ship
        if used_by = row[3]
          raise Unauthorized.new("invitation is invalid") unless used_by == request.auth.ship
        else
          expected = row[1] || raise Unauthorized.new("invitation is invalid")
          supplied = Digest::SHA256.digest(Crypto.unb64(
            request.relationship_admission_secret,
            "relationship admission secret"
          ))
          unless Crypto.constant_time_equal?(expected, supplied)
            raise Unauthorized.new("invitation is invalid")
          end
          ship_a, ship_b = relationship_pair(row[0], request.auth.ship)
          connection.exec(
            <<-SQL, ship_a, ship_b
              INSERT INTO relationships(ship_a, ship_b, state)
              VALUES (?, ?, 'active')
              ON CONFLICT(ship_a, ship_b) DO UPDATE SET
                state = 'active', transition_until = NULL
            SQL
          )
          connection.exec(
            "UPDATE invitations SET used_at = ?, used_by_ship = ?, relationship_admission_secret_hash = NULL WHERE id = ? AND used_at IS NULL",
            now, request.auth.ship, request.id
          )
        end
        row[0]
      end.not_nil!
      ship_card_json(creator, now, include_admin: false)
    end

    def inspect_ship(request : ShipInspection,
                     now : Int64 = Time.utc.to_unix) : String
      target = Names.ship!(request.target_ship)
      requester = request.auth.ship
      visible = database.db.transaction do |transaction|
        connection = transaction.connection
        verify_radio_action(connection, request.auth, "ship.inspect", request.payload, now)
        exists = connection.query_one?(
          "SELECT 1 FROM ships WHERE name = ?", target, as: Int64
        )
        ship_a, ship_b = relationship_pair(requester, target)
        related = requester == target || connection.query_one?(
          "SELECT 1 FROM relationships WHERE ship_a = ? AND ship_b = ? AND state = 'active'",
          ship_a, ship_b, as: Int64
        )
        !!exists && !!related
      end.not_nil!
      raise NotFound.new("ship is not available to this radio") unless visible
      ship_card_json(target, now, include_admin: requester == target)
    end

    def prepare(envelope : SignedRelayEnvelope,
                now : Int64 = Time.utc.to_unix) : PreparedRelayEnvelope?
      validate_envelope_shape!(envelope)
      ciphertext = Crypto.unb64(envelope.ciphertext, "ciphertext")
      raise Invalid.new("ciphertext exceeds #{MAX_CIPHERTEXT_BYTES} bytes") if ciphertext.size > MAX_CIPHERTEXT_BYTES
      signature = Crypto.unb64(envelope.signature, "relay envelope signature")
      envelope_digest = Digest::SHA256.digest(envelope.signing_bytes + signature)
      pairing = envelope.pairing_proof.try { |value| Crypto.unb64(value, "pairing proof") }

      disposition = database.db.transaction do |transaction|
        connection = transaction.connection
        if connection.query_one?("SELECT 1 FROM transmissions WHERE id = ?", envelope.transmission_id, as: Int64)
          stored_digest = connection.query_one("SELECT envelope_digest FROM transmissions WHERE id = ?", envelope.transmission_id, as: Bytes)
          raise Conflict.new("transmission id was reused with different contents") unless Crypto.constant_time_equal?(stored_digest, envelope_digest)
          next :accepted
        end

        validate_new_envelope_time!(envelope, now)

        sender = authenticate_radio_signature(
          connection, envelope.sender_ship, envelope.sender_signing_generation,
          envelope.signing_bytes, signature
        )
        raise Unavailable.new("sender radio is not active") unless sender[2] == "active"
        sender_state = connection.query_one?(
          "SELECT state FROM ships WHERE name = ?", envelope.sender_ship, as: String
        ) || raise Unauthorized.new("sender ship is not registered")
        raise Unavailable.new("sender ship is not active") unless sender_state == "active"
        validate_thread_shape!(envelope)
        :new
      end.not_nil!
      return nil unless disposition == :new
      PreparedRelayEnvelope.new(
        envelope, ciphertext, signature, pairing, envelope_digest, now
      )
    end

    def prepare_hail(hail : Hail,
                     now : Int64 = Time.utc.to_unix) : Hail
      raise Invalid.new("unsupported protocol") unless hail.protocol == PROTOCOL
      require_uuid!(hail.hail_id, "hail id")
      Names.ship!(hail.sender_ship)
      Names.ship!(hail.recipient_ship)
      raise Invalid.new("a ship cannot hail itself") if hail.sender_ship == hail.recipient_ship
      raise Invalid.new("hail creation time is outside the authentication window") unless (hail.created_at - now).abs <= AUTH_SKEW_SECONDS
      raise Invalid.new("hail expiry must be within one hour") unless hail.expires_at.in?((now + 1)..(now + HAIL_LIFETIME_SECONDS))
      signature = Crypto.unb64(hail.signature, "hail signature")
      database.db.transaction do |transaction|
        connection = transaction.connection
        sender = authenticate_radio_signature(
          connection, hail.sender_ship, hail.sender_signing_generation,
          hail.signing_bytes, signature
        )
        raise Unavailable.new("sender radio is not active") unless sender[2] == "active"
        sender_state = connection.query_one?(
          "SELECT state FROM ships WHERE name = ?", hail.sender_ship, as: String
        ) || raise Unauthorized.new("sender ship is not registered")
        raise Unavailable.new("sender ship is not active") unless sender_state == "active"
      end
      hail
    end

    def persist_hail(hail : Hail) : Bool
      signature = Crypto.unb64(hail.signature, "hail signature")
      database.db.transaction do |transaction|
        connection = transaction.connection
        active = connection.query_one?(
          "SELECT 1 FROM ships WHERE name = ? AND state = 'active'",
          hail.recipient_ship, as: Int64
        )
        next false unless active
        sql = <<-SQL
            INSERT INTO hails(
              id, sender_ship, sender_signing_generation, recipient_ship,
              created_at, expires_at, signature
            ) VALUES (?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(sender_ship, recipient_ship) DO NOTHING
          SQL
        connection.exec(
          sql, hail.hail_id, hail.sender_ship,
          hail.sender_signing_generation, hail.recipient_ship,
          hail.created_at, hail.expires_at, signature
        ).rows_affected == 1
      end.not_nil!
    end

    def accept(envelope : SignedRelayEnvelope,
               now : Int64 = Time.utc.to_unix) : Nil
      prepared = prepare(envelope, now)
      persist(prepared) if prepared
    end

    def deliverable?(prepared : PreparedRelayEnvelope) : Bool
      database.db.transaction do |transaction|
        delivery_allowed?(transaction.connection, prepared.envelope, false)
      end.not_nil!
    end

    def persist(prepared : PreparedRelayEnvelope) : Bool
      # SQLite cannot reliably upgrade several concurrent read transactions into
      # writers. Serialize only the final durable-fallback transaction; public
      # rendering, verification, reads, and direct in-memory handoff stay concurrent.
      @fallback_write_mutex.synchronize do
        database.db.transaction do |transaction|
          connection = transaction.connection
          if stored_digest = connection.query_one?(
               "SELECT envelope_digest FROM transmissions WHERE id = ?",
               prepared.envelope.transmission_id, as: Bytes
             )
            unless Crypto.constant_time_equal?(stored_digest, prepared.digest)
              raise Conflict.new("transmission id was reused with different contents")
            end
            next true
          end
          next false unless delivery_allowed?(connection, prepared.envelope, true)
          insert_transmission(connection, prepared)
          true
        end
      end.not_nil!
    end

    def wait_once(request : RadioWaitRequest,
                  now : Int64 = Time.utc.to_unix) : RadioWaitResponse
      raise Invalid.new("wait hold must be between 0 and 25 seconds") unless request.hold_seconds.in?(0..25)
      database.db.transaction do |transaction|
        connection = transaction.connection
        verify_radio_action(connection, request.auth, "radio.wait", request.payload, now)
        updates = contact_updates(
          connection, request.auth.ship, request.known_contact_generations, now
        )
        next RadioWaitResponse.new(contact_updates: updates) unless updates.empty?
        hail = pending_hail(
          connection, request.auth.ship, request.known_contact_generations, now
        )
        next RadioWaitResponse.new(hail: hail) if hail
        envelope = pending_envelope(connection, request.auth.ship, now)
        RadioWaitResponse.new(envelope: envelope)
      end.not_nil!
    end

    def acknowledge(request : TransmissionAck,
                    now : Int64 = Time.utc.to_unix) : Nil
      require_uuid!(request.transmission_id, "transmission id")
      database.db.transaction do |transaction|
        connection = transaction.connection
        verify_radio_action(connection, request.auth, "transmission.ack", request.payload, now)
        row = connection.query_one?(
          "SELECT recipient_ship, state FROM transmissions WHERE id = ?",
          request.transmission_id, as: {String, String}
        )
        # A successful direct handoff has no relay row. Treat its later ack retry,
        # an already-cleaned fallback, and an unrelated opaque ID identically.
        if row && row[0] == request.auth.ship && row[1] == "pending"
          erase_payload(connection, request.transmission_id, now)
        end
      end
    end

    def verify_ack(request : TransmissionAck,
                   now : Int64 = Time.utc.to_unix) : Nil
      require_uuid!(request.transmission_id, "transmission id")
      database.db.transaction do |transaction|
        verify_radio_action(
          transaction.connection, request.auth, "transmission.ack", request.payload, now
        )
      end
    end

    def acknowledge_hail(request : HailAck,
                         now : Int64 = Time.utc.to_unix) : Nil
      require_uuid!(request.hail_id, "hail id")
      database.db.transaction do |transaction|
        connection = transaction.connection
        verify_radio_action(connection, request.auth, "hail.ack", request.payload, now)
        connection.exec(
          "UPDATE hails SET collected_at = COALESCE(collected_at, ?) WHERE id = ? AND recipient_ship = ?",
          now, request.hail_id, request.auth.ship
        )
      end
    end

    private def ship_card_json(ship : String, now : Int64,
                               include_admin : Bool) : String
      ship_row = database.db.query_one?(
        "SELECT claimed_at, state, admin_generation FROM ships WHERE name = ?",
        ship, as: {Int64, String, Int64}
      ) || raise NotFound.new("ship is not available to this radio")
      JSON.build do |json|
        json.object do
          json.field "ship", ship
          json.field "claimed_at", ship_row[0]
          json.field "state", ship_row[1]
          if include_admin
            json.field "admin_generation", ship_row[2]
          end
          json.field "authority_notice", "ship namespace administration only; never human sponsor authority"
          json.field "owner_keys" { write_owner_keys(json, ship) }
          json.field "radio_keys" { write_radio_keys(json, ship) }
        end
      end
    end

    def close_relationship(request : RelationshipClose,
                           now : Int64 = Time.utc.to_unix) : Nil
      peer = Names.ship!(request.peer_ship)
      retained = request.retained_ships.map { |ship| Names.ship!(ship) }.uniq.sort
      raise Invalid.new("a ship cannot retain or close itself") if peer == request.auth.ship || retained.includes?(request.auth.ship)
      raise Invalid.new("closed peer cannot be retained") if retained.includes?(peer)
      certificate = request.certificate
      database.db.transaction do |transaction|
        connection = transaction.connection
        verify_owner_action(
          connection, request.auth, "relationship.close", request.payload, now
        )
        raise Invalid.new("radio certificate belongs to another ship") unless certificate.ship == request.auth.ship
        prior_generation = connection.scalar(
          "SELECT MAX(generation) FROM ship_radio_keys WHERE ship = ?",
          certificate.ship
        ).as(Int64).to_i
        raise Invalid.new("radio generation must advance by one") unless certificate.generation == prior_generation + 1
        verify_radio_certificate(connection, certificate)
        prior_key = radio_key(connection, certificate.ship, prior_generation)
        unless Crypto.verify(
                 certificate.unsigned_bytes,
                 Crypto.unb64(request.prior_radio_signature), prior_key[0]
               )
          raise Unauthorized.new("radio retune lacks the prior radio signature")
        end
        connection.exec(
          "UPDATE ship_radio_keys SET state = 'rotated', revoked_at = ? WHERE ship = ? AND state = 'active'",
          now, certificate.ship
        )
        insert_radio_key(connection, certificate, request.prior_radio_signature)
        target_a, target_b = relationship_pair(request.auth.ship, peer)
        unless connection.query_one?(
                 "SELECT 1 FROM relationships WHERE ship_a = ? AND ship_b = ? AND state = 'active'",
                 target_a, target_b, as: Int64
               )
          raise NotFound.new("active relationship not found")
        end
        deadline = now + MAX_PENDING_SECONDS
        active_peers = [] of String
        connection.query(
          "SELECT ship_a, ship_b FROM relationships WHERE state = 'active' AND (ship_a = ? OR ship_b = ?)",
          request.auth.ship, request.auth.ship
        ) do |rows|
          rows.each do
            ship_a, ship_b = rows.read(String, String)
            active_peers << (ship_a == request.auth.ship ? ship_b : ship_a)
          end
        end
        connection.exec(
          "UPDATE relationships SET state = 'transitioning', transition_until = ? WHERE state = 'active' AND (ship_a = ? OR ship_b = ?)",
          deadline, request.auth.ship, request.auth.ship
        )
        retained.each do |retained_ship|
          next unless active_peers.includes?(retained_ship)
          connection.exec(
            <<-SQL, request.auth.ship, retained_ship, prior_generation, certificate.generation, deadline
              INSERT INTO relationship_transitions(
                owner_ship, peer_ship, from_generation, to_generation, expires_at
              ) VALUES (?, ?, ?, ?, ?)
              ON CONFLICT(owner_ship, peer_ship) DO UPDATE SET
                from_generation = excluded.from_generation,
                to_generation = excluded.to_generation,
                expires_at = excluded.expires_at
            SQL
          )
        end
        advance_admin(connection, request.auth)
      end
    end

    def acknowledge_retune(request : RetuneAck,
                           now : Int64 = Time.utc.to_unix) : Nil
      owner_ship = Names.ship!(request.owner_ship)
      database.db.transaction do |transaction|
        connection = transaction.connection
        verify_radio_action(connection, request.auth, "relationship.retune.ack", request.payload, now)
        connection.query_one?(
          <<-SQL, owner_ship, request.auth.ship, request.to_generation, now,
            SELECT 1 FROM relationship_transitions
             WHERE owner_ship = ? AND peer_ship = ? AND to_generation = ?
               AND expires_at > ?
          SQL
          as: Int64
        ) || raise NotFound.new("retune transition is unavailable")
        ship_a, ship_b = relationship_pair(owner_ship, request.auth.ship)
        connection.exec(
          "UPDATE relationships SET state = 'active', transition_until = NULL WHERE ship_a = ? AND ship_b = ? AND state = 'transitioning'",
          ship_a, ship_b
        )
        connection.exec(
          "DELETE FROM relationship_transitions WHERE owner_ship = ? AND peer_ship = ?",
          owner_ship, request.auth.ship
        )
      end
    end

    def allow_relationship(request : RelationshipAllow,
                           now : Int64 = Time.utc.to_unix) : Nil
      peer = Names.ship!(request.peer_ship)
      require_uuid!(request.hail_id, "hail id")
      database.db.transaction do |transaction|
        connection = transaction.connection
        verify_radio_action(connection, request.auth, "relationship.allow", request.payload, now)
        connection.query_one?(
          <<-SQL, request.hail_id, peer, request.auth.ship, now,
            SELECT 1 FROM hails
             WHERE id = ? AND sender_ship = ? AND recipient_ship = ?
               AND collected_at IS NOT NULL AND expires_at > ?
          SQL
          as: Int64
        ) || raise NotFound.new("authenticated hail is unavailable")
        ship_a, ship_b = relationship_pair(request.auth.ship, peer)
        connection.exec(
          <<-SQL, ship_a, ship_b
              INSERT INTO relationships(ship_a, ship_b, state)
              VALUES (?, ?, 'active')
            ON CONFLICT(ship_a, ship_b) DO UPDATE SET
              state = 'active', transition_until = NULL
          SQL
        )
        connection.exec("DELETE FROM hails WHERE id = ?", request.hail_id)
      end
    end

    def rotate_owner(rotation : OwnerRotation,
                     now : Int64 = Time.utc.to_unix) : Nil
      database.db.transaction do |transaction|
        connection = transaction.connection
        verify_owner_action(connection, rotation.auth, "owner.rotate", rotation.payload, now)
        raise Invalid.new("owner generation must advance by one") unless rotation.new_generation == rotation.auth.owner_generation + 1
        new_key = Crypto.unb64(rotation.new_public_key, "new owner public key")
        old_key = owner_key(connection, rotation.auth.ship, rotation.auth.owner_generation)
        bytes = Canonical.fields("tinrelay-owner-rotation-v1", rotation.auth.ship, rotation.new_generation.to_s, rotation.new_public_key)
        unless Crypto.verify(bytes, Crypto.unb64(rotation.prior_signature), old_key)
          raise Unauthorized.new("owner rotation lacks the prior owner signature")
        end
        prior_signature = Crypto.unb64(rotation.prior_signature)
        connection.exec("UPDATE ship_owner_keys SET state = 'rotated', revoked_at = ? WHERE ship = ? AND state = 'active'", now, rotation.auth.ship)
        connection.exec(
          <<-SQL, rotation.auth.ship, rotation.new_generation, new_key, now, prior_signature
            INSERT INTO ship_owner_keys(
              ship, generation, public_key, state, valid_from,
              authorization_signature
            ) VALUES (?, ?, ?, 'active', ?, ?)
          SQL
        )
        advance_admin(connection, rotation.auth)
      end
    end

    def ship_change(change : ShipChange,
                    now : Int64 = Time.utc.to_unix) : Nil
      raise Invalid.new("ship operation must be freeze, activate, or revoke") unless change.operation.in?({"freeze", "activate", "revoke"})
      database.db.transaction do |transaction|
        connection = transaction.connection
        verify_owner_action(connection, change.auth, "ship.change", change.payload, now)
        current = connection.scalar("SELECT state FROM ships WHERE name = ?", change.auth.ship).as(String)
        raise Conflict.new("revoked ships cannot be reactivated") if current == "revoked"
        state = change.operation == "activate" ? "active" : change.operation == "revoke" ? "revoked" : "frozen"
        connection.exec(
          "UPDATE ships SET state = ? WHERE name = ?",
          state, change.auth.ship
        )
        if state == "revoked"
          connection.exec("UPDATE ship_owner_keys SET state = 'revoked', revoked_at = ? WHERE ship = ? AND state = 'active'", now, change.auth.ship)
          connection.exec("UPDATE ship_radio_keys SET state = 'revoked', revoked_at = ? WHERE ship = ? AND state = 'active'", now, change.auth.ship)
        end
        advance_admin(connection, change.auth)
      end
    end

    def cleanup(now : Int64 = Time.utc.to_unix)
      database.db.transaction do |transaction|
        connection = transaction.connection
        expired = connection.exec(
          <<-SQL, now
            UPDATE transmissions
               SET state = 'expired', ciphertext = NULL,
                   signature = NULL, pairing_proof = NULL, invitation_id = NULL
             WHERE state = 'pending' AND expires_at <= ?
          SQL
        ).rows_affected
        deleted = connection.exec(
          "DELETE FROM transmissions WHERE state != 'pending' AND expires_at <= ?", now
        ).rows_affected
        admissions_deleted = connection.exec(
          "DELETE FROM admissions WHERE used_at IS NOT NULL OR expires_at <= ? OR revoked_at IS NOT NULL",
          now
        ).rows_affected
        invitations_deleted = connection.exec(
          "DELETE FROM invitations WHERE (used_at IS NULL AND (expires_at <= ? OR revoked_at IS NOT NULL)) OR (used_at IS NOT NULL AND used_at <= ?)",
          now, now - MAX_PENDING_SECONDS
        ).rows_affected
        hails_deleted = connection.exec(
          "DELETE FROM hails WHERE expires_at <= ?", now
        ).rows_affected
        relationships_deleted = connection.exec(
          "DELETE FROM relationships WHERE state = 'transitioning' AND transition_until <= ?",
          now
        ).rows_affected
        transitions_deleted = connection.exec(
          "DELETE FROM relationship_transitions WHERE expires_at <= ?", now
        ).rows_affected
        {
          expired: expired, deleted: deleted,
          admissions_deleted: admissions_deleted,
          invitations_deleted: invitations_deleted,
          hails_deleted: hails_deleted,
          relationships_deleted: relationships_deleted,
          transitions_deleted: transitions_deleted,
        }
      end.not_nil!
    end

    private def validate_envelope_shape!(envelope : SignedRelayEnvelope) : Nil
      raise Invalid.new("unsupported signed relay envelope") unless envelope.object_version == 1 && envelope.protocol == PROTOCOL
      require_uuid!(envelope.transmission_id, "transmission id")
      require_uuid!(envelope.thread_id, "thread id")
      envelope.reply_to.try { |id| require_uuid!(id, "reply id") }
      Names.ship!(envelope.sender_ship)
      Names.ship!(envelope.recipient_ship)
    end

    private def validate_thread_shape!(envelope : SignedRelayEnvelope) : Nil
      unless envelope.reply_to
        raise Invalid.new("new transmission thread id must equal transmission id") unless envelope.thread_id == envelope.transmission_id
      end
    end

    private def validate_new_envelope_time!(envelope : SignedRelayEnvelope, now : Int64) : Nil
      raise Invalid.new("transmission creation time is outside the authentication window") unless (envelope.created_at - now).abs <= AUTH_SKEW_SECONDS
      raise Invalid.new("transmission expiry must be within 96 hours") unless envelope.expires_at.in?((now + 1)..(now + MAX_PENDING_SECONDS))
    end

    private def insert_transmission(connection : DB::Connection,
                                    prepared : PreparedRelayEnvelope) : Nil
      envelope = prepared.envelope
      connection.exec(
        <<-SQL,
          INSERT INTO transmissions(
            id, thread_id, reply_to, sender_ship, sender_signing_generation,
            recipient_ship, recipient_encryption_generation, created_at, expires_at,
            accepted_at, state, ciphertext, signature, invitation_id,
            pairing_proof, envelope_digest
          ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'pending', ?, ?, ?, ?, ?)
        SQL
        envelope.transmission_id, envelope.thread_id, envelope.reply_to,
        envelope.sender_ship, envelope.sender_signing_generation,
        envelope.recipient_ship, envelope.recipient_encryption_generation,
        envelope.created_at, envelope.expires_at, prepared.accepted_at,
        prepared.ciphertext, prepared.signature, envelope.invitation_id,
        prepared.pairing_proof, prepared.digest
      )
    end

    private def erase_payload(connection : DB::Connection, transmission_id : String,
                              now : Int64) : Nil
      connection.exec(
        <<-SQL, transmission_id
          UPDATE transmissions
             SET state = 'collected', ciphertext = NULL,
                 signature = NULL, pairing_proof = NULL, invitation_id = NULL
           WHERE id = ? AND state = 'pending'
        SQL
      )
    end

    private def consume_admission(connection : DB::Connection,
                                  id : String?, secret : String?, ship : String,
                                  now : Int64) : Nil
      capability_id = id || raise Unauthorized.new("admission id is required")
      supplied_secret = secret || raise Unauthorized.new("admission secret is required")
      require_uuid!(capability_id, "admission id")
      capability = connection.query_one?(
        "SELECT ship, ship_claim_admission_secret_hash, expires_at, used_at, revoked_at FROM admissions WHERE id = ?",
        capability_id, as: {String?, Bytes, Int64, Int64?, Int64?}
      ) || raise Unauthorized.new("admission is invalid")
      raise Unauthorized.new("admission is for another ship") unless capability[0] == ship
      raise Expired.new("admission expired") if capability[2] <= now
      raise Unauthorized.new("admission was revoked") if capability[4]
      raise Conflict.new("admission was already used") if capability[3]
      supplied_hash = Digest::SHA256.digest(Crypto.unb64(supplied_secret, "admission secret"))
      unless Crypto.constant_time_equal?(capability[1], supplied_hash)
        raise Unauthorized.new("admission is invalid")
      end
      connection.exec(
        "UPDATE admissions SET used_at = ? WHERE id = ? AND used_at IS NULL",
        now, capability_id
      )
    end

    private def delivery_allowed?(connection : DB::Connection,
                                  envelope : SignedRelayEnvelope,
                                  enforce_capacity : Bool) : Bool
      unless envelope.sender_ship == envelope.recipient_ship
        ship_a, ship_b = relationship_pair(
          envelope.sender_ship, envelope.recipient_ship
        )
        relationship = connection.query_one?(
          "SELECT 1 FROM relationships WHERE ship_a = ? AND ship_b = ? AND state = 'active'",
          ship_a, ship_b, as: Int64
        )
        return false unless relationship
      end

      recipient = begin
        radio_key(
          connection, envelope.recipient_ship,
          envelope.recipient_encryption_generation
        )
      rescue Unauthorized
        return false
      end
      return false unless recipient[2] == "active"
      destination_active = connection.query_one?(
        "SELECT 1 FROM ships WHERE name = ? AND state = 'active'",
        envelope.recipient_ship, as: Int64
      )
      return false unless destination_active
      return true unless enforce_capacity

      pending = connection.scalar(
        "SELECT COUNT(*) FROM transmissions WHERE recipient_ship = ? AND state = 'pending'",
        envelope.recipient_ship
      ).as(Int64)
      pending < MAX_PENDING_PER_SHIP
    end

    private def pending_envelope(connection : DB::Connection, ship : String,
                                 now : Int64) : SignedRelayEnvelope?
      row = connection.query_one?(
        <<-SQL, ship, now,
          SELECT id, thread_id, reply_to, sender_ship, sender_signing_generation,
                 recipient_encryption_generation, created_at, expires_at, ciphertext,
                 signature, invitation_id, pairing_proof
           FROM transmissions
           WHERE recipient_ship = ? AND state = 'pending' AND expires_at > ?
           ORDER BY accepted_at, rowid LIMIT 1
        SQL
        as: {String, String, String?, String, Int64, Int64, Int64, Int64,
             Bytes, Bytes, String?, Bytes?}
      )
      return nil unless row
      SignedRelayEnvelope.new(
        row[0], row[1], row[3], row[4].to_i, ship, row[5].to_i,
        row[6], row[7], Crypto.b64(row[8]), row[2], row[10],
        row[11].try { |proof| Crypto.b64(proof) }, Crypto.b64(row[9])
      )
    end

    private def pending_hail(connection : DB::Connection, ship : String,
                             known : Hash(String, Int32),
                             now : Int64) : HailDelivery?
      row = connection.query_one?(
        <<-SQL, ship, now,
          SELECT h.id, h.sender_ship, h.sender_signing_generation,
                 h.created_at, h.expires_at, h.signature,
                 r.signing_public_key, r.encryption_public_key, r.issued_at,
                 r.owner_generation, r.owner_signature, o.public_key
            FROM hails h
            JOIN ship_radio_keys r
              ON r.ship = h.sender_ship
             AND r.generation = h.sender_signing_generation
            JOIN ship_owner_keys o
              ON o.ship = r.ship AND o.generation = r.owner_generation
           WHERE h.recipient_ship = ? AND h.expires_at > ?
             AND h.collected_at IS NULL
           ORDER BY h.created_at, h.rowid LIMIT 1
        SQL
        as: {String, String, Int64, Int64, Int64, Bytes,
             Bytes, Bytes, Int64, Int64, Bytes, Bytes}
      )
      return nil unless row
      hail = Hail.new(
        row[0], row[1], row[2].to_i, ship, row[3], row[4], Crypto.b64(row[5])
      )
      certificate = ShipRadioCertificate.new(
        row[1], row[2].to_i, Crypto.b64(row[6]), Crypto.b64(row[7]),
        row[8], row[9].to_i, Crypto.b64(row[10])
      )
      chain = known[row[1]]?.try do |generation|
        radio_chain(connection, row[1], generation, row[2].to_i)
      end || [] of RadioCertificateLink
      owner_chain = known[row[1]]?.try do |generation|
        from_owner = owner_generation_for_radio(connection, row[1], generation)
        owner_chain(connection, row[1], from_owner, certificate.owner_generation)
      end || [] of OwnerKeyLink
      HailDelivery.new(
        hail, Crypto.b64(row[11]), certificate, owner_chain, chain
      )
    end

    private def contact_updates(connection : DB::Connection, ship : String,
                                known : Hash(String, Int32),
                                now : Int64) : Array(ContactUpdate)
      updates = [] of ContactUpdate
      connection.query(
        <<-SQL, ship, now
          SELECT owner_ship, from_generation, to_generation
            FROM relationship_transitions
           WHERE peer_ship = ? AND expires_at > ?
           ORDER BY owner_ship
        SQL
      ) do |rows|
        rows.each do
          owner_ship, from_generation, to_generation = rows.read(
            String, Int64, Int64
          )
          next unless known[owner_ship]? == from_generation.to_i
          chain = radio_chain(
            connection, owner_ship, from_generation.to_i, to_generation.to_i
          )
          from_owner = owner_generation_for_radio(
            connection, owner_ship, from_generation.to_i
          )
          to_owner = chain.last.certificate.owner_generation
          updates << ContactUpdate.new(
            owner_ship, to_generation.to_i,
            owner_chain(connection, owner_ship, from_owner, to_owner), chain
          )
        end
      end
      updates
    end

    private def radio_chain(connection : DB::Connection, ship : String,
                            from_generation : Int32,
                            to_generation : Int32) : Array(RadioCertificateLink)
      links = [] of RadioCertificateLink
      connection.query(
        <<-SQL, ship, from_generation, to_generation
          SELECT generation, signing_public_key, encryption_public_key,
                 issued_at, owner_generation, owner_signature,
                 prior_radio_signature
            FROM ship_radio_keys
           WHERE ship = ? AND generation > ? AND generation <= ?
           ORDER BY generation
        SQL
      ) do |rows|
        rows.each do
          generation, signing, encryption, issued_at, owner_generation, owner_signature, prior_signature = rows.read(
            Int64, Bytes, Bytes, Int64, Int64, Bytes, Bytes?
          )
          certificate = ShipRadioCertificate.new(
            ship, generation.to_i, Crypto.b64(signing), Crypto.b64(encryption),
            issued_at, owner_generation.to_i, Crypto.b64(owner_signature)
          )
          links << RadioCertificateLink.new(
            certificate,
            prior_signature.try { |signature| Crypto.b64(signature) }
          )
        end
      end
      expected = to_generation - from_generation
      raise Error.new("radio continuity chain is incomplete") unless links.size == expected
      links
    end

    private def owner_generation_for_radio(connection : DB::Connection,
                                           ship : String,
                                           generation : Int32) : Int32
      connection.query_one(
        "SELECT owner_generation FROM ship_radio_keys WHERE ship = ? AND generation = ?",
        ship, generation, as: Int64
      ).to_i
    end

    private def owner_chain(connection : DB::Connection, ship : String,
                            from_generation : Int32,
                            to_generation : Int32) : Array(OwnerKeyLink)
      links = [] of OwnerKeyLink
      connection.query(
        <<-SQL, ship, from_generation, to_generation
          SELECT generation, public_key, authorization_signature
            FROM ship_owner_keys
           WHERE ship = ? AND generation > ? AND generation <= ?
           ORDER BY generation
        SQL
      ) do |rows|
        rows.each do
          generation, public_key, signature = rows.read(Int64, Bytes, Bytes?)
          links << OwnerKeyLink.new(
            generation.to_i, Crypto.b64(public_key),
            signature.try { |value| Crypto.b64(value) }
          )
        end
      end
      raise Error.new("owner continuity chain is incomplete") unless links.size == to_generation - from_generation
      links
    end

    private def radio_key(connection : DB::Connection, ship : String,
                          generation : Int32) : Tuple(Bytes, Bytes, String)
      connection.query_one?(
        "SELECT signing_public_key, encryption_public_key, state FROM ship_radio_keys WHERE ship = ? AND generation = ?",
        ship, generation, as: {Bytes, Bytes, String}
      ) || raise Unauthorized.new("ship radio key is not registered")
    end

    private def owner_key(connection : DB::Connection, ship : String,
                          generation : Int32) : Bytes
      connection.query_one?(
        "SELECT public_key FROM ship_owner_keys WHERE ship = ? AND generation = ? AND state = 'active'",
        ship, generation, as: Bytes
      ) || raise Unauthorized.new("ship owner key is not active")
    end

    private def verify_radio_action(connection : DB::Connection, auth : RadioAuth,
                                    action : String, payload : Bytes,
                                    now : Int64) : Nil
      unauthenticated! unless Names::SHIP.matches?(auth.ship)
      unauthenticated! unless (auth.timestamp - now).abs <= AUTH_SKEW_SECONDS
      signature = decode_auth_signature(auth.signature)
      key = authenticate_radio_signature(
        connection, auth.ship, auth.radio_generation,
        auth.signing_bytes(action, payload), signature
      )
      raise Unavailable.new("ship radio is not active") unless key[2] == "active"
    end

    private def verify_owner_action(connection : DB::Connection, auth : OwnerAuth,
                                    action : String, payload : Bytes,
                                    now : Int64) : Nil
      unauthenticated! unless Names::SHIP.matches?(auth.ship)
      unauthenticated! unless (auth.timestamp - now).abs <= AUTH_SKEW_SECONDS
      signature = decode_auth_signature(auth.signature)
      key = connection.query_one?(
        "SELECT public_key, state FROM ship_owner_keys WHERE ship = ? AND generation = ?",
        auth.ship, auth.owner_generation, as: {Bytes, String}
      )
      verification_key = key.try(&.[0]) || dummy_signing_public_key
      unauthenticated! unless Crypto.verify(
                                auth.signing_bytes(action, payload), signature, verification_key
                              ) && key
      raise Unavailable.new("ship owner key is not active") unless key.not_nil![1] == "active"
      current = connection.query_one?(
        "SELECT admin_generation, state FROM ships WHERE name = ?", auth.ship,
        as: {Int64, String}
      ) || unauthenticated!
      raise Unavailable.new("ship is revoked") if current[1] == "revoked"
      raise Conflict.new("admin generation must advance by one") unless auth.admin_generation == current[0] + 1
    end

    private def authenticate_radio_signature(
      connection : DB::Connection,
      ship : String,
      generation : Int32,
      signed_bytes : Bytes,
      signature : Bytes,
    ) : Tuple(Bytes, Bytes, String)
      key = connection.query_one?(
        "SELECT signing_public_key, encryption_public_key, state FROM ship_radio_keys WHERE ship = ? AND generation = ?",
        ship, generation, as: {Bytes, Bytes, String}
      )
      verification_key = key.try(&.[0]) || dummy_signing_public_key
      unauthenticated! unless Crypto.verify(
                                signed_bytes, signature, verification_key
                              ) && key
      key.not_nil!
    end

    private def decode_auth_signature(encoded : String) : Bytes
      signature = Crypto.unb64(encoded, "authentication signature")
      unauthenticated! unless signature.size == Crypto::SIGNATURE_BYTES
      signature
    rescue Invalid
      unauthenticated!
    end

    private def dummy_signing_public_key : Bytes
      @@dummy_signing_public_key ||= Crypto.signing_keypair(
        Bytes.new(Crypto::SIGN_SEED_BYTES, 0_u8)
      ).public_key
    end

    private def unauthenticated! : NoReturn
      raise Unauthorized.new("authentication failed")
    end

    private def advance_admin(connection : DB::Connection, auth : OwnerAuth) : Nil
      connection.exec("UPDATE ships SET admin_generation = ? WHERE name = ?", auth.admin_generation, auth.ship)
    end

    private def verify_radio_certificate(connection : DB::Connection,
                                         certificate : ShipRadioCertificate) : Nil
      owner = owner_key(connection, certificate.ship, certificate.owner_generation)
      unless Crypto.verify(certificate.unsigned_bytes, Crypto.unb64(certificate.owner_signature), owner)
        raise Unauthorized.new("radio certificate is not owner-authorized")
      end
    end

    private def insert_radio_key(connection : DB::Connection,
                                 certificate : ShipRadioCertificate,
                                 prior_radio_signature : String? = nil) : Nil
      signing = Crypto.unb64(certificate.signing_public_key, "radio signing public key")
      encryption = Crypto.unb64(certificate.encryption_public_key, "radio encryption public key")
      owner_signature = Crypto.unb64(certificate.owner_signature)
      prior_signature = prior_radio_signature.try { |value| Crypto.unb64(value) }
      connection.exec(
        <<-SQL, certificate.ship, certificate.generation, signing, encryption, certificate.issued_at, certificate.owner_generation, owner_signature, prior_signature
          INSERT INTO ship_radio_keys(
            ship, generation, signing_public_key, encryption_public_key,
            state, issued_at, owner_generation, owner_signature,
            prior_radio_signature
          ) VALUES (?, ?, ?, ?, 'active', ?, ?, ?, ?)
        SQL
      )
    end

    private def write_owner_keys(json : JSON::Builder, ship : String) : Nil
      json.array do
        database.db.query(
          "SELECT generation, public_key, state, valid_from, revoked_at, authorization_signature FROM ship_owner_keys WHERE ship = ? ORDER BY generation",
          ship
        ) do |rows|
          rows.each do
            generation, key, state, valid_from, revoked_at, authorization_signature = rows.read(Int64, Bytes, String, Int64, Int64?, Bytes?)
            json.object do
              json.field "generation", generation
              json.field "public_key", Crypto.b64(key)
              json.field "fingerprint", Crypto.fingerprint(key)
              json.field "state", state
              json.field "valid_from", valid_from
              json.field "revoked_at", revoked_at
              json.field "authorization_signature", authorization_signature.try { |signature| Crypto.b64(signature) }
            end
          end
        end
      end
    end

    private def write_radio_keys(json : JSON::Builder, ship : String) : Nil
      json.array do
        database.db.query(
          <<-SQL, ship
            SELECT generation, signing_public_key, encryption_public_key,
                   state, issued_at, owner_generation, owner_signature,
                   prior_radio_signature, revoked_at
              FROM ship_radio_keys WHERE ship = ? ORDER BY generation
          SQL
        ) do |rows|
          rows.each do
            generation, signing, encryption, state, issued_at, owner_generation, owner_signature, prior_signature, revoked_at = rows.read(
              Int64, Bytes, Bytes, String, Int64, Int64, Bytes, Bytes?, Int64?
            )
            json.object do
              json.field "generation", generation
              json.field "signing_public_key", Crypto.b64(signing)
              json.field "encryption_public_key", Crypto.b64(encryption)
              json.field "signing_fingerprint", Crypto.fingerprint(signing)
              json.field "encryption_fingerprint", Crypto.fingerprint(encryption)
              json.field "state", state
              json.field "issued_at", issued_at
              json.field "owner_generation", owner_generation
              json.field "owner_signature", Crypto.b64(owner_signature)
              json.field "prior_radio_signature", prior_signature.try { |signature| Crypto.b64(signature) }
              json.field "revoked_at", revoked_at
            end
          end
        end
      end
    end

    private def require_uuid!(value : String, label : String) : Nil
      raise Invalid.new("invalid #{label}") unless UUID.matches?(value)
    end

    private def relationship_pair(first : String,
                                  second : String) : Tuple(String, String)
      first < second ? {first, second} : {second, first}
    end
  end
end
