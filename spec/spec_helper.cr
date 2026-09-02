require "spec"
require "file_utils"
require "../src/tinrelay/client_runtime"
require "../src/tinrelay/server"

module TinrelaySpec
  def self.temporary_root : String
    root = File.join(Dir.tempdir, "tinrelay-spec-#{Process.pid}-#{Tinrelay::Ids.uuid}")
    Dir.mkdir_p(root)
    root
  end

  def self.with_server(art_manifest_path : String? = nil, &)
    root = temporary_root
    template = File.expand_path("../templates/common-bootstrap.md", __DIR__)
    token = "bootstrap-token-for-tests"
    config = Tinrelay::ServerConfig.new(
      "127.0.0.1", 0, File.join(root, "service.db"),
      Digest::SHA256.digest(token), template,
      "https://example.test/tinrelay.git", System.cpu_count,
      art_manifest_path
    )
    api = Tinrelay::API.new(config)
    server = HTTP::Server.new(api.handler)
    address = server.bind_tcp("127.0.0.1", 0)
    spawn { server.listen }
    Fiber.yield
    origin = "http://127.0.0.1:#{address.port}"
    begin
      yield root, token, origin, api
    ensure
      server.close
      api.close
      FileUtils.rm_r(root) if Dir.exists?(root)
    end
  end

  def self.radio_auth(client : Tinrelay::Client, action : String,
                      payload : Bytes, now : Int64 = Time.utc.to_unix) : Tinrelay::RadioAuth
    radio = client.keyring.data.radio!
    auth = Tinrelay::RadioAuth.new(
      client.keyring.data.ship, radio.generation, now
    )
    auth.signature = Tinrelay::Crypto.b64(
      Tinrelay::Crypto.sign(
        auth.signing_bytes(action, payload),
        Tinrelay::Crypto.unb64(radio.signing.secret_key)
      )
    )
    auth
  end

  def self.receive(channel : Channel(T), within = 3.seconds) : T forall T
    select
    when value = channel.receive
      value
    when timeout(within)
      raise "timed out waiting for a test channel"
    end
  end

  def self.eventually(within = 3.seconds, &) : Nil
    deadline = Time.instant + within
    until yield
      raise "timed out waiting for a causal test condition" if Time.instant >= deadline
      Fiber.yield
    end
  end

  def self.radio_wait_request(client : Tinrelay::Client,
                              hold_seconds : Int32) : Tinrelay::RadioWaitRequest
    known = client.keyring.data.contacts.to_h do |contact|
      {contact.ship, contact.radio_certificate.generation}
    end
    placeholder = Tinrelay::RadioAuth.new(
      client.keyring.data.ship,
      client.keyring.data.active_radio_generation,
      0_i64
    )
    request = Tinrelay::RadioWaitRequest.new(
      hold_seconds, placeholder, known_contact_generations: known
    )
    request.auth = radio_auth(client, "radio.wait", request.payload)
    request
  end

  def self.admit(root : String, origin : String, api : Tinrelay::API,
                 ship : String, passphrase : String) : Tinrelay::Client
    secret_bytes = Tinrelay::Crypto.random(32)
    secret = Tinrelay::Crypto.b64(secret_bytes)
    id = Tinrelay::Ids.uuid
    expires_at = Time.utc.to_unix + 3600
    api.store.create_admission(
      id, ship, Digest::SHA256.digest(secret_bytes), expires_at
    )
    admission = Tinrelay::ShipAdmission.new(
      origin, id, ship, secret, expires_at
    )
    capability = "#{origin}/meet##{Base64.urlsafe_encode(admission.to_json, padding: false)}"
    Tinrelay::Client.join(
      File.join(root, "#{ship}.keyring"), capability, ship, passphrase
    )
  end

  def self.admit_contact(root : String, origin : String, api : Tinrelay::API,
                         ship : String, passphrase : String,
                         invitation : String) : Tinrelay::Client
    client = admit(root, origin, api, ship, passphrase)
    client.pin_invitation(invitation)
    client
  end
end
