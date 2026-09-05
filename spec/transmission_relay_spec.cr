require "./spec_helper"

class RelayCaptureRemote < Tinrelay::Remote
  getter captured : Tinrelay::SignedRelayEnvelope?

  def post(path : String, body : String) : String
    if path == "/v1/transmissions"
      @captured = Tinrelay::SignedRelayEnvelope.from_json(body)
      %({"state":"accepted"})
    else
      super
    end
  end
end

module TinrelayRelaySpec
  def self.admit(root : String, origin : String, ship : String,
                 passphrase : String) : Tinrelay::Client
    TinrelaySpec.admit(root, origin, ship, passphrase)
  end

  def self.trust_locally(sender : Tinrelay::Client,
                         recipient : Tinrelay::Client,
                         label = "steward") : Nil
    radio = recipient.keyring.data.radio!
    sender.keyring.data.contacts << Tinrelay::ShipContact.new(
      recipient.keyring.data.ship,
      recipient.keyring.data.owner_generation,
      recipient.keyring.data.owner_public_key,
      radio.certificate,
      label
    )
  end

  def self.capture(sender : Tinrelay::Client, origin : String,
                   coordinate : String, body : String) : Tinrelay::SignedRelayEnvelope
    remote = RelayCaptureRemote.new(origin)
    Tinrelay::Client.new(sender.keyring, sender.passphrase, remote)
      .send(coordinate, body)
    remote.captured.not_nil!
  end

  def self.resign(sender : Tinrelay::Client, envelope : Tinrelay::SignedRelayEnvelope) : Nil
    radio = sender.keyring.data.radio!
    envelope.signature = Tinrelay::Crypto.b64(
      Tinrelay::Crypto.sign(
        envelope.signing_bytes,
        Tinrelay::Crypto.unb64(radio.signing.secret_key)
      )
    )
  end

  def self.elapsed(&) : Time::Span
    started = Time.instant
    yield
    Time.instant - started
  end
end

