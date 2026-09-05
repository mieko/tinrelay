require "./spec_helper"

class RadioPollRemote < Tinrelay::Remote
  getter holds = [] of Int32
  getter acknowledgements = [] of String

  def initialize(origin : String,
                 @responses : Array(Tinrelay::RadioWaitResponse),
                 @ack_unavailable = false)
    super(origin)
  end

  def post(path : String, body : String) : String
    case path
    when "/v1/radio/wait"
      request = Tinrelay::RadioWaitRequest.from_json(body)
      holds << request.hold_seconds
      (@responses.shift? || raise "test radio sequence is empty").to_json
    when "/v1/transmissions/ack"
      acknowledgement = Tinrelay::TransmissionAck.from_json(body)
      acknowledgements << acknowledgement.transmission_id
      raise Tinrelay::Unavailable.new("synthetic relay outage") if @ack_unavailable
      %({"state":"acknowledged"})
    else
      super
    end
  end
end

describe "immediate radio polling" do
  it "surfaces durable local work even when relay cleanup is unavailable" do
    TinrelaySpec.with_server do |root, origin, _api|
      passphrase = "local poll recovery passphrase"
      alpha = Tinrelay::Client.join(
        File.join(root, "alpha.keyring"), origin, "alpha", passphrase
      )
      beta = TinrelaySpec.admit_contact(
        root, origin, "beta", passphrase, alpha
      )
      spool = Tinrelay::Spool.new(File.join(root, "inbox"))
      beta.send("steward@alpha", "already safe at home")
      pending = alpha.radio_wait(spool, hold_seconds: 0)

      offline = RadioPollRemote.new(origin, [] of Tinrelay::RadioWaitResponse, true)
      replayed = Tinrelay::Client.new(alpha.keyring, passphrase, offline)
        .radio_poll(spool)

      replayed.not_nil!.local_id.should eq(pending.local_id)
      offline.holds.should be_empty
      offline.acknowledgements.should be_empty
    end
  end

  it "lets radio wait resurface durable local work without the relay" do
    root = TinrelaySpec.temporary_root
    spool = Tinrelay::Spool.new(File.join(root, "inbox"))
    record = Tinrelay::RejectedTransmissionSpoolRecord.new(
      local_id: "tr_0123456789abcdef0123456789abcdef",
      received_at: 10_i64,
      relay_transmission_id: "11111111-1111-4111-8111-111111111111",
      rejection_reason: "unusable_envelope"
    )
    Tinrelay::AtomicPrivateFile.write(
      File.join(spool.pending, "#{record.local_id}.json"),
      record.to_pretty_json + "\n"
    )
    offline = RadioPollRemote.new(
      "http://127.0.0.1:1", [] of Tinrelay::RadioWaitResponse, true
    )
    keyring = Tinrelay::Keyring.create(
      File.join(root, "alpha.keyring"), "http://127.0.0.1:1", "alpha",
      "offline wait passphrase"
    )

    event = Tinrelay::Client.new(keyring, "offline wait passphrase", offline)
      .radio_wait(spool, hold_seconds: 0)

    event.local_id.should eq(record.local_id)
    offline.holds.should be_empty
    offline.acknowledgements.should be_empty
  ensure
    FileUtils.rm_r(root) if root && Dir.exists?(root)
  end

  it "collects immediately available relay work through the ordinary path" do
    TinrelaySpec.with_server do |root, origin, api|
      passphrase = "immediate relay poll passphrase"
      alpha = Tinrelay::Client.join(
        File.join(root, "alpha.keyring"), origin, "alpha", passphrase
      )
      beta = TinrelaySpec.admit_contact(
        root, origin, "beta", passphrase, alpha
      )
      spool = Tinrelay::Spool.new(File.join(root, "inbox"))
      sent = beta.send("steward@alpha", "waiting at the repeater")

      event = alpha.radio_poll(spool).not_nil!

      event.kind.should eq("transmission")
      spool.get(event.local_id).as(Tinrelay::TransmissionSpoolRecord)
        .signed_transmission.body.should eq("waiting at the repeater")
      api.database.db.query_one(
        "SELECT state, ciphertext IS NULL FROM transmissions WHERE id = ?",
        sent.transmission_id, as: {String, Int64}
      ).should eq({"collected", 1_i64})
    end
  end

  it "collects new relay work while older local work remains unrouted" do
    TinrelaySpec.with_server do |root, origin, _api|
      passphrase = "background radio collection passphrase"
      alpha = Tinrelay::Client.join(
        File.join(root, "alpha.keyring"), origin, "alpha", passphrase
      )
      beta = TinrelaySpec.admit_contact(
        root, origin, "beta", passphrase, alpha
      )
      spool = Tinrelay::Spool.new(File.join(root, "inbox"))
      beta.send("steward@alpha", "first local transmission")
      first = alpha.radio_wait(spool, hold_seconds: 0)
      beta.send("steward@alpha", "second relay transmission")

      second = alpha.radio_collect(spool, hold_seconds: 0)

      second.local_id.should_not eq(first.local_id)
      spool.next_unrouted.not_nil!.local_id.should eq(first.local_id)
      spool.list.count(&.routed_at.nil?).should eq(2)
    end
  end

  it "makes exactly one zero-hold relay attempt and reports quiet" do
    TinrelaySpec.with_server do |root, origin, _api|
      passphrase = "quiet radio poll passphrase"
      ship = Tinrelay::Client.join(
        File.join(root, "ship.keyring"), origin, "ship", passphrase
      )
      remote = RadioPollRemote.new(origin, [Tinrelay::RadioWaitResponse.new])
      client = Tinrelay::Client.new(ship.keyring, passphrase, remote)

      client.radio_poll(Tinrelay::Spool.new(File.join(root, "inbox"))).should be_nil
      remote.holds.should eq([0])
    end
  end
end
