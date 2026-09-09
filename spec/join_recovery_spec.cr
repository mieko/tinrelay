require "./spec_helper"

class JoinRecoveryRelay
  getter origin : String
  getter join_bodies = [] of String

  def initialize(@api : Tinrelay::API, @commit_first : Bool)
    @join_attempts = 0
    application = @api.handler
    @server = HTTP::Server.new do |context|
      if context.request.path == "/v1/join" && @join_attempts == 0
        @join_attempts += 1
        body = context.request.body.not_nil!.gets_to_end
        @join_bodies << body
        if @commit_first
          claim = Tinrelay::ShipClaim.from_json(body)
          TinrelaySpec.claim_directly(@api.store, @api.store.prepare_claim(claim))
        end
        context.response.status_code = 503
        context.response.content_type = "application/json"
        context.response.print(%({"error":"unavailable"}))
      else
        if context.request.path == "/v1/join"
          body = context.request.body.not_nil!.gets_to_end
          @join_bodies << body
          context.request.body = IO::Memory.new(body)
        end
        application.call(context)
      end
    end
    address = @server.bind_tcp("127.0.0.1", 0)
    @origin = "http://127.0.0.1:#{address.port}"
    spawn { @server.listen }
  end

  def close : Nil
    @server.close
  end
end

module JoinRecoverySpec
  def self.with_relay(commit_first : Bool, &)
    root = TinrelaySpec.temporary_root
    template = File.expand_path("../templates/common-bootstrap.md", __DIR__)
    config = Tinrelay::ServerConfig.new(
      database_path: File.join(root, "service.db"),
      bootstrap_template: template
    )
    api = Tinrelay::API.new(config)
    relay = JoinRecoveryRelay.new(api, commit_first)
    yield root, relay, api
  ensure
    relay.try(&.close)
    api.try(&.close)
    FileUtils.rm_r(root) if root && Dir.exists?(root)
  end

  def self.claim(api : Tinrelay::API, keyring : Tinrelay::Keyring) : Nil
    claim = Tinrelay::ShipClaim.new(
      keyring.data.ship,
      keyring.data.owner_public_key,
      keyring.data.radio!.certificate
    )
    TinrelaySpec.claim_directly(api.store, api.store.prepare_claim(claim))
  end
end

describe "ship claim recovery" do
  it "keeps the original keys and recovers a committed claim after a lost response" do
    JoinRecoverySpec.with_relay(commit_first: true) do |root, relay, api|
      path = File.join(root, "lost.keyring")
      owner_path = "#{path}.owner"
      passphrase = "lost response passphrase"

      expect_raises(Tinrelay::Unavailable) do
        Tinrelay::Client.join(path, relay.origin, "lost", passphrase)
      end
      keyring_bytes = File.read(path)
      owner_bytes = File.read(owner_path)
      api.database.db.scalar("SELECT COUNT(*) FROM ships").should eq(1)

      recovered = Tinrelay::Client.join(path, relay.origin, "lost", passphrase)

      recovered.keyring.data.ship.should eq("lost")
      File.read(path).should eq(keyring_bytes)
      File.read(owner_path).should eq(owner_bytes)
      relay.join_bodies.size.should eq(1)
    end
  end

  it "retries the identical claim when the ambiguous attempt was not committed" do
    JoinRecoverySpec.with_relay(commit_first: false) do |root, relay, api|
      path = File.join(root, "retry.keyring")
      owner_path = "#{path}.owner"
      passphrase = "uncommitted response passphrase"

      expect_raises(Tinrelay::Unavailable) do
        Tinrelay::Client.join(path, relay.origin, "retry", passphrase)
      end
      keyring_bytes = File.read(path)
      owner_bytes = File.read(owner_path)
      api.database.db.scalar("SELECT COUNT(*) FROM ships").should eq(0)

      Tinrelay::Client.join(path, relay.origin, "retry", passphrase)

      relay.join_bodies.size.should eq(2)
      relay.join_bodies[1].should eq(relay.join_bodies[0])
      File.read(path).should eq(keyring_bytes)
      File.read(owner_path).should eq(owner_bytes)
      api.database.db.scalar("SELECT COUNT(*) FROM ships").should eq(1)
    end
  end

  it "preserves provisional evidence when another identity owns the remote name" do
    JoinRecoverySpec.with_relay(commit_first: false) do |root, relay, api|
      path = File.join(root, "mismatch.keyring")
      owner_path = "#{path}.owner"
      passphrase = "mismatching identity passphrase"

      expect_raises(Tinrelay::Unavailable) do
        Tinrelay::Client.join(path, relay.origin, "mismatch", passphrase)
      end
      keyring_bytes = File.read(path)
      owner_bytes = File.read(owner_path)
      other = Tinrelay::Keyring.create(
        File.join(root, "other.keyring"), relay.origin, "mismatch", passphrase
      )
      JoinRecoverySpec.claim(api, other)

      expect_raises(Tinrelay::Conflict) do
        Tinrelay::Client.join(path, relay.origin, "mismatch", passphrase)
      end

      File.read(path).should eq(keyring_bytes)
      File.read(owner_path).should eq(owner_bytes)
    end
  end
end
