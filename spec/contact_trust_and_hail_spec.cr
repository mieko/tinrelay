require "./spec_helper"

describe "contact trust and content-free hails" do
  it "establishes first contact from an explicitly allowed hail and pins each ship by TOFU" do
    TinrelaySpec.with_server do |root, origin, api|
      passphrase = "explicit hail trust passphrase"
      alpha = Tinrelay::Client.join(
        File.join(root, "alpha.keyring"), origin, "alpha", passphrase
      )
      beta = Tinrelay::Client.join(
        File.join(root, "beta.keyring"), origin, "beta", passphrase
      )
      beta_spool = Tinrelay::Spool.new(File.join(root, "beta-inbox"))
      alpha_spool = Tinrelay::Spool.new(File.join(root, "alpha-inbox"))

      alpha.hail("beta")
      event = beta.radio_wait(beta_spool, hold_seconds: 0)
      event.kind.should eq("hail")
      inspection = JSON.parse(beta_spool.inspection(event.local_id))
      inspection["sender_owner_fingerprint"].as_s.should eq(
        Tinrelay::Crypto.fingerprint(
          Tinrelay::Crypto.unb64(alpha.keyring.data.owner_public_key)
        )
      )
      inspection["sender_radio_fingerprint"].as_s.should eq(
        Tinrelay::Crypto.fingerprint(
          alpha.keyring.data.radio!.certificate.unsigned_bytes
        )
      )
      beta_spool.routed(event.local_id)
      beta.keyring.data.contacts.should be_empty
      alpha.keyring.data.contacts.should be_empty

      beta.allow_contact("alpha", event.local_id, beta_spool)
      beta.keyring.data.contact!("alpha").radio_certificate.to_json.should eq(
        alpha.keyring.data.radio!.certificate.to_json
      )
      alpha.keyring.data.contacts.should be_empty
      api.database.db.query_one(
        "SELECT state FROM relationships WHERE ship_a = 'alpha' AND ship_b = 'beta'",
        as: String
      ).should eq("active")

      beta.hail("alpha")
      return_event = alpha.radio_wait(alpha_spool, hold_seconds: 0)
      return_event.kind.should eq("hail")
      alpha_spool.routed(return_event.local_id)
      alpha.allow_contact("beta", return_event.local_id, alpha_spool)
      alpha.keyring.data.contact!("beta").radio_certificate.to_json.should eq(
        beta.keyring.data.radio!.certificate.to_json
      )

      first = alpha.send("steward@beta", "Hello from alpha")
      received = beta.radio_wait(beta_spool, hold_seconds: 0)
      received.kind.should eq("transmission")
      beta_spool.get(received.local_id).as(Tinrelay::TransmissionSpoolRecord)
        .relay_transmission_id.should eq(first.transmission_id)
    end
  end

  it "delivers a ship-name hail only to fallback without creating contact" do
    TinrelaySpec.with_server do |root, origin, api|
      passphrase = "content free hail passphrase"
      alpha = Tinrelay::Client.join(
        File.join(root, "alpha.keyring"), origin, "alpha", passphrase
      )
      beta = TinrelaySpec.admit(root, origin, "beta", passphrase)
      spool = Tinrelay::Spool.new(File.join(root, "inbox"))

      hail = beta.hail("alpha")
      event = alpha.radio_wait(spool, hold_seconds: 0)
      event.kind.should eq("hail")
      event.name.should be_nil
      event.wrapper.should contain("Registry-observed sender ship: beta")
      event.wrapper.should_not contain("steward")
      spool.get(event.local_id).should be_a(Tinrelay::HailSpoolRecord)
      api.database.db.query_one(
        "SELECT collected_at IS NOT NULL FROM hails WHERE id = ?", hail.hail_id,
        as: Int64
      ).should eq(1_i64)
      api.database.db.scalar("SELECT COUNT(*) FROM relationships").as(Int64).should eq(0)
    end
  end

  it "counts authenticated invalid-target hails before resolution and keeps their result opaque" do
    TinrelaySpec.with_server do |root, origin, api|
      passphrase = "opaque hail admission passphrase"
      Tinrelay::Client.join(
        File.join(root, "alpha.keyring"), origin, "alpha", passphrase
      )
      beta = TinrelaySpec.admit(root, origin, "beta", passphrase)
      Tinrelay::Store::MAX_HAILS_PER_DAY.times do |index|
        started = Time.instant
        hail = beta.hail("absent-#{index}")
        hail.submission_evidence[:state].should eq("accepted")
        (Time.instant - started).should be >= Tinrelay::API::ACCEPTANCE_TARGET - 25.milliseconds
      end

      limited = beta.hail("alpha")
      limited.submission_evidence[:state].should eq("accepted")
      api.database.db.scalar(
        "SELECT COUNT(*) FROM hails WHERE id = ?", limited.hail_id
      ).as(Int64).should eq(0)
    end
  end
end