describe "transmission relay transitions" do
  it "accepts opaquely but stores nothing without a positive relationship" do
    TinrelaySpec.with_server do |root, origin, api|
      passphrase = "relationship admission passphrase"
      alpha = Tinrelay::Client.join(
        File.join(root, "alpha.keyring"), origin, "alpha", passphrase
      )
      beta = TinrelaySpec.admit_contact(
        root, origin, "beta", passphrase, alpha
      )
      gamma = TinrelayRelaySpec.admit(root, origin, "gamma", passphrase)
      TinrelayRelaySpec.trust_locally(beta, gamma)

      attempt = beta.send("steward@gamma", "guessed but unrelated")
      attempt.submission_evidence[:state].should eq("accepted")
      api.database.db.scalar(
        "SELECT COUNT(*) FROM transmissions WHERE id = ?", attempt.transmission_id
      ).as(Int64).should eq(0)
    end
  end

  it "spools content-free rejection evidence, erases unusable payload, and reaches later traffic" do
    TinrelaySpec.with_server do |root, origin, api|
      passphrase = "unusable transmission passphrase"
      alpha = Tinrelay::Client.join(
        File.join(root, "alpha.keyring"), origin, "alpha", passphrase
      )
      beta = TinrelaySpec.admit_contact(
        root, origin, "beta", passphrase, alpha
      )
      spool = Tinrelay::Spool.new(File.join(root, "inbox"))

      unusable = TinrelayRelaySpec.capture(
        beta, origin, "steward@alpha", "body must never survive rejection"
      )
      unusable.ciphertext = Tinrelay::Crypto.b64(Tinrelay::Crypto.random(64))
      TinrelayRelaySpec.resign(beta, unusable)
      response = beta.remote.post("/v1/transmissions", unusable.to_json)
      JSON.parse(response)["state"].as_s.should eq("accepted")

      invalid_plaintext = TinrelayRelaySpec.capture(
        beta, origin, "steward@alpha", "body also must not survive invalid plaintext"
      )
      recipient = alpha.keyring.data.radio!
      invalid_plaintext.ciphertext = Tinrelay::Crypto.b64(
        Tinrelay::Crypto.seal(
          "not a TinRelay plaintext".to_slice,
          Tinrelay::Crypto.unb64(recipient.encryption.public_key)
        )
      )
      TinrelayRelaySpec.resign(beta, invalid_plaintext)
      response = beta.remote.post("/v1/transmissions", invalid_plaintext.to_json)
      JSON.parse(response)["state"].as_s.should eq("accepted")
      valid = beta.send("steward@alpha", "valid behind unusable")

      rejected = alpha.radio_wait(spool, hold_seconds: 0)
      rejected.kind.should eq("rejected_transmission")
      rejected.name.should be_nil
      rejected.wrapper.should_not contain("body must never survive rejection")
      rejection_record = spool.get(rejected.local_id)
        .as(Tinrelay::RejectedTransmissionSpoolRecord)
      rejection_record.rejection_reason.should eq("unusable_envelope")
      api.database.db.query_one(
        "SELECT state, ciphertext IS NULL FROM transmissions WHERE id = ?",
        unusable.transmission_id, as: {String, Int64}
      ).should eq({"collected", 1_i64})

      spool.routed(rejected.local_id)
      rejected_plaintext = alpha.radio_wait(spool, hold_seconds: 0)
      rejected_plaintext.kind.should eq("rejected_transmission")
      rejected_plaintext.wrapper.should_not contain("body also must not survive")
      api.database.db.query_one(
        "SELECT state, ciphertext IS NULL FROM transmissions WHERE id = ?",
        invalid_plaintext.transmission_id, as: {String, Int64}
      ).should eq({"collected", 1_i64})
      spool.routed(rejected_plaintext.local_id)

      delivered = alpha.radio_wait(spool, hold_seconds: 0)
      delivered.kind.should eq("transmission")
      spool.get(delivered.local_id).as(Tinrelay::TransmissionSpoolRecord)
        .signed_transmission.body.should eq("valid behind unusable")
      delivered.wrapper.should_not contain("valid behind unusable")
      valid.transmission_id.should_not be_empty
    end
  end

  it "counts an authenticated discarded attempt before destination resolution" do
    TinrelaySpec.with_server do |root, origin, api|
      passphrase = "all attempt rate passphrase"
      alpha = Tinrelay::Client.join(
        File.join(root, "alpha.keyring"), origin, "alpha", passphrase
      )
      beta = TinrelaySpec.admit_contact(
        root, origin, "beta", passphrase, alpha
      )
      (Tinrelay::Store::MAX_TRANSMISSIONS_PER_HOUR - 1).times do
        api.submission_window.allow?("beta").should be_true
      end

      discarded = TinrelayRelaySpec.capture(
        beta, origin, "steward@alpha", "discarded attempt"
      )
      discarded.recipient_ship = "not-claimed"
      discarded.recipient_encryption_generation = 1
      TinrelayRelaySpec.resign(beta, discarded)
      response = beta.remote.post("/v1/transmissions", discarded.to_json)
      JSON.parse(response)["state"].as_s.should eq("accepted")

      limited = beta.send("steward@alpha", "must be rate limited opaquely")
      api.database.db.scalar(
        "SELECT COUNT(*) FROM transmissions WHERE id = ?", limited.transmission_id
      ).as(Int64).should eq(0)
    end
  end

  it "returns direct, fallback, and discarded acceptance on the same bounded schedule" do
    TinrelaySpec.with_server do |root, origin, api|
      passphrase = "acceptance schedule passphrase"
      alpha = Tinrelay::Client.join(
        File.join(root, "alpha.keyring"), origin, "alpha", passphrase
      )
      beta = TinrelaySpec.admit_contact(
        root, origin, "beta", passphrase, alpha
      )
      gamma = TinrelayRelaySpec.admit(root, origin, "gamma", passphrase)
      TinrelayRelaySpec.trust_locally(beta, gamma)
      spool = Tinrelay::Spool.new(File.join(root, "inbox"))

      direct_event = Channel(Tinrelay::RadioEvent).new(1)
      spawn { direct_event.send(alpha.radio_wait(spool, hold_seconds: 5)) }
      TinrelaySpec.eventually { api.handoffs.waiting?("alpha") }
      direct_message = nil.as(Tinrelay::SignedRelayEnvelope?)
      direct = TinrelayRelaySpec.elapsed do
        direct_message = beta.send("steward@alpha", "direct timing")
      end
      spool.routed(TinrelaySpec.receive(direct_event).local_id)

      fallback = TinrelayRelaySpec.elapsed do
        beta.send("steward@alpha", "fallback timing")
      end
      discarded = TinrelayRelaySpec.elapsed do
        beta.send("steward@gamma", "discarded timing")
      end

      floor = Tinrelay::API::ACCEPTANCE_TARGET - 25.milliseconds
      durations = [direct, fallback, discarded]
      durations.each { |duration| duration.should be >= floor }
      (durations.max - durations.min).should be < 200.milliseconds
      api.database.db.scalar(
        "SELECT COUNT(*) FROM transmissions WHERE id = ?", direct_message.not_nil!.transmission_id
      ).as(Int64).should eq(0)
    end
  end

  it "rechecks recipient state and pending capacity in the final fallback transaction" do
    TinrelaySpec.with_server do |root, origin, api|
      passphrase = "fallback transaction passphrase"
      alpha = Tinrelay::Client.join(
        File.join(root, "alpha.keyring"), origin, "alpha", passphrase
      )
      beta = TinrelaySpec.admit_contact(
        root, origin, "beta", passphrase, alpha
      )
      envelope = TinrelayRelaySpec.capture(beta, origin, "steward@alpha", "prepared before freeze")
      prepared = api.store.prepare(envelope).not_nil!

      api.database.db.exec("UPDATE ships SET state = 'frozen' WHERE name = 'alpha'")
      api.store.persist(prepared).should be_false
      api.database.db.scalar(
        "SELECT COUNT(*) FROM transmissions WHERE id = ?", envelope.transmission_id
      ).as(Int64).should eq(0)

      api.database.db.exec("UPDATE ships SET state = 'active' WHERE name = 'alpha'")
      Tinrelay::Store::MAX_PENDING_PER_SHIP.times do
        id = Tinrelay::Ids.uuid
        now = Time.utc.to_unix
        api.database.db.exec(
          <<-SQL, id, now, now + 3600, now, Tinrelay::Crypto.random(32)
            INSERT INTO transmissions(
              id, sender_ship, sender_signing_generation,
              recipient_ship, recipient_encryption_generation, created_at, expires_at,
              accepted_at, state, ciphertext, signature, envelope_digest
            ) VALUES (?, 'beta', 1, 'alpha', 1, ?, ?, ?, 'pending', X'01', X'01', ?)
          SQL
        )
      end
      second = TinrelayRelaySpec.capture(beta, origin, "steward@alpha", "prepared before full")
      full = api.store.prepare(second).not_nil!
      api.store.persist(full).should be_false
      api.database.db.scalar(
        "SELECT COUNT(*) FROM transmissions WHERE id = ?", second.transmission_id
      ).as(Int64).should eq(0)
    end
  end

  it "does not rewrite the encrypted keyring for a routine known-contact send" do
    TinrelaySpec.with_server do |root, origin, api|
      passphrase = "stable keyring passphrase"
      alpha = Tinrelay::Client.join(
        File.join(root, "alpha.keyring"), origin, "alpha", passphrase
      )
      beta = TinrelaySpec.admit_contact(
        root, origin, "beta", passphrase, alpha
      )
      before = File.read(beta.keyring.path)
      TinrelayRelaySpec.capture(beta, origin, "steward@alpha", "no key changes")
      File.read(beta.keyring.path).should eq(before)
    end
  end

  it "uses and enforces the 96-hour durable fallback window" do
    TinrelaySpec.with_server do |root, origin, api|
      passphrase = "fallback lifetime passphrase"
      alpha = Tinrelay::Client.join(
        File.join(root, "alpha.keyring"), origin, "alpha", passphrase
      )
      beta = TinrelaySpec.admit_contact(
        root, origin, "beta", passphrase, alpha
      )

      envelope = TinrelayRelaySpec.capture(
        beta, origin, "steward@alpha", "bounded fallback"
      )
      (envelope.expires_at - envelope.created_at).should eq(
        Tinrelay::FALLBACK_LIFETIME_SECONDS
      )
      api.store.prepare(envelope).should_not be_nil

      too_long = Tinrelay::SignedRelayEnvelope.from_json(envelope.to_json)
      too_long.expires_at += 1
      TinrelayRelaySpec.resign(beta, too_long)
      expect_raises(Tinrelay::Invalid, /within 96 hours/) do
        api.store.prepare(too_long)
      end
    end
  end

  it "retains relay tombstones only through envelope expiry" do
    TinrelaySpec.with_server do |root, origin, api|
      passphrase = "cleanup transition passphrase"
      alpha = Tinrelay::Client.join(
        File.join(root, "alpha.keyring"), origin, "alpha", passphrase
      )
      beta = TinrelaySpec.admit_contact(
        root, origin, "beta", passphrase, alpha
      )
      sent = beta.send("steward@alpha", "short retry window", expires_in: 30)
      ack = Tinrelay::TransmissionAck.new(
        sent.transmission_id,
        TinrelaySpec.radio_auth(
          alpha,
          "transmission.ack",
          Tinrelay::Canonical.fields(sent.transmission_id)
        )
      )
      api.store.acknowledge(ack)

      api.store.cleanup(sent.expires_at + 1)
      api.database.db.query_one?(
        "SELECT id FROM transmissions WHERE id = ?", sent.transmission_id, as: String
      ).should be_nil
    end
  end
end
