require "./spec_helper"

describe "destinationless ship admission" do
  it "claims exactly one contact-free ship from a bounded capability" do
    TinrelaySpec.with_server do |root, _token, origin, api|
      id = Tinrelay::Ids.uuid
      secret_bytes = Tinrelay::Crypto.random(32)
      secret = Tinrelay::Crypto.b64(secret_bytes)
      expires_at = Time.utc.to_unix + 3600
      api.store.create_admission(
        id, "first-ship", Digest::SHA256.digest(secret_bytes), expires_at
      )
      admission = Tinrelay::ShipAdmission.new(
        origin, id, "first-ship", secret, expires_at
      )
      JSON.parse(admission.to_json).as_h.keys.sort.should eq(%w(
        admission_id expires_at kind protocol server ship
        ship_claim_admission_secret
      ).sort)
      url = "#{origin}/meet##{Base64.urlsafe_encode(admission.to_json, padding: false)}"

      ship = Tinrelay::Client.join(
        File.join(root, "first.keyring"), url, "first-ship",
        "destinationless passphrase"
      )
      ship.keyring.data.contacts.should be_empty
      api.database.db.query_one?(
        "SELECT used_at FROM admissions WHERE id = ?", id, as: Int64
      ).should_not be_nil

      expect_raises(Tinrelay::Invalid, /another ship/) do
        Tinrelay::Client.join(
          File.join(root, "second.keyring"), url, "second-ship",
          "destinationless passphrase"
        )
      end
    end
  end

  it "rejects revoked and expired admissions without creating a ship" do
    TinrelaySpec.with_server do |root, _token, origin, api|
      secret_bytes = Tinrelay::Crypto.random(32)
      secret = Tinrelay::Crypto.b64(secret_bytes)
      now = Time.utc.to_unix

      revoked_id = Tinrelay::Ids.uuid
      api.store.create_admission(
        revoked_id, "revoked-ship", Digest::SHA256.digest(secret_bytes), now + 60, now
      )
      api.store.revoke_admission(revoked_id, now)
      revoked = Tinrelay::ShipAdmission.new(
        origin, revoked_id, "revoked-ship", secret, now + 60
      )
      revoked_url = "#{origin}/meet##{Base64.urlsafe_encode(revoked.to_json, padding: false)}"
      expect_raises(Tinrelay::Unauthorized, "relay authentication failed") do
        Tinrelay::Client.join(
          File.join(root, "revoked.keyring"), revoked_url, "revoked-ship",
          "destinationless passphrase"
        )
      end

      expired_id = Tinrelay::Ids.uuid
      api.database.db.exec(
        "INSERT INTO admissions(id, ship, ship_claim_admission_secret_hash, expires_at) VALUES (?, ?, ?, ?)",
        expired_id, "expired-ship", Digest::SHA256.digest(secret_bytes), now - 1
      )
      expired = Tinrelay::ShipAdmission.new(
        origin, expired_id, "expired-ship", secret, now - 1
      )
      expired_url = "#{origin}/meet##{Base64.urlsafe_encode(expired.to_json, padding: false)}"
      expect_raises(Tinrelay::Expired, "relay object has expired") do
        Tinrelay::Client.join(
          File.join(root, "expired.keyring"), expired_url, "expired-ship",
          "destinationless passphrase"
        )
      end
    end
  end
end
