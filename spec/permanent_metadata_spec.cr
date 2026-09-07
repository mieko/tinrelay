require "./spec_helper"

describe "permanent relay metadata capacity" do
  it "serializes concurrent permanent growth at the configured boundary" do
    root = TinrelaySpec.temporary_root
    database = Tinrelay::Database.new(File.join(root, "capacity.db"), 2)
    store = Tinrelay::Store.new(database, 3_i64)
    prepared = %w(alpha beta).map do |ship|
      owner = Tinrelay::Crypto.signing_keypair
      signing = Tinrelay::Crypto.signing_keypair
      encryption = Tinrelay::Crypto.box_keypair
      certificate = Tinrelay::ShipRadioCertificate.new(
        ship, 1, Tinrelay::Crypto.b64(signing.public_key),
        Tinrelay::Crypto.b64(encryption.public_key), Time.utc.to_unix, 1
      )
      certificate.owner_signature = Tinrelay::Crypto.b64(
        Tinrelay::Crypto.sign(certificate.unsigned_bytes, owner.secret_key)
      )
      store.prepare_claim(Tinrelay::ShipClaim.new(
        ship, Tinrelay::Crypto.b64(owner.public_key), certificate
      ))
    end
    results = Channel(Exception?).new(2)

    prepared.each do |claim|
      spawn do
        begin
          store.claim(claim)
          results.send(nil)
        rescue ex
          results.send(ex)
        end
      end
    end

    outcomes = 2.times.map { TinrelaySpec.receive(results) }.to_a
    outcomes.count(&.nil?).should eq(1)
    outcomes.compact.first.should be_a(Tinrelay::Unavailable)
    store.permanent_metadata_usage.should eq(3)
  ensure
    database.try(&.close)
    FileUtils.rm_r(root) if root && Dir.exists?(root)
  end

  it "rejects growing claims while established correspondence remains writable" do
    TinrelaySpec.with_server(permanent_metadata_limit: 3_i64) do |root, origin, api|
      passphrase = "permanent metadata claim capacity"
      alpha = TinrelaySpec.admit(root, origin, "alpha", passphrase)

      expect_raises(Tinrelay::Unavailable) do
        TinrelaySpec.admit(root, origin, "beta", passphrase)
      end
      api.store.permanent_metadata_usage.should eq(3)
      below_limit = Tinrelay::Store.new(api.database, 2_i64)
      below_limit.permanent_metadata_usage.should eq(3)
      below_limit.wait_once(TinrelaySpec.radio_wait_request(alpha, 0)).empty?.should be_true

      sent = alpha.send("steward@alpha", "capacity leaves correspondence working")
      api.database.db.scalar(
        "SELECT COUNT(*) FROM transmissions WHERE id = ?", sent.transmission_id
      ).as(Int64).should eq(1)
    end
  end

  it "charges owner and radio generations but not an existing relationship update" do
    TinrelaySpec.with_server(permanent_metadata_limit: 7_i64) do |root, origin, api|
      passphrase = "permanent metadata generation capacity"
      alpha = TinrelaySpec.admit(root, origin, "alpha", passphrase)
      beta = TinrelaySpec.admit(root, origin, "beta", passphrase)
      TinrelaySpec.connect(root, alpha, beta)

      api.store.permanent_metadata_usage.should eq(7)
      hail_id = api.database.db.query_one(
        "SELECT id FROM hails WHERE sender_ship = 'beta' AND recipient_ship = 'alpha'",
        as: String
      )
      repeated = Tinrelay::RelationshipAllow.new(
        "beta", hail_id, Tinrelay::RadioAuth.new("alpha", 1, 0_i64)
      )
      repeated.auth = TinrelaySpec.radio_auth(
        alpha, "relationship.allow", repeated.payload
      )
      api.store.allow_relationship(repeated)
      api.store.permanent_metadata_usage.should eq(7)

      expect_raises(Tinrelay::Unavailable) { alpha.rotate_owner }
      expect_raises(Tinrelay::Unavailable) { alpha.close_contact("beta") }

      api.database.db.scalar(
        "SELECT COUNT(*) FROM ship_owner_keys WHERE ship = 'alpha'"
      ).as(Int64).should eq(1)
      api.database.db.scalar(
        "SELECT COUNT(*) FROM ship_radio_keys WHERE ship = 'alpha'"
      ).as(Int64).should eq(1)
      api.database.db.query_one(
        "SELECT state FROM relationships WHERE ship_a = 'alpha' AND ship_b = 'beta'",
        as: String
      ).should eq("active")
    end
  end

  it "leaves a hail unallowed when a new relationship would exceed capacity" do
    TinrelaySpec.with_server(permanent_metadata_limit: 6_i64) do |root, origin, api|
      passphrase = "permanent metadata relationship capacity"
      alpha = TinrelaySpec.admit(root, origin, "alpha", passphrase)
      beta = TinrelaySpec.admit(root, origin, "beta", passphrase)
      spool = Tinrelay::Spool.new(File.join(root, "beta-inbox"))

      alpha.hail("beta")
      event = beta.radio_wait(spool, hold_seconds: 0)
      hail_id = spool.get(event.local_id).as(Tinrelay::HailSpoolRecord).hail_id
      request = Tinrelay::RelationshipAllow.new(
        "alpha", hail_id, Tinrelay::RadioAuth.new("beta", 1, 0_i64)
      )
      request.auth = TinrelaySpec.radio_auth(
        beta, "relationship.allow", request.payload
      )

      expect_raises(Tinrelay::Unavailable) do
        api.store.allow_relationship(request)
      end
      api.database.db.scalar("SELECT COUNT(*) FROM relationships").should eq(0)
      api.database.db.query_one(
        "SELECT allowed_at IS NULL FROM hails WHERE id = ?", hail_id, as: Int64
      ).should eq(1_i64)
      api.store.permanent_metadata_usage.should eq(6)
    end
  end

  it "charges transitioning relationships until cleanup physically removes them" do
    TinrelaySpec.with_server(permanent_metadata_limit: 8_i64) do |root, origin, api|
      passphrase = "permanent metadata transition cleanup"
      alpha = TinrelaySpec.admit(root, origin, "alpha", passphrase)
      beta = TinrelaySpec.admit(root, origin, "beta", passphrase)
      TinrelaySpec.connect(root, alpha, beta)

      alpha.close_contact("beta").should eq(2)
      api.store.permanent_metadata_usage.should eq(8)

      api.store.cleanup(Time.utc.to_unix + Tinrelay::FALLBACK_LIFETIME_SECONDS + 1)

      api.database.db.scalar("SELECT COUNT(*) FROM relationships").should eq(0)
      api.store.permanent_metadata_usage.should eq(7)
    end
  end

  it "rejects a signed wrong-sized next owner key without consuming history" do
    TinrelaySpec.with_server do |root, origin, api|
      passphrase = "permanent metadata owner key length"
      alpha = TinrelaySpec.admit(root, origin, "alpha", passphrase)
      owner = alpha.keyring.owner(passphrase)
      next_public = Tinrelay::Crypto.b64(Bytes.new(40_000, 1_u8))
      rotation_bytes = Tinrelay::Canonical.fields(
        "tinrelay-owner-rotation-v1", "alpha", "2", next_public
      )
      prior_signature = Tinrelay::Crypto.b64(
        Tinrelay::Crypto.sign(
          rotation_bytes, Tinrelay::Crypto.unb64(owner.key.secret_key)
        )
      )
      auth = Tinrelay::OwnerAuth.new("alpha", 1, 1_i64, Time.utc.to_unix)
      rotation = Tinrelay::OwnerRotation.new(2, next_public, prior_signature, auth)
      auth.signature = Tinrelay::Crypto.b64(
        Tinrelay::Crypto.sign(
          auth.signing_bytes("owner.rotate", rotation.payload),
          Tinrelay::Crypto.unb64(owner.key.secret_key)
        )
      )
      headers = HTTP::Headers{
        "Content-Type"        => "application/json",
        "X-Tinrelay-Protocol" => Tinrelay::PROTOCOL.to_s,
      }

      response = HTTP::Client.post(
        "#{origin}/v1/owners/rotate", headers, rotation.to_json
      )

      response.status_code.should eq(400)
      api.database.db.scalar(
        "SELECT COUNT(*) FROM ship_owner_keys WHERE ship = 'alpha'"
      ).as(Int64).should eq(1)
    end
  end

  it "bounds the operator setting to the identity-response contract" do
    root = TinrelaySpec.temporary_root
    database = Tinrelay::Database.new(File.join(root, "capacity.db"))
    begin
      expect_raises(Tinrelay::Invalid) { Tinrelay::Store.new(database, 0_i64) }
      expect_raises(Tinrelay::Invalid) do
        Tinrelay::Store.new(
          database, Tinrelay::MAX_PERMANENT_METADATA_LIMIT + 1
        )
      end
    ensure
      database.close
      FileUtils.rm_r(root)
    end
  end

  it "reads a valid identity history beyond the ordinary response ceiling" do
    TinrelaySpec.with_server do |root, origin, api|
      passphrase = "bounded large identity history"
      alpha = TinrelaySpec.admit(root, origin, "alpha", passphrase)
      owner = alpha.keyring.owner(passphrase).key
      previous_secret = Tinrelay::Crypto.unb64(owner.secret_key)

      api.database.db.transaction do |transaction|
        connection = transaction.connection
        2.upto(300) do |generation|
          keys = Tinrelay::Crypto.signing_keypair
          encoded = Tinrelay::Crypto.b64(keys.public_key)
          rotation = Tinrelay::Canonical.fields(
            "tinrelay-owner-rotation-v1", "alpha", generation.to_s, encoded
          )
          signature = Tinrelay::Crypto.sign(rotation, previous_secret)
          connection.exec(
            "UPDATE ship_owner_keys SET state = 'rotated', revoked_at = 0 " +
            "WHERE ship = 'alpha' AND state = 'active'"
          )
          connection.exec(
            <<-SQL, generation, keys.public_key, signature
              INSERT INTO ship_owner_keys(
                ship, generation, public_key, state, valid_from,
                authorization_signature
              ) VALUES ('alpha', ?, ?, 'active', 0, ?)
            SQL
          )
          previous_secret = keys.secret_key
        end
        connection.exec("UPDATE ships SET admin_generation = 299 WHERE name = 'alpha'")
      end

      card = alpha.who("alpha")
      card.bytesize.should be > Tinrelay::Remote::MAX_RESPONSE_BYTES
      card.bytesize.to_i64.should be < Tinrelay::MAX_IDENTITY_RESPONSE_BYTES
      JSON.parse(card)["owner_keys"].as_a.size.should eq(300)
    end
  end

  it "bounds every distinct history contribution, separator, and fixed framing" do
    row_count = Tinrelay::MAX_PERMANENT_METADATA_LIMIT
    array_count = 4_i64
    repeated_entries =
      row_count * Tinrelay::IdentityResponseBounds.maximum_permanent_row_bytes
    separators =
      (row_count - array_count) *
        Tinrelay::IdentityResponseBounds::PERMANENT_ROW_SEPARATOR_BYTES
    fixed_shape = {
      owner_keys:  [] of String,
      radio_keys:  [] of String,
      owner_chain: [] of String,
      chain:       [] of String,
    }.to_json.bytesize.to_i64

    fixed_shape.should be <= Tinrelay::IdentityResponseBounds::FIXED_ENVELOPE_BYTES
    maximum_serialized_shape = repeated_entries + separators + fixed_shape
    Tinrelay::MAX_IDENTITY_RESPONSE_BYTES.should be >= maximum_serialized_shape
  end
end
