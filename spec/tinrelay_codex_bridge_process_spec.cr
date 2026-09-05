require "json"
require "socket"
require "file_utils"
require "uuid"

require "./spec_helper"

module TinrelayCodexBridgeProcessSpec
  REPO           = File.expand_path("..", __DIR__)
  BUILD_ROOT     = File.join(Dir.tempdir, "tinrelay-process-spec-#{Process.pid}")
  BINARY         = File.join(BUILD_ROOT, "tinrelay-codex-bridge")
  CLIENT_BINARY  = File.join(BUILD_ROOT, "tinrelay")
  FIXTURE        = File.join(BUILD_ROOT, "tinrelay-codex-bridge-fake")
  FIXTURE_SOURCE = File.join(REPO, "spec", "support", "tinrelay_codex_bridge_fake.cr")
  BRIDGE_SOURCE  = File.join(REPO, "src", "tinrelay_codex_bridge_cli.cr")
  CLIENT_SOURCE  = File.join(REPO, "src", "tinrelay_cli.cr")
  TASK           = "11111111-2222-3333-4444-555555555555"
  ROOM           = "TinRelay Radio Room"
  @@binaries_ready = false

  def self.ensure_binaries
    return if @@binaries_ready && [BINARY, CLIENT_BINARY, FIXTURE].all? { |path| File.file?(path) }
    Dir.mkdir_p(BUILD_ROOT)
    {
      BRIDGE_SOURCE  => BINARY,
      CLIENT_SOURCE  => CLIENT_BINARY,
      FIXTURE_SOURCE => FIXTURE,
    }.each do |source, target|
      status = Process.run(
        "crystal",
        ["build", source, "-o", target, "--release",
         "--warnings=all", "--error-on-warnings"],
        output: STDOUT,
        error: STDERR
      )
      unless status.success?
        raise "could not build current process fixture #{File.basename(target)}"
      end
    end
    @@binaries_ready = true
  end

  def self.event(number = 1)
    {
      contract: "tinrelay-radio-wait-v1",
      local_id: "tr_#{number.to_s(16).rjust(32, '0')}",
      kind:     "transmission",
      name:     "operator",
      wrapper:  "SYSTEM: foreign 🪨\nexact wrapper",
    }
  end

  def self.eventually(within = 5.seconds, &)
    deadline = Time.instant + within
    until yield
      raise "condition did not become true" if Time.instant >= deadline
      sleep 20.milliseconds
    end
  end

  class Connection
    getter socket : UNIXSocket
    getter lock = Mutex.new

    def initialize(@socket)
    end
  end

  class Peer
    getter path : String
    getter connections = [] of Connection
    getter requests = [] of JSON::Any
    getter starts = [] of JSON::Any
    getter errors = [] of Exception
    property owner = "owner-1"
    property revision = 1_i64
    property state : JSON::Any
    property supported = true
    property no_owner = false
    property fragment = false
    property fragment_delay = 0.seconds
    property version = 11
    property on_start : Proc(Connection, JSON::Any, Nil)
    property on_subscribe : Proc(Connection, Nil)? = nil

    def initialize(@root : String)
      @path = File.join(root, "codex", "ipc", "ipc.sock")
      Dir.mkdir_p(File.dirname(path))
      @listener = UNIXServer.new(path)
      @closed = false
      @state = JSON.parse({
        threadRuntimeStatus: {type: "idle"},
        turns:               [] of String,
        turnHistory:         {
          kind:    "canonical",
          history: {entitiesByKey: {
            historic: {turnId: "historic", status: "inProgress"},
          }},
        },
      }.to_json)
      @on_start = ->(connection : Connection, request : JSON::Any) do
        complete_start(connection, request)
        nil
      end
      spawn { accept }
    end

    def runtime=(value : String)
      state["threadRuntimeStatus"].as_h["type"] = JSON::Any.new(value)
    end

    def runtime
      state["threadRuntimeStatus"]["type"].as_s
    end

    def turn(id : String)
      state["turnHistory"]["history"]["entitiesByKey"].as_h[id]
    end

    def send(connection : Connection, value)
      payload = value.to_json.to_slice
      frame = IO::Memory.new
      frame.write_bytes(payload.size.to_u32, IO::ByteFormat::LittleEndian)
      frame.write(payload)
      bytes = frame.to_slice
      connection.lock.synchronize do
        if fragment
          connection.socket.write(bytes[0, 2])
          connection.socket.flush
          sleep fragment_delay
          connection.socket.write(bytes[2, 6])
          connection.socket.flush
          sleep fragment_delay
          connection.socket.write(bytes[8..])
        else
          connection.socket.write(bytes)
        end
        connection.socket.flush
      end
    end

    def reply(connection : Connection, request : JSON::Any, result = nil, error : String? = nil,
              method : String? = nil, handled_by : String? = nil)
      value = {
        "type"              => JSON::Any.new("response"),
        "requestId"         => JSON::Any.new(request["requestId"].as_s),
        "method"            => JSON::Any.new(method || request["method"].as_s),
        "handledByClientId" => JSON::Any.new(handled_by || owner),
        "resultType"        => JSON::Any.new(error ? "error" : "success"),
        "result"            => JSON.parse(result.to_json),
      }
      value["error"] = JSON::Any.new(error) if error
      send(connection, value)
    end

    def stream(connection : Connection? = nil, change : JSON::Any? = nil,
               source : String? = nil, stream_version : Int32? = nil)
      selected = connection || connections.last
      update = change || JSON.parse({
        type: "snapshot", revision: revision, conversationState: state,
      }.to_json)
      send(selected, {
        type:           "broadcast",
        method:         "thread-stream-state-changed",
        version:        stream_version || version,
        sourceClientId: source || owner,
        params:         {hostId: "local", conversationId: TASK, change: update},
      })
    end

    def accept_start(connection : Connection, request : JSON::Any)
      id = "turn-#{starts.size}"
      self.runtime = "active"
      entity = JSON.parse({turnId: id, status: "inProgress"}.to_json)
      state["turnHistory"]["history"]["entitiesByKey"].as_h[id] = entity
      self.revision += 1
      stream(connection)
      reply(connection, request, {result: {turn: {id: id, status: "inProgress"}}})
      id
    end

    def finish(id : String, connection : Connection? = nil, routed = true, terminal = "completed")
      if routed
        request = starts[id.split('-').last.to_i - 1]
        items = request["params"]["turnStart"]["context"]["responseItems"]
        text = items[1]["output"][0]["text"].as_s
        raw = JSON.parse(text)["text"].as_s
        event_id = JSON.parse(raw)["local_id"].as_s
        File.touch(File.join(@root, "#{event_id}.routed"))
      end
      turn(id).as_h["status"] = JSON::Any.new(terminal)
      self.runtime = "idle"
      self.revision += 1
      stream(connection)
    end

    def complete_start(connection : Connection, request : JSON::Any)
      finish(accept_start(connection, request), connection)
    end

    def disconnect(connection : Connection)
      connection.socket.close
    rescue IO::Error
    end

    def write(connection : Connection, bytes : Bytes)
      connection.lock.synchronize do
        connection.socket.write(bytes)
        connection.socket.flush
      end
    end

    def close
      @closed = true
      @listener.close
      connections.each { |connection| disconnect(connection) }
      File.delete(path) if File.exists?(path)
    end

    private def accept
      until @closed
        socket = @listener.accept?
        break unless socket
        connection = Connection.new(socket)
        connections << connection
        spawn { serve(connection) }
      end
    rescue ex : IO::Error
      errors << ex unless @closed
    end

    private def exact(io : IO, count : Int32)
      bytes = Bytes.new(count)
      offset = 0
      while offset < count
        read = io.read(bytes[offset..])
        raise IO::EOFError.new if read == 0
        offset += read
      end
      bytes
    end

    private def serve(connection : Connection)
      loop do
        size = IO::ByteFormat::LittleEndian.decode(UInt32, exact(connection.socket, 4))
        request = JSON.parse(String.new(exact(connection.socket, size.to_i)))
        requests << request
        case request["method"]?.try(&.as_s?)
        when "initialize"
          reply(connection, request, {clientId: "bridge-test-client"})
        when "thread-owner-discovery"
          if no_owner
            reply(connection, request, error: "no-client-found")
          else
            reply(connection, request, {supportsUntrustedAppInput: supported})
          end
        when "thread-stream-following-changed"
          if request["params"]["following"].as_bool
            if callback = on_subscribe
              callback.call(connection)
            else
              stream(connection)
            end
          end
        when "thread-follower-start-turn"
          starts << request
          on_start.call(connection, request)
        end
      end
    rescue IO::EOFError | IO::Error
    rescue ex
      errors << ex
    end
  end

  class ManagedProcess
    getter process : Process

    def initialize(@process)
      @status = nil.as(Process::Status?)
      @done = Channel(Process::Status).new(1)
      spawn do
        status = process.wait
        @status = status
        @done.send(status)
      end
    end

    def running?
      @status.nil? && Process.exists?(process.pid)
    end

    def wait(within = 5.seconds)
      return @status.not_nil! if @status
      select
      when status = @done.receive
        @status = status
        status
      when timeout(within)
        raise "process did not exit"
      end
    end

    def signal(signal : Signal)
      process.signal(signal)
    rescue RuntimeError
    end
  end

  class FixedResponseServer
    getter requests = 0
    getter port : Int32

    def initialize(@status_code : Int32, @body : String, port = 0)
      @server = HTTP::Server.new do |context|
        @requests += 1
        context.response.status_code = @status_code
        context.response.content_type = "application/json"
        context.response.print(@body)
      end
      address = @server.bind_tcp("127.0.0.1", port)
      @port = address.port
      spawn { @server.listen }
      Fiber.yield
    end

    def close
      @server.close
    end
  end

  def self.available_port : Int32
    socket = TCPServer.new("127.0.0.1", 0)
    socket.local_address.as(Socket::IPAddress).port
  ensure
    socket.try(&.close)
  end

  def self.prepare_ship(root : String, origin : String,
                        ship = "fixture") : Tinrelay::LocalPaths
    paths = Tinrelay::LocalPaths.new(ship, root)
    passphrase = "process collector passphrase"
    Tinrelay::Keyring.create(paths.keyring, origin, ship, passphrase, paths.owner_key)
    Tinrelay::AtomicPrivateFile.write(paths.passphrase, passphrase + "\n")
    paths
  end

  def self.start_client(root : String, args : Array(String), label : String)
    ensure_binaries
    output_path = File.join(root, "#{label}.stdout")
    error_path = File.join(root, "#{label}.stderr")
    output = File.open(output_path, "w")
    error = File.open(error_path, "w")
    process = Process.new(
      CLIENT_BINARY,
      args,
      env: ENV.to_h.merge({"HOME" => root}),
      output: output,
      error: error
    )
    output.close
    error.close
    {ManagedProcess.new(process), output_path, error_path}
  end

  class Harness
    getter root : String
    getter peer : Peer
    getter processes = [] of ManagedProcess

    def initialize(root : String? = nil, @tinrelay = FIXTURE)
      TinrelayCodexBridgeProcessSpec.ensure_binaries
      @remove_root = root.nil?
      @root = root || File.join("/tmp", "trcb-#{Process.pid}-#{UUID.random}")
      Dir.mkdir_p(@root)
      @config = JSON.parse(%({"events":[]}))
      save
      @peer = Peer.new(@root)
    end

    def config
      @config.as_h
    end

    def save
      temporary = File.join(root, "fixture.tmp")
      File.write(temporary, @config.to_json)
      File.rename(temporary, File.join(root, "fixture.json"))
    end

    def start(command = "run", extra = [] of String)
      number = processes.size
      stdout = File.join(root, "stdout-#{number}")
      stderr = File.join(root, "stderr-#{number}")
      environment = ENV.to_h.merge({
        "HOME"             => root,
        "CODEX_HOME"       => File.join(root, "codex"),
        "BRIDGE_TEST_ROOT" => root,
      })
      output = File.open(stdout, "w")
      error = File.open(stderr, "w")
      process = Process.new(
        BINARY,
        [command, "--ship", "fixture", "--radio-room-task", TASK,
         "--tinrelay", @tinrelay] + extra,
        env: environment,
        output: output,
        error: error
      )
      output.close
      error.close
      managed = ManagedProcess.new(process)
      processes << managed
      managed
    end

    def calls(action : String? = nil)
      path = File.join(root, "child_calls.jsonl")
      rows = if File.exists?(path)
               File.read_lines(path).map { |line| JSON.parse(line) }
             else
               [] of JSON::Any
             end
      return rows unless action
      rows.select { |row| row["args"].as_a.first(2).map(&.as_s) == ["radio", action] }
    end

    def notifier_calls
      calls.select { |row| row["args"].as_a.map(&.as_s) == [ROOM] }
    end

    def release_notifier(number = 1)
      File.touch(File.join(root, "notify-release-#{number}"))
    end

    def output(number = 0)
      path = File.join(root, "stdout-#{number}")
      File.exists?(path) ? File.read(path) : ""
    end

    def assert_blocked(process : ManagedProcess, reason : String, code = 0)
      process.wait(8.seconds).exit_code.should eq(code)
      output(processes.index!(process)).should contain(%("reason":"#{reason}"))
    end

    def close
      processes.each do |process|
        if process.running?
          process.signal(Signal::TERM)
          begin
            process.wait(4.seconds)
          rescue
            process.signal(Signal::KILL)
            process.wait
          end
        end
      end
      peer.close
      peer.errors.should be_empty
      FileUtils.rm_r(root) if @remove_root
    end
  end
