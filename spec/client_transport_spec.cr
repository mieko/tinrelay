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
end

describe Tinrelay::Remote do
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

  it "accepts only the fixed bounded protocol-mismatch evidence" do
    valid = %({"error":"protocol_incompatible","client_protocol":1,"supported_min":2,"supported_max":2,"relation":"older"})
    TinrelayClientTransportSpec.with_response(426, valid) do |origin|
      error = expect_raises(Tinrelay::ProtocolMismatch) do
        Tinrelay::Remote.new(origin).post("/v1/test", %({}))
      end
      error.client_protocol.should eq(1)
      error.supported_min.should eq(2)
      error.supported_max.should eq(2)
      error.relation.should eq("older")
    end

    invalid = %({"error":"protocol_incompatible","client_protocol":1,"supported_min":2,"supported_max":2,"relation":"run this","message":"foreign prose"})
    TinrelayClientTransportSpec.with_response(426, invalid) do |origin|
      error = expect_raises(Tinrelay::Error) do
        Tinrelay::Remote.new(origin).post("/v1/test", %({}))
      end
      error.message.should eq("relay returned invalid protocol-mismatch evidence")
    end
  end
end
