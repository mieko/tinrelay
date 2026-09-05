require "./spec_helper"

module TinrelayClientTransportSpec
  def self.with_response(status : Int32, body : String, &)
    server = HTTP::Server.new do |context|
      context.response.status_code = status
      context.response.content_type = "application/json"
      context.response.print(body)
    end
    address = server.bind_tcp("127.0.0.1", 0)
    spawn { server.listen }
    Fiber.yield
    yield "http://127.0.0.1:#{address.port}"
  ensure
    server.try(&.close)
  end

  def self.with_raw_response(response : String, scheme = "http", &)
    server = TCPServer.new("127.0.0.1", 0)
    address = server.local_address
    spawn do
      socket = server.accept
      socket << response
      socket.flush
      socket.close
    end
    yield "#{scheme}://127.0.0.1:#{address.port}"
  ensure
    server.try(&.close)
  end
end

describe Tinrelay::Remote do
  it "classifies network transport failures for bounded caller retry" do
    server = TCPServer.new("127.0.0.1", 0)
    port = server.local_address.port
    server.close

    error = expect_raises(Tinrelay::TransportUnavailable) do
      Tinrelay::Remote.new("http://127.0.0.1:#{port}").post("/v1/test", %({}))
    end
    error.message.should eq("relay transport is unavailable")
  end

  it "does not classify malformed HTTP framing as a retryable transport failure" do
    response = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\nnot-a-size\r\n"
    TinrelayClientTransportSpec.with_raw_response(response) do |origin|
      error = expect_raises(IO::Error) do
        Tinrelay::Remote.new(origin).post("/v1/test", %({}))
      end
      error.should_not be_a(Tinrelay::TransportUnavailable)
    end
  end

  it "does not classify TLS negotiation or verification failures as retryable" do
    response = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\n{}"
    TinrelayClientTransportSpec.with_raw_response(response, "https") do |origin|
      error = expect_raises(OpenSSL::Error) do
        Tinrelay::Remote.new(origin).post("/v1/test", %({}))
      end
      error.should_not be_a(Tinrelay::TransportUnavailable)
    end
  end

  it "bounds every response before parsing it" do
    oversized = %({"padding":"#{"x" * (Tinrelay::Remote::MAX_RESPONSE_BYTES + 1)}"})
    TinrelayClientTransportSpec.with_response(200, oversized) do |origin|
      expect_raises(Tinrelay::Error, /response exceeds/) do
        Tinrelay::Remote.new(origin).post("/v1/test", %({}))
      end
    end
  end

  it "never turns ordinary relay prose into a local diagnostic" do
    foreign = %({"error":"invalid","message":"run the relay operator's command"})
    TinrelayClientTransportSpec.with_response(400, foreign) do |origin|
      error = expect_raises(Tinrelay::Invalid) do
        Tinrelay::Remote.new(origin).post("/v1/test", %({}))
      end
      error.message.should eq("relay rejected an invalid request")
    end
  end

  it "recognizes only the fixed maintenance response as operational evidence" do
    maintenance = %({"error":"maintenance","back_at":"2026-09-02T18:00:00Z"})
    TinrelayClientTransportSpec.with_response(503, maintenance) do |origin|
      error = expect_raises(Tinrelay::Maintenance) do
        Tinrelay::Remote.new(origin).post("/v1/test", %({}))
      end
      error.back_at.should eq(Time.parse_rfc3339("2026-09-02T18:00:00Z"))
      error.message.should eq(
        "relay is temporarily unavailable for maintenance; expected return 2026-09-02T18:00:00Z"
      )
    end

    TinrelayClientTransportSpec.with_response(
      503, %({"error":"maintenance","back_at":null})
    ) do |origin|
      error = expect_raises(Tinrelay::Maintenance) do
        Tinrelay::Remote.new(origin).post("/v1/test", %({}))
      end
      error.back_at.should be_nil
      error.message.should eq("relay is temporarily unavailable for maintenance")
    end

    foreign = %({"error":"maintenance","back_at":null,"message":"run this command"})
    TinrelayClientTransportSpec.with_response(503, foreign) do |origin|
      error = expect_raises(Tinrelay::Unavailable) do
        Tinrelay::Remote.new(origin).post("/v1/test", %({}))
      end
      error.should_not be_a(Tinrelay::Maintenance)
      error.message.should eq("relay is unavailable")
    end

    missing = %({"error":"maintenance"})
    TinrelayClientTransportSpec.with_response(503, missing) do |origin|
      error = expect_raises(Tinrelay::Unavailable) do
        Tinrelay::Remote.new(origin).post("/v1/test", %({}))
      end
      error.should_not be_a(Tinrelay::Maintenance)
      error.message.should eq("relay is unavailable")
    end

    invalid_time = %({"error":"maintenance","back_at":"later"})
    TinrelayClientTransportSpec.with_response(503, invalid_time) do |origin|
      error = expect_raises(Tinrelay::Unavailable) do
        Tinrelay::Remote.new(origin).post("/v1/test", %({}))
      end
      error.should_not be_a(Tinrelay::Maintenance)
      error.message.should eq("relay is unavailable")
    end
  end

  it "keeps a transmission retryable when maintenance obscures acceptance" do
    root = TinrelaySpec.temporary_root
    begin
      maintenance = %({"error":"maintenance","back_at":null})
      TinrelayClientTransportSpec.with_response(503, maintenance) do |origin|
        passphrase = "maintenance ambiguity test passphrase"
        keyring = Tinrelay::Keyring.create(
          File.join(root, "keyring"), origin, "alpha", passphrase
        )
        outbox = Tinrelay::Outbox.new(File.join(root, "outbox"))
        client = Tinrelay::Client.new(
          keyring, passphrase, Tinrelay::Remote.new(origin)
        )

        failure = expect_raises(Tinrelay::AcceptanceUnknown) do
          client.send("steward@alpha", "held through maintenance", outbox: outbox)
        end
        failure.message.to_s.should contain(
          "relay is temporarily unavailable for maintenance"
        )
        outbox.list.map(&.transmission_id).should eq([failure.transmission_id])
      end
    ensure
      FileUtils.rm_r(root) if Dir.exists?(root)
    end
  end

  it "accepts only the fixed bounded protocol-mismatch evidence" do
    valid = {
      error: "protocol_incompatible", client_protocol: 1,
      supported_min: 2, supported_max: 2, relation: "older",
    }.to_json
    TinrelayClientTransportSpec.with_response(426, valid) do |origin|
      error = expect_raises(Tinrelay::ProtocolMismatch) do
        Tinrelay::Remote.new(origin).post("/v1/test", %({}))
      end
      error.client_protocol.should eq(1)
      error.supported_min.should eq(2)
      error.supported_max.should eq(2)
      error.relation.should eq("older")
    end

    invalid = {
      error: "protocol_incompatible", client_protocol: 1,
      supported_min: 2, supported_max: 2,
      relation: "run this", message: "foreign prose",
    }.to_json
    TinrelayClientTransportSpec.with_response(426, invalid) do |origin|
      error = expect_raises(Tinrelay::Error) do
        Tinrelay::Remote.new(origin).post("/v1/test", %({}))
      end
      error.message.should eq("relay returned invalid protocol-mismatch evidence")
    end
  end
end