end

include TinrelayCodexBridgeProcessSpec

Spec.after_suite do
  root = TinrelayCodexBridgeProcessSpec::BUILD_ROOT
  FileUtils.rm_r(root) if Dir.exists?(root)
end

private def eventually(within = 5.seconds, &)
  TinrelayCodexBridgeProcessSpec.eventually(within) { yield }
end

private def with_bridge_harness(&)
  harness = TinrelayCodexBridgeProcessSpec::Harness.new
  begin
    yield harness
  ensure
    harness.close
  end
end

private def run_current_client(root : String, args : Array(String))
  TinrelayCodexBridgeProcessSpec.ensure_binaries
  output = IO::Memory.new
  error = IO::Memory.new
  status = Process.run(
    TinrelayCodexBridgeProcessSpec::CLIENT_BINARY,
    args,
    env: ENV.to_h.merge({"HOME" => root}),
    output: output,
    error: error
  )
  {status, output.to_s, error.to_s}
end

describe "tinrelay-codex-bridge process contract" do
  it "retries only transport outages inside the long-lived collector" do
    root = TinrelaySpec.temporary_root
    port = TinrelayCodexBridgeProcessSpec.available_port
    origin = "http://127.0.0.1:#{port}"
    TinrelayCodexBridgeProcessSpec.prepare_ship(root, origin)
    process, _, error_path = TinrelayCodexBridgeProcessSpec.start_client(
      root, ["radio", "collect", "--ship", "fixture"], "transport-retry"
    )
    eventually { File.read(error_path).includes?(%("error":"transport_unavailable")) }
    process.running?.should be_true

    mismatch = {
      error:           "protocol_incompatible",
      client_protocol: Tinrelay::PROTOCOL,
      supported_min:   Tinrelay::PROTOCOL + 1,
      supported_max:   Tinrelay::PROTOCOL + 1,
      relation:        "older",
    }.to_json
    server = TinrelayCodexBridgeProcessSpec::FixedResponseServer.new(426, mismatch, port)

    process.wait(5.seconds).exit_code.should eq(2)
    server.requests.should eq(1)
    error = File.read(error_path)
    error.should contain(%("error":"transport_unavailable"))
    error.should contain(%("error":"protocol_incompatible"))
  ensure
    process.try do |running|
      running.signal(Signal::TERM) if running.running?
    end
    server.try(&.close)
    FileUtils.rm_r(root) if root && Dir.exists?(root)
  end

  it "stops expected collector faults and keeps unexpected failure distinct" do
    terminal_cases = [
      {401, %({"error":"ignored"}), 2, "unauthorized"},
      {200, "{", 1, "unexpected"},
    ]
    terminal_cases.each_with_index do |(status_code, body, exit_code, label), index|
      root = TinrelaySpec.temporary_root
      server = TinrelayCodexBridgeProcessSpec::FixedResponseServer.new(status_code, body)
      TinrelayCodexBridgeProcessSpec.prepare_ship(
        root, "http://127.0.0.1:#{server.port}"
      )
      process, _, error_path = TinrelayCodexBridgeProcessSpec.start_client(
        root, ["radio", "collect", "--ship", "fixture"], "terminal-#{index}"
      )

      process.wait(5.seconds).exit_code.should eq(exit_code)
      server.requests.should eq(1)
      error = File.read(error_path)
      if label == "unauthorized"
        error.should contain(%("error":"unauthorized"))
      else
        error.should_not contain(%("retryable":true))
      end
    ensure
      process.try do |running|
        running.signal(Signal::TERM) if running.running?
      end
      server.try(&.close)
      FileUtils.rm_r(root) if root && Dir.exists?(root)
    end

    root = TinrelaySpec.temporary_root
    process, _, error_path = TinrelayCodexBridgeProcessSpec.start_client(
      root, ["radio", "collect", "--ship", "fixture"], "local-terminal"
    )
    process.wait(5.seconds).exit_code.should eq(2)
    File.read(error_path).should contain(%("error":"invalid"))
  ensure
    process.try do |running|
      running.signal(Signal::TERM) if running.running?
    end
    FileUtils.rm_r(root) if root && Dir.exists?(root)
  end

  it "reads a real local spool without a keyring or passphrase" do
    root = TinrelaySpec.temporary_root
    paths = Tinrelay::LocalPaths.new("fixture", root)
    spool = Tinrelay::Spool.new(paths.spool)
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

    status, output, error = run_current_client(
      root, ["radio", "wait", "--local", "--ship", "fixture"]
    )

    status.success?.should be_true
    error.should be_empty
    event = Tinrelay::RadioEvent.from_json(output)
    event.local_id.should eq(record.local_id)
    event.kind.should eq("rejected_transmission")
    event.wrapper.should contain("TINRELAY REJECTED TRANSMISSION POINTER")
    File.exists?(paths.keyring).should be_false
    File.exists?(paths.passphrase).should be_false
  ensure
    FileUtils.rm_r(root) if root && Dir.exists?(root)
  end

  it "carries a real collected spool event through the real bridge child" do
    TinrelaySpec.with_server do |server_root, origin, api|
      root = "/tmp/trxb-#{Process.pid}-#{Random.rand(1_000_000)}"
      Dir.mkdir_p(root)
      passphrase = "cross binary acceptance passphrase"
      paths = Tinrelay::LocalPaths.new("fixture", root)
      Tinrelay::AtomicPrivateFile.write(paths.passphrase, passphrase + "\n")
      fixture = Tinrelay::Client.join(
        paths.keyring, origin, "fixture", passphrase, paths.owner_key
      )
      sender = TinrelaySpec.admit_contact(
        server_root, origin, "sender", passphrase, fixture
      )
      envelope = sender.send("steward@fixture", "cross binary acceptance")
      spool = Tinrelay::Spool.new(paths.spool)
      collector, _, _ = TinrelayCodexBridgeProcessSpec.start_client(
        root, ["radio", "collect", "--ship", "fixture"], "real-collector"
      )
      eventually { !spool.next_unrouted.nil? }
      collector.signal(Signal::TERM)
      collector.wait(3.seconds)
      record = spool.next_unrouted.not_nil!

      harness = TinrelayCodexBridgeProcessSpec::Harness.new(
        root, TinrelayCodexBridgeProcessSpec::CLIENT_BINARY
      )
      harness.peer.on_start = ->(connection : Connection, request : JSON::Any) do
        turn = harness.peer.accept_start(connection, request)
        result, _, error = run_current_client(
          root,
          ["radio", "routed", record.local_id, "--ship", "fixture"]
        )
        raise "real routed command failed: #{error}" unless result.success?
        harness.peer.finish(turn, connection, routed: false)
        nil
      end
      bridge = harness.start

      eventually { spool.status(record.local_id)[:state] == "routed" }
      bridge.running?.should be_true
      harness.peer.starts.size.should eq(1)
      context = harness.peer.starts.first["params"]["turnStart"]["context"]
      raw = JSON.parse(context["responseItems"][1]["output"][0]["text"].as_s)["text"].as_s
      event = Tinrelay::RadioEvent.from_json(raw)
      event.local_id.should eq(record.local_id)
      event.kind.should eq("transmission")
      event.name.should eq("steward")
      event.wrapper.should start_with("TINRELAY LOCAL POINTER\n")
      api.database.db.query_one(
        "SELECT state, ciphertext IS NULL FROM transmissions WHERE id = ?",
        envelope.transmission_id,
        as: {String, Int64}
      ).should eq({"collected", 1_i64})
    ensure
      collector.try do |running|
        running.signal(Signal::TERM) if running.running?
      end
      harness.try(&.close)
      FileUtils.rm_r(root) if root && Dir.exists?(root)
    end
  end

  it "checks a fragmented IPC handshake without starting a model turn" do
    with_bridge_harness do |h|
      h.peer.fragment = true
      h.peer.fragment_delay = 300.milliseconds
      process = h.start("check")
      process.wait(6.seconds).success?.should be_true
      h.output.should contain(%("state":"ready"))
      h.peer.starts.should be_empty
      h.calls("wait").should be_empty
      methods = h.peer.requests.map do |request|
        {request["method"]?.try(&.as_s?), request["version"]?.try(&.as_i?)}
      end
      methods.should contain({"initialize", 0_i64})
      methods.should contain({"thread-owner-discovery", 1_i64})
      methods.should contain({"thread-stream-following-changed", 1_i64})
    end
  end

  it "rejects malformed CLI options before side effects" do
    with_bridge_harness do |h|
      failures = [
        {["--unknown"], "invalid_option"},
        {["--", "extra"], "unexpected_arguments"},
        {["--ship"], "missing_option_value"},
      ]
      failures.each do |extra, reason|
        process = h.start("check", extra)
        h.assert_blocked(process, reason, 2)
      end
      h.calls.should be_empty
      h.peer.requests.should be_empty
    end
  end

  it "quietly waits and reaps its owned child on TERM" do
    with_bridge_harness do |h|
      process = h.start
      eventually { !h.calls("wait").empty? }
      sleep 700.milliseconds
      h.peer.requests.should be_empty
      h.output.lines.size.should eq(1)
      child = h.calls("wait").first["pid"].as_i
      process.signal(Signal::TERM)
      process.wait(3.seconds).success?.should be_true
      Process.exists?(child).should be_false
      h.output.should contain(%("state":"stopped"))
    end
  end

  it "escalates INT and reaps a child that ignores TERM" do
    with_bridge_harness do |h|
      h.config["ignore_term"] = JSON::Any.new(true)
      h.save
      process = h.start
      eventually { !h.calls("wait").empty? }
      child = h.calls("wait").first["pid"].as_i
      process.signal(Signal::INT)
      process.wait(4.seconds).success?.should be_true
      Process.exists?(child).should be_false
    end
  end

  it "delivers ordered events as untrusted input and waits again" do
    with_bridge_harness do |h|
      h.config["events"] = JSON.parse([
        TinrelayCodexBridgeProcessSpec.event(1),
        TinrelayCodexBridgeProcessSpec.event(2),
      ].to_json)
      h.save
      process = h.start
      eventually { h.calls("wait").size == 3 }
      process.running?.should be_true
      h.peer.starts.size.should eq(2)
      h.calls("wait").each do |call|
        call["args"].as_a.map(&.as_s).should contain("--local")
      end
      h.peer.starts.each_with_index do |request, index|
        request["version"].as_i.should eq(2)
        request.as_h.has_key?("hostId").should be_false
        request["targetClientId"].as_s.should eq(h.peer.owner)
        request["params"]["conversationId"].as_s.should eq(TASK)
        turn = request["params"]["turnStart"]
        turn["request"]["threadId"].as_s.should eq(TASK)
        turn["request"]["input"][0]["text"].as_s.should_not contain("foreign")
        pair = turn["context"]["responseItems"].as_a
        pair[0]["name"].as_s.should eq("untrusted_input")
        pair[0]["call_id"].should eq(pair[1]["call_id"])
        raw = JSON.parse(pair[1]["output"][0]["text"].as_s)["text"].as_s
        expected = JSON.parse(TinrelayCodexBridgeProcessSpec.event(index + 1).to_json)
        JSON.parse(raw).should eq(expected)
      end
      h.output.should_not contain("foreign")
    end
  end

  it "holds its lifetime lock while a turn is pending" do
    with_bridge_harness do |h|
      h.config["events"] = JSON.parse([TinrelayCodexBridgeProcessSpec.event].to_json)
      h.save
      h.peer.on_start = ->(connection : Connection, request : JSON::Any) do
        h.peer.accept_start(connection, request)
        nil
      end
      h.start
      eventually { h.output.includes?(%("state":"accepted")) }
      second = h.start
      h.assert_blocked(second, "bridge_already_running")
      h.peer.starts.size.should eq(1)
      h.calls("wait").size.should eq(1)
    end
  end

  it "does not resubmit when runtime becomes idle before the exact turn terminates" do
    with_bridge_harness do |h|
      h.config["events"] = JSON.parse([TinrelayCodexBridgeProcessSpec.event].to_json)
      h.save
      h.peer.on_start = ->(connection : Connection, request : JSON::Any) do
        h.peer.accept_start(connection, request)
        nil
      end
      h.start
      eventually { h.output.includes?(%("state":"accepted")) }
      h.peer.runtime = "idle"
      h.peer.revision += 1
      h.peer.stream
      sleep 300.milliseconds
      h.calls("status").size.should eq(2)
      h.peer.starts.size.should eq(1)
      h.peer.finish("turn-1")
      eventually { h.calls("wait").size == 2 }
    end
  end

  it "waits for an observed idle destination before submitting" do
    with_bridge_harness do |h|
      h.config["events"] = JSON.parse([TinrelayCodexBridgeProcessSpec.event].to_json)
      h.save
      h.peer.runtime = "active"
      h.start
      eventually do
        h.peer.requests.any? do |request|
          request["method"]?.try(&.as_s?) == "thread-stream-following-changed"
        end
      end
      h.peer.starts.should be_empty
      h.peer.runtime = "idle"
      h.peer.revision += 1
      h.peer.stream
      eventually { h.calls("wait").size == 2 }
      h.peer.starts.size.should eq(1)
    end
  end

  it "refreshes lifecycle state after a busy submission race" do
    with_bridge_harness do |h|
      h.config["events"] = JSON.parse([TinrelayCodexBridgeProcessSpec.event].to_json)
      h.save
      h.peer.on_start = ->(connection : Connection, request : JSON::Any) do
        h.peer.runtime = "active"
        h.peer.reply(
          connection,
          request,
          error: "App context must wait until the current turn finishes"
        )
        h.peer.on_start = ->(next_connection : Connection, next_request : JSON::Any) do
          h.peer.complete_start(next_connection, next_request)
          nil
        end
        nil
      end
      h.start
      eventually do
        h.peer.requests.count do |request|
          request["method"]?.try(&.as_s?) == "thread-stream-following-changed"
        end >= 2
      end
      h.peer.starts.size.should eq(1)
      h.peer.runtime = "idle"
      h.peer.revision += 1
      h.peer.stream
      eventually { h.calls("wait").size == 2 }
      h.peer.starts.size.should eq(2)
    end
  end

  it "rediscovers state after a busy rejection followed by disconnect" do
    with_bridge_harness do |h|
      h.config["events"] = JSON.parse([TinrelayCodexBridgeProcessSpec.event].to_json)
      h.save
      h.peer.on_start = ->(connection : Connection, request : JSON::Any) do
        h.peer.reply(
          connection,
          request,
          error: "App context must wait until the current turn finishes"
        )
        h.peer.on_start = ->(next_connection : Connection, next_request : JSON::Any) do
          h.peer.complete_start(next_connection, next_request)
          nil
        end
        h.peer.disconnect(connection)
        nil
      end
      h.start
      eventually { h.calls("wait").size == 2 }
      h.peer.starts.size.should eq(2)
    end
  end

  it "stops after two unrouted terminal turns" do
    with_bridge_harness do |h|
      h.config["events"] = JSON.parse([TinrelayCodexBridgeProcessSpec.event].to_json)
      h.save
      h.peer.on_start = ->(connection : Connection, request : JSON::Any) do
        h.peer.finish(
          h.peer.accept_start(connection, request),
          connection,
          routed: false,
          terminal: "failed"
        )
        nil
      end
      process = h.start
      h.assert_blocked(process, "recovery_exhausted")
      h.peer.starts.size.should eq(2)
      h.calls("wait").size.should eq(1)
    end
  end

  it "uses a second turn to recover an interrupted unrouted turn" do
    with_bridge_harness do |h|
      h.config["events"] = JSON.parse([TinrelayCodexBridgeProcessSpec.event].to_json)
      h.save
      h.peer.on_start = ->(connection : Connection, request : JSON::Any) do
        h.peer.finish(
          h.peer.accept_start(connection, request),
          connection,
          routed: false,
          terminal: "interrupted"
        )
        h.peer.on_start = ->(next_connection : Connection, next_request : JSON::Any) do
          h.peer.complete_start(next_connection, next_request)
          nil
        end
        nil
      end
      h.start
      eventually { h.calls("wait").size == 2 }
      h.peer.starts.size.should eq(2)
    end
  end

  it "does not replay a submission with an ambiguous outcome" do
    with_bridge_harness do |h|
      h.config["events"] = JSON.parse([TinrelayCodexBridgeProcessSpec.event].to_json)
      h.save
      h.peer.on_start = ->(connection : Connection, request : JSON::Any) do
        h.peer.owner = "owner-new"
        h.peer.disconnect(connection)
        nil
      end
      process = h.start
      h.assert_blocked(process, "submission_outcome_unknown")
      h.peer.starts.size.should eq(1)
    end
  end

  it "reconciles a routed submission whose IPC acceptance was ambiguous" do
    with_bridge_harness do |h|
      event = TinrelayCodexBridgeProcessSpec.event
      h.config["events"] = JSON.parse([event].to_json)
      h.save
      h.peer.on_start = ->(connection : Connection, request : JSON::Any) do
        File.touch(File.join(h.root, "#{event[:local_id]}.routed"))
        h.peer.disconnect(connection)
        nil
      end
      h.start
      eventually { h.calls("wait").size == 2 }
      h.peer.starts.size.should eq(1)
    end
  end

  it "rediscovers the task owner after an accepted turn disconnects" do
    with_bridge_harness do |h|
      event = TinrelayCodexBridgeProcessSpec.event
      h.config["events"] = JSON.parse([event].to_json)
      h.save
      h.peer.on_start = ->(connection : Connection, request : JSON::Any) do
        id = h.peer.accept_start(connection, request)
        File.touch(File.join(h.root, "#{event[:local_id]}.routed"))
        h.peer.turn(id).as_h["status"] = JSON::Any.new("completed")
        h.peer.runtime = "idle"
        h.peer.revision += 1
        h.peer.owner = "owner-2"
        h.peer.disconnect(connection)
        nil
      end
      h.start
      eventually { h.calls("wait").size == 2 }
      h.peer.starts.size.should eq(1)
      h.peer.connections.size.should be >= 2
      h.peer.requests.any? do |request|
        clients = request["targetClientIds"]?.try(&.as_a?)
        clients.try(&.map(&.as_s)) == ["owner-2"]
      end.should be_true
    end
  end

  it "times out an unacknowledged submission without resending it" do
    with_bridge_harness do |h|
      h.config["events"] = JSON.parse([TinrelayCodexBridgeProcessSpec.event].to_json)
      h.save
      h.peer.on_start = ->(_connection : Connection, _request : JSON::Any) { nil }
      process = h.start
      process.wait(24.seconds).success?.should be_true
      h.output.should contain(%("reason":"submission_outcome_unknown"))
      h.peer.starts.size.should eq(1)
      h.peer.connections.size.should be >= 2
    end
  end

  it "delivers when Desktop appears after starting absent" do
    with_bridge_harness do |h|
      event = TinrelayCodexBridgeProcessSpec.event
      h.config["events"] = JSON.parse([event].to_json)
      h.save
      saved = "#{h.peer.path}.paused"
      File.rename(h.peer.path, saved)
      process = h.start
      eventually { h.output.includes?(%("reason":"codex_socket_unavailable")) }
      process.running?.should be_true
      File.exists?(File.join(h.root, "#{event[:local_id]}.routed")).should be_false
      h.calls("wait").size.should eq(1)
      h.peer.starts.should be_empty
      File.rename(saved, h.peer.path)
      eventually { h.calls("wait").size == 2 }
      h.peer.starts.size.should eq(1)
    end
  end

  it "delivers when the configured Desktop owner appears" do
    with_bridge_harness do |h|
      event = TinrelayCodexBridgeProcessSpec.event
      h.config["events"] = JSON.parse([event].to_json)
      h.save
      h.peer.no_owner = true
      process = h.start
      eventually { h.output.includes?(%("reason":"no_compatible_task_owner")) }
      process.running?.should be_true
      File.exists?(File.join(h.root, "#{event[:local_id]}.routed")).should be_false
      h.calls("wait").size.should eq(1)
      h.peer.starts.should be_empty
      h.peer.no_owner = false
      eventually { h.calls("wait").size == 2 }
      h.peer.starts.size.should eq(1)
    end
  end

  it "blocks in a local notifier until the radio room becomes available" do
    with_bridge_harness do |h|
      event = TinrelayCodexBridgeProcessSpec.event
      h.config["events"] = JSON.parse([event].to_json)
      h.save
      h.peer.no_owner = true
      process = h.start(extra: [
        "--notify-command", FIXTURE, "--radio-room-name", ROOM,
      ])
      eventually { h.notifier_calls.size == 1 }
      process.running?.should be_true
      h.notifier_calls[0]["args"].as_a.map(&.as_s).should eq([ROOM])
      File.exists?(File.join(h.root, "#{event[:local_id]}.routed")).should be_false

      h.peer.no_owner = false
      h.release_notifier
      eventually { h.calls("wait").size == 2 }
      h.peer.starts.size.should eq(1)
    end
  end

  it "waits without another prompt after the user says they will open the room" do
    with_bridge_harness do |h|
      h.config["events"] = JSON.parse([TinrelayCodexBridgeProcessSpec.event].to_json)
      h.save
      h.peer.no_owner = true
      h.start(extra: [
        "--notify-command", FIXTURE, "--radio-room-name", ROOM,
      ])
      eventually { h.notifier_calls.size == 1 }
      h.release_notifier
      eventually do
        h.peer.requests.count do |request|
          request["method"]?.try(&.as_s?) == "thread-owner-discovery"
        end >= 2
      end
      h.notifier_calls.size.should eq(1)
      h.peer.starts.should be_empty
    end
  end

  it "changes only the reminder cooldown when the user chooses Not Today" do
    with_bridge_harness do |h|
      event = TinrelayCodexBridgeProcessSpec.event
      h.config["events"] = JSON.parse([event].to_json)
      h.config["notifier_choice"] = JSON::Any.new("not_today")
      h.save
      h.peer.no_owner = true
      process = h.start(extra: [
        "--notify-command", FIXTURE, "--radio-room-name", ROOM,
      ])
      eventually { h.notifier_calls.size == 1 }
      h.peer.no_owner = false
      h.release_notifier
      eventually { h.output.includes?(%("state":"radio_room_reminder_deferred")) }
      h.output.should contain(%("reason":"twenty_four_hours"))
      process.running?.should be_true
      eventually { h.calls("wait").size == 2 }
      h.peer.starts.size.should eq(1)
    end
  end

  it "leaves the event pending when its configured notifier fails" do
    with_bridge_harness do |h|
      event = TinrelayCodexBridgeProcessSpec.event
      h.config["events"] = JSON.parse([event].to_json)
      h.config["notifier_failure"] = JSON::Any.new(true)
      h.save
      h.peer.no_owner = true
      process = h.start(extra: [
        "--notify-command", FIXTURE, "--radio-room-name", ROOM,
      ])
      eventually { h.notifier_calls.size == 1 }
      h.release_notifier
      h.assert_blocked(process, "notifier_failed")
      File.exists?(File.join(h.root, "#{event[:local_id]}.routed")).should be_false
      h.peer.starts.should be_empty
    end
  end

  it "rejects an IPC response for the wrong method" do
    with_bridge_harness do |h|
      h.config["events"] = JSON.parse([TinrelayCodexBridgeProcessSpec.event].to_json)
      h.save
      h.peer.on_start = ->(connection : Connection, request : JSON::Any) do
        h.peer.reply(connection, request, {} of String => String, method: "unrelated")
        nil
      end
      process = h.start
      h.assert_blocked(process, "ipc_response_method_mismatch")
    end
  end

  it "rejects an oversized IPC frame declaration" do
    with_bridge_harness do |h|
      h.peer.on_subscribe = ->(connection : Connection) do
        frame = IO::Memory.new
        frame.write_bytes(268_435_457_u32, IO::ByteFormat::LittleEndian)
        h.peer.write(connection, frame.to_slice)
        nil
      end
      process = h.start("check")
      h.assert_blocked(process, "invalid_ipc_frame_length", 2)
    end
  end

  it "requires a fresh snapshot before rejecting an unknown runtime" do
    with_bridge_harness do |h|
      h.peer.runtime = "new-unknown-state"
      process = h.start("check")
      h.assert_blocked(process, "unknown_task_runtime", 2)
      h.peer.requests.count do |request|
        request["params"]?.try { |params| params["following"]?.try(&.as_bool?) } == true
      end.should eq(2)
    end
  end

  it "rejects an accepted turn absent from fresh lifecycle history" do
    with_bridge_harness do |h|
      h.config["events"] = JSON.parse([TinrelayCodexBridgeProcessSpec.event].to_json)
      h.save
      h.peer.on_start = ->(connection : Connection, request : JSON::Any) do
        h.peer.reply(connection, request, {result: {turn: {id: "missing"}}})
        nil
      end
      process = h.start
      h.assert_blocked(process, "accepted_turn_unresolved")
      h.peer.starts.size.should eq(1)
    end
  end

  it "reconciles a pending event after the original bridge is restarted" do
    with_bridge_harness do |h|
      h.config["events"] = JSON.parse([TinrelayCodexBridgeProcessSpec.event].to_json)
      h.save
      h.peer.on_start = ->(connection : Connection, request : JSON::Any) do
        h.peer.accept_start(connection, request)
        nil
      end
      first = h.start
      eventually { h.output.includes?(%("state":"accepted")) }
      first.signal(Signal::TERM)
      first.wait(3.seconds).success?.should be_true
      h.start
      eventually { h.peer.connections.size >= 2 }
      sleep 200.milliseconds
      h.peer.starts.size.should eq(1)
      h.peer.finish("turn-1")
      eventually { h.calls("wait").size == 3 }
      h.peer.starts.size.should eq(1)
    end
  end

  it "requires a snapshot after a lifecycle revision gap" do
    with_bridge_harness do |h|
      h.config["events"] = JSON.parse([TinrelayCodexBridgeProcessSpec.event].to_json)
      h.save
      h.peer.runtime = "active"
      h.start
      eventually do
        h.peer.requests.any? do |request|
          request["method"]?.try(&.as_s?) == "thread-stream-following-changed"
        end
      end
      change = JSON.parse({
        type:         "patches",
        baseRevision: 2,
        revision:     3,
        patches:      [{
          op: "replace", path: ["threadRuntimeStatus", "type"], value: "idle",
        }],
      }.to_json)
      h.peer.stream(change: change)
      eventually do
        h.peer.requests.count do |request|
          request["method"]?.try(&.as_s?) == "thread-stream-following-changed"
        end == 2
      end
      h.peer.starts.should be_empty
      h.peer.runtime = "idle"
      h.peer.revision = 4
      h.peer.stream
      eventually { h.calls("wait").size == 2 }
    end
  end

  it "ignores unrelated broadcasts and declines client discovery" do
    with_bridge_harness do |h|
      h.peer.on_subscribe = ->(connection : Connection) do
        h.peer.send(connection, {
          type: "broadcast", method: "unrelated",
          params: {text: "x" * 2_000_000},
        })
        h.peer.send(connection, {type: "client-discovery-request", requestId: "who-handles-this"})
        h.peer.stream(connection, source: "other-owner", stream_version: 999)
        h.peer.stream(connection)
        nil
      end
      process = h.start("check")
      process.wait(5.seconds).success?.should be_true
      eventually do
        h.peer.requests.any? do |request|
          request["type"]?.try(&.as_s?) == "client-discovery-response"
        end
      end
      answer = h.peer.requests.find do |request|
        request["type"]?.try(&.as_s?) == "client-discovery-response"
      end.not_nil!
      answer["response"].should eq(JSON.parse(%({"canHandle":false})))
      h.output.bytesize.should be < 1_000
    end
  end

  it "rejects malformed, incompatible, and untrusted IPC peers before a model turn" do
    with_bridge_harness do |h|
      h.peer.no_owner = true
      process = h.start("check")
      h.assert_blocked(process, "no_compatible_task_owner", 2)
      h.peer.starts.should be_empty
    end
    with_bridge_harness do |h|
      h.peer.supported = false
      process = h.start("check")
      h.assert_blocked(process, "untrusted_input_unsupported", 2)
    end
    with_bridge_harness do |h|
      h.peer.version = 12
      process = h.start("check")
      h.assert_blocked(process, "unsupported_lifecycle_version", 2)
    end
  end

  it "does not reinterpret a failed local wait as a relay retry" do
    with_bridge_harness do |h|
      h.config["child_error"] = JSON.parse({
        error: "transport_unavailable", retryable: true, message: "secret-value",
      }.to_json)
      h.save
      process = h.start
      h.assert_blocked(process, "tinrelay_local_wait_failed")
      h.output.should_not contain("secret-value")
    end
  end

  it "rejects invalid radio output and mismatched status before submission" do
    with_bridge_harness do |h|
      h.config["raw_output"] = JSON::Any.new("[]")
      h.save
      process = h.start
      h.assert_blocked(process, "invalid_radio_event")
      h.peer.starts.should be_empty
    end
    with_bridge_harness do |h|
      h.config["events"] = JSON.parse([TinrelayCodexBridgeProcessSpec.event].to_json)
      h.config["status_override"] = JSON.parse({
        local_id: TinrelayCodexBridgeProcessSpec.event(2)[:local_id],
      }.to_json)
      h.save
      process = h.start
      h.assert_blocked(process, "status_id_mismatch")
      h.peer.starts.should be_empty
    end
  end

  it "does not accept a turn acknowledgement from the wrong task owner" do
    with_bridge_harness do |h|
      h.config["events"] = JSON.parse([TinrelayCodexBridgeProcessSpec.event].to_json)
      h.save
      h.peer.on_start = ->(connection : Connection, request : JSON::Any) do
        h.peer.reply(connection, request, {result: {turn: {id: "wrong"}}}, handled_by: "impostor")
        nil
      end
      process = h.start
      h.assert_blocked(process, "ipc_response_owner_mismatch")
      h.output.should_not contain(%("state":"accepted"))
    end
  end

  it "bounds child output and does not mistake inherited pipes for child completion" do
    with_bridge_harness do |h|
      h.config["huge_output"] = JSON::Any.new(true)
      h.save
      process = h.start
      h.assert_blocked(process, "tinrelay_capture_failure")
      Process.exists?(h.calls("wait").first["pid"].as_i).should be_false
    end
    with_bridge_harness do |h|
      h.config["hold_pipe"] = JSON::Any.new(true)
      h.save
      process = h.start
      h.assert_blocked(process, "tinrelay_pipe_not_closed")
      h.peer.starts.should be_empty
    end
  end
end
