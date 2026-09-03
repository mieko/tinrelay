require "./spec_helper"

class TrustCaptureRemote < Tinrelay::Remote
  getter envelopes = [] of Tinrelay::SignedRelayEnvelope

  def post(path : String, body : String) : String
    if path == "/v1/transmissions"
      envelopes << Tinrelay::SignedRelayEnvelope.from_json(body)
      %({"state":"accepted"})
    else
      super
    end
  end
end

class RadioSequenceRemote < Tinrelay::Remote
  getter acknowledgements = [] of String

  def initialize(origin : String,
                 @responses : Array(Tinrelay::RadioWaitResponse))
    super(origin)
  end

  def post(path : String, body : String) : String
    case path
    when "/v1/radio/wait"
      (@responses.shift? || raise "test radio sequence is empty").to_json
    when "/v1/transmissions/ack"
      acknowledgements << Tinrelay::TransmissionAck.from_json(body).transmission_id
      %({"state":"acknowledged"})
    else
      super
    end
  end
end

class OwnerSubstitutionRemote < Tinrelay::Remote
  def initialize(origin : String, @envelope : Tinrelay::SignedRelayEnvelope,
                 @substituted_card : String)
    super(origin)
  end

  def post(path : String, body : String) : String
    case path
    when "/v1/radio/wait"
      Tinrelay::RadioWaitResponse.new(envelope: @envelope).to_json
    when "/v1/ships/inspect"
      @substituted_card
    when "/v1/transmissions/ack"
      %({"state":"acknowledged"})
    else
      super
    end
  end
end

class UnavailableSubmissionRemote < Tinrelay::Remote
  def initialize(origin : String, @store : Tinrelay::Store? = nil)
    super(origin)
  end

  def post(path : String, body : String) : String
    case path
    when "/v1/transmissions"
      @store.try(&.accept(Tinrelay::SignedRelayEnvelope.from_json(body)))
      raise Tinrelay::Unavailable.new("synthetic proxy failure")
    when "/v1/hails"
      if store = @store
        hail = store.prepare_hail(Tinrelay::Hail.from_json(body))
        store.persist_hail(hail)
      end
      raise Tinrelay::Unavailable.new("synthetic proxy failure")
    else
      super
    end
  end
end

class AmbiguousRelationshipRemote < Tinrelay::Remote
  getter certificates = [] of String

  def initialize(origin : String, @store : Tinrelay::Store? = nil)
    super(origin)
  end

  def post(path : String, body : String) : String
    if path == "/v1/relationships/close"
      request = Tinrelay::RelationshipClose.from_json(body)
      certificates << request.certificate.to_json
      @store.try(&.close_relationship(request))
      raise Tinrelay::Unavailable.new("synthetic lost relationship-close response")
    end
    super
  end
end

class RejectedRelationshipRemote < Tinrelay::Remote
  def post(path : String, body : String) : String
    if path == "/v1/relationships/close"
      raise Tinrelay::Conflict.new("synthetic definite rejection")
    end
    super
  end
end

module TrustRecoverySpec
  def self.response(origin : String, path : String, body : String) : Tuple(Int32, String)
    headers = HTTP::Headers{
      "Content-Type"        => "application/json",
      "X-Tinrelay-Protocol" => Tinrelay::PROTOCOL.to_s,
    }
    response = HTTP::Client.post("#{origin}#{path}", headers, body)
    {response.status_code, response.body}
  end

  def self.bad_radio_auth(ship : String, generation : Int32,
                          payload : Bytes) : Tinrelay::RadioAuth
    auth = Tinrelay::RadioAuth.new(ship, generation, Time.utc.to_unix)
    auth.signature = Tinrelay::Crypto.b64(Tinrelay::Crypto.random(64))
    auth
  end

  def self.bad_owner_auth(ship : String, owner_generation : Int32,
                          admin_generation : Int64,
                          payload : Bytes) : Tinrelay::OwnerAuth
    auth = Tinrelay::OwnerAuth.new(
      ship, owner_generation, admin_generation, Time.utc.to_unix
    )
    auth.signature = Tinrelay::Crypto.b64(Tinrelay::Crypto.random(64))
    auth
  end
