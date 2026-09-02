require "./spec_helper"

class ContactVisibilityRemote < Tinrelay::Remote
  getter requests = [] of Tuple(String, String)

  def post(path : String, body : String) : String
    requests << {path, body}
    super
  end
end

describe "contact trust and content-free hails" do
  it "keeps peer pairing material out of complete server-visible contact admission" do
    TinrelaySpec.with_server do |root, token, origin, api|
      passphrase = "independent invitation secrets"
      alpha = Tinrelay::Client.bootstrap(
        File.join(root, "alpha.keyring"), origin, "alpha", passphrase, token
      )
      beta = TinrelaySpec.admit(root, origin, api, "beta", passphrase)
      invitation_url = alpha.create_invitation("steward", 3600)
      invitation = Tinrelay::Client.invitation_from_url(invitation_url)
      JSON.parse(invitation.to_json).as_h.keys.sort.should eq(%w(
        expires_at invitation_id kind peer_pairing_secret protocol
        radio_certificate recipient_label recipient_ship
        relationship_admission_secret server ship_owner_generation
        ship_owner_public_key
      ).sort)
      invitation.relationship_admission_secret.should_not eq(invitation.peer_pairing_secret)

      remote = ContactVisibilityRemote.new(origin)
      Tinrelay::Client.new(beta.keyring, passphrase, remote)
        .pin_invitation(invitation_url)
      accept_request = remote.requests.find(&.[0].==("/v1/invitations/accept")).not_nil!
      accept_json = JSON.parse(accept_request[1])
      accept_json["relationship_admission_secret"].as_s.should eq(
        invitation.relationship_admission_secret
      )
      accept_request[1].should_not contain(invitation.peer_pairing_secret)
      server_visible = remote.requests.map(&.[1]).join("\n") +
                       api.database.db.query_one(
                         "SELECT hex(relationship_admission_secret_hash) FROM invitations WHERE id = ?",
                         invitation.invitation_id, as: String
                       )
      server_visible.should_not contain(invitation.peer_pairing_secret)

      substituted_owner = Tinrelay::Crypto.signing_keypair
      substituted_radio = Tinrelay::Crypto.signing_keypair
      substituted_box = Tinrelay::Crypto.box_keypair
      certificate = Tinrelay::ShipRadioCertificate.new(
        "beta", 1, Tinrelay::Crypto.b64(substituted_radio.public_key),
        Tinrelay::Crypto.b64(substituted_box.public_key), Time.utc.to_unix, 1
      )
      certificate.owner_signature = Tinrelay::Crypto.b64(
        Tinrelay::Crypto.sign(certificate.unsigned_bytes, substituted_owner.secret_key)
      )
      identity = Tinrelay::Pairing.identity_bytes(
        invitation.invitation_id, "beta", 1,
        Tinrelay::Crypto.b64(substituted_owner.public_key), certificate
      )
      forged = Tinrelay::Crypto.hmac(
        identity, Tinrelay::Crypto.unb64(invitation.relationship_admission_secret)
      )
      genuine = Tinrelay::Crypto.hmac(
        identity, Tinrelay::Crypto.unb64(invitation.peer_pairing_secret)
      )
      Tinrelay::Crypto.constant_time_equal?(forged, genuine).should be_false
    end
  end

  it "delivers a ship-name hail only to fallback without creating contact" do
    TinrelaySpec.with_server do |root, token, origin, api|
      passphrase = "content free hail passphrase"
      alpha = Tinrelay::Client.bootstrap(
        File.join(root, "alpha.keyring"), origin, "alpha", passphrase, token
      )
      beta = TinrelaySpec.admit(root, origin, api, "beta", passphrase)
      spool = Tinrelay::Spool.new(File.join(root, "inbox"))

      hail = beta.hail("alpha", Tinrelay::HailOutbox.new(File.join(root, "outbox")))
      event = alpha.radio_wait(spool, hold_seconds: 0)
      event.kind.should eq("hail")
      event.name.should be_nil
      event.wrapper.should contain("Registry-authenticated sender ship: beta")
      event.wrapper.should_not contain("steward")
      spool.get(event.local_id).should be_a(Tinrelay::HailSpoolRecord)
      api.database.db.query_one(
        "SELECT collected_at IS NOT NULL FROM hails WHERE id = ?", hail.hail_id,
        as: Int64
      ).should eq(1_i64)
      api.database.db.scalar(
        "SELECT COUNT(*) FROM invitations WHERE used_by_ship IN ('alpha', 'beta')"
      ).as(Int64).should eq(0)
    end
  end

  it "counts authenticated invalid-target hails before resolution and keeps their result opaque" do
    TinrelaySpec.with_server do |root, token, origin, api|
      passphrase = "opaque hail admission passphrase"
      Tinrelay::Client.bootstrap(
        File.join(root, "alpha.keyring"), origin, "alpha", passphrase, token
      )
      beta = TinrelaySpec.admit(root, origin, api, "beta", passphrase)
      box = Tinrelay::HailOutbox.new(File.join(root, "outbox"))

      Tinrelay::Store::MAX_HAILS_PER_DAY.times do |index|
        started = Time.instant
        hail = beta.hail("absent-#{index}", box)
        hail.submission_evidence[:state].should eq("accepted")
        (Time.instant - started).should be >= Tinrelay::API::ACCEPTANCE_TARGET - 25.milliseconds
      end

      limited = beta.hail("alpha", box)
      limited.submission_evidence[:state].should eq("accepted")
      api.database.db.scalar(
        "SELECT COUNT(*) FROM hails WHERE id = ?", limited.hail_id
      ).as(Int64).should eq(0)
    end
  end
end