end

describe "trust and recovery transitions" do
  it "uses the pinned owner anchor and certificate after first contact" do
    TinrelaySpec.with_server do |root, origin, api|
      passphrase = "pinned ownership anchor passphrase"
      alpha = Tinrelay::Client.join(
        File.join(root, "alpha.keyring"), origin, "alpha", passphrase
      )
      beta = TinrelaySpec.admit(root, origin, "beta", passphrase)
      TinrelaySpec.connect(root, alpha, beta)
      capture = TrustCaptureRemote.new(origin)
      Tinrelay::Client.new(beta.keyring, passphrase, capture)
        .send("steward@alpha", "pinned identity survives registry substitution")
      envelope = capture.envelopes.first

      genuine = JSON.parse(beta.who("beta"))
      attacker = Tinrelay::Crypto.signing_keypair
      radio = genuine["radio_keys"].as_a.find(&.["state"].as_s.==("active")).not_nil!
      substituted = Tinrelay::ShipRadioCertificate.new(
        "beta", radio["generation"].as_i.to_i,
        radio["signing_public_key"].as_s,
        radio["encryption_public_key"].as_s,
        radio["issued_at"].as_i64, 1
      )
      substituted.owner_signature = Tinrelay::Crypto.b64(
        Tinrelay::Crypto.sign(substituted.unsigned_bytes, attacker.secret_key)
      )
      substituted_card = JSON.build do |json|
        json.object do
          json.field "ship", "beta"
          json.field "claimed_at", genuine["claimed_at"].as_i64
          json.field "state", "active"
          json.field "authority_notice", genuine["authority_notice"].as_s
          json.field "owner_keys" do
            json.array do
              json.object do
                json.field "generation", 1
                json.field "public_key", Tinrelay::Crypto.b64(attacker.public_key)
                json.field "fingerprint", Tinrelay::Crypto.fingerprint(attacker.public_key)
                json.field "state", "active"
                json.field "valid_from", genuine["claimed_at"].as_i64
                json.field "revoked_at", nil
                json.field "authorization_signature", nil
              end
            end
          end
          json.field "radio_keys" do
            json.array do
              json.object do
                json.field "generation", substituted.generation
                json.field "signing_public_key", substituted.signing_public_key
                json.field "encryption_public_key", substituted.encryption_public_key
                json.field "signing_fingerprint", Tinrelay::Crypto.fingerprint(Tinrelay::Crypto.unb64(substituted.signing_public_key))
                json.field "encryption_fingerprint", Tinrelay::Crypto.fingerprint(Tinrelay::Crypto.unb64(substituted.encryption_public_key))
                json.field "state", "active"
                json.field "issued_at", substituted.issued_at
                json.field "owner_generation", 1
                json.field "owner_signature", substituted.owner_signature
                json.field "prior_radio_signature", nil
                json.field "revoked_at", nil
              end
            end
          end
        end
      end
      receiver = Tinrelay::Client.new(
        alpha.keyring, passphrase,
        OwnerSubstitutionRemote.new(origin, envelope, substituted_card)
      )
      spool = Tinrelay::Spool.new(File.join(root, "inbox"))

      event = receiver.radio_wait(spool, hold_seconds: 0)
      event.kind.should eq("transmission")
      record = spool.get(event.local_id).as(Tinrelay::TransmissionSpoolRecord)
      record.signed_transmission.body.should eq("pinned identity survives registry substitution")
    end
  end

  it "retains exact transmission and hail attempts across every unavailable response" do
    TinrelaySpec.with_server do |root, origin, api|
      passphrase = "unavailable ambiguity passphrase"
      alpha = Tinrelay::Client.join(
        File.join(root, "alpha.keyring"), origin, "alpha", passphrase
      )
      beta = TinrelaySpec.admit_contact(
        root, origin, "beta", passphrase, alpha
      )

      [nil, api.store].each_with_index do |accepted_store, index|
        transmission_box = Tinrelay::Outbox.new(File.join(root, "tx-outbox-#{index}"))
        unreliable = Tinrelay::Client.new(
          beta.keyring, passphrase,
          UnavailableSubmissionRemote.new(origin, accepted_store)
        )
        failure = expect_raises(Tinrelay::AcceptanceUnknown) do
          unreliable.send("steward@alpha", "ambiguous #{index}", outbox: transmission_box)
        end
        transmission_box.list.map(&.transmission_id).should eq([failure.transmission_id])
        beta.retry(transmission_box, failure.transmission_id)
        transmission_box.list.should be_empty

        hail_box = Tinrelay::HailOutbox.new(File.join(root, "hail-outbox-#{index}"))
        hail_failure = expect_raises(Tinrelay::HailAcceptanceUnknown) do
          unreliable.hail("alpha", hail_box)
        end
        hail_box.read(hail_failure.hail_id)[0].hail_id.should eq(hail_failure.hail_id)
        beta.retry_hail(hail_box, hail_failure.hail_id)
        expect_raises(Tinrelay::NotFound) { hail_box.read(hail_failure.hail_id) }
      end
    end
  end

  it "returns one unauthenticated response for guessed radio and owner state" do
    TinrelaySpec.with_server do |root, origin, api|
      passphrase = "generic authentication boundary passphrase"
      alpha = Tinrelay::Client.join(
        File.join(root, "alpha.keyring"), origin, "alpha", passphrase
      )
      radio_payload = Tinrelay::Canonical.fields("0", "", "", "")
      radio_cases = [
        TrustRecoverySpec.bad_radio_auth("absent", 1, radio_payload),
        TrustRecoverySpec.bad_radio_auth("alpha", 1, radio_payload),
        TrustRecoverySpec.bad_radio_auth("alpha", 99, radio_payload),
      ].map do |auth|
        request = Tinrelay::RadioWaitRequest.new(0, auth)
        TrustRecoverySpec.response(origin, "/v1/radio/wait", request.to_json)
      end
      radio_cases.uniq.size.should eq(1)

      owner_cases = [
        TrustRecoverySpec.bad_owner_auth("absent", 1, 1_i64, Tinrelay::Canonical.fields("freeze")),
        TrustRecoverySpec.bad_owner_auth("alpha", 1, 99_i64, Tinrelay::Canonical.fields("freeze")),
        TrustRecoverySpec.bad_owner_auth("alpha", 99, 1_i64, Tinrelay::Canonical.fields("freeze")),
      ].map do |auth|
        request = Tinrelay::ShipChange.new("freeze", auth)
        TrustRecoverySpec.response(origin, "/v1/ships/change", request.to_json)
      end
      owner_cases.uniq.size.should eq(1)
      alpha.keyring.data.ship.should eq("alpha")
    end
  end

  it "reuses one pending radio identity across failure, restart, and lost success" do
    TinrelaySpec.with_server do |root, origin, api|
      passphrase = "single pending radio identity passphrase"
      alpha = Tinrelay::Client.join(
        File.join(root, "alpha.keyring"), origin, "alpha", passphrase
      )
      spool = Tinrelay::Spool.new(File.join(root, "alpha-inbox"))
      %w(beta gamma delta).each do |ship|
        peer = TinrelaySpec.admit_contact(
          root, origin, ship, passphrase, alpha
        )
        peer.send("steward@alpha", "establish #{ship}")
        event = alpha.radio_wait(spool, hold_seconds: 0)
        spool.routed(event.local_id)
      end

      before_acceptance = AmbiguousRelationshipRemote.new(origin)
      interrupted = Tinrelay::Client.new(
        alpha.keyring, passphrase, before_acceptance
      )
      expect_raises(Tinrelay::Unavailable) do
        interrupted.close_contact("beta")
      end
      pending_certificate = interrupted.keyring.data.pending_radio.not_nil!
        .certificate.to_json

      restarted_keyring = Tinrelay::Keyring.load(alpha.keyring.path, passphrase)
      after_acceptance = AmbiguousRelationshipRemote.new(origin, api.store)
      restarted = Tinrelay::Client.new(
        restarted_keyring, passphrase, after_acceptance
      )
      restarted.close_contact("beta").should eq(2)
      after_acceptance.certificates.should eq([pending_certificate])
      before_acceptance.certificates.should eq([pending_certificate])
      restarted.keyring.data.pending_radio.should be_nil
      restarted.keyring.data.radios.count(&.generation.==(2)).should eq(1)

      rejected = Tinrelay::Client.new(
        restarted.keyring, passphrase,
        RejectedRelationshipRemote.new(origin)
      )
      expect_raises(Tinrelay::Conflict, /definite rejection/) do
        rejected.close_contact("gamma")
      end
      rejected.keyring.data.pending_radio.should be_nil
    end
  end

  it "suppresses routed exact retries but still advances to later traffic" do
    TinrelaySpec.with_server do |root, origin, api|
      passphrase = "routed retry suppression passphrase"
      alpha = Tinrelay::Client.join(
        File.join(root, "alpha.keyring"), origin, "alpha", passphrase
      )
      beta = TinrelaySpec.admit_contact(
        root, origin, "beta", passphrase, alpha
      )
      capture = TrustCaptureRemote.new(origin)
      composer = Tinrelay::Client.new(beta.keyring, passphrase, capture)
      composer.send("steward@alpha", "exactly once pointer")
      composer.send("steward@alpha", "later valid traffic")
      first, later = capture.envelopes
      remote = RadioSequenceRemote.new(origin, [
        Tinrelay::RadioWaitResponse.new(envelope: first),
        Tinrelay::RadioWaitResponse.new(envelope: first),
        Tinrelay::RadioWaitResponse.new(envelope: later),
      ])
      receiver = Tinrelay::Client.new(alpha.keyring, passphrase, remote)
      spool = Tinrelay::Spool.new(File.join(root, "inbox"))

      first_event = receiver.radio_wait(spool, hold_seconds: 0)
      spool.routed(first_event.local_id)
      next_event = receiver.radio_wait(spool, hold_seconds: 0)
      spool.get(next_event.local_id).as(Tinrelay::TransmissionSpoolRecord)
        .signed_transmission.body
        .should eq("later valid traffic")
      remote.acknowledgements.should eq([
        first.transmission_id, first.transmission_id, later.transmission_id,
      ])
    end
  end

  it "holds one OS-released local radio waiter lock" do
    root = TinrelaySpec.temporary_root
    ready = File.join(root, "child-ready")
    spool = Tinrelay::Spool.new(File.join(root, "inbox"))
    helper = File.expand_path("support/radio_lock_holder.cr", __DIR__)
    helper_binary = File.join(root, "radio-lock-holder")
    build = Process.run(
      "crystal", ["build", helper, "-o", helper_binary],
      output: Process::Redirect::Close, error: Process::Redirect::Close
    )
    build.success?.should be_true
    child = Process.new(
      helper_binary, [spool.root, ready],
      output: Process::Redirect::Close, error: Process::Redirect::Close
    )
    begin
      TinrelaySpec.eventually { File.file?(ready) }
      expect_raises(Tinrelay::Conflict, /radio wait is already running/) do
        spool.with_radio_lock { }
      end
      child.terminate
      child.wait
      spool.with_radio_lock { }
    ensure
      begin
        child.terminate
      rescue
      end
      FileUtils.rm_r(root) if Dir.exists?(root)
    end
  end
end
