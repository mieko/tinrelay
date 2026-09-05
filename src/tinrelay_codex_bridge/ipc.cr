module TinrelayCodexBridge
  class IPC
    MAX_FRAME       = 268_435_456
    REQUEST_TIMEOUT = 20.seconds
    getter lifecycle = Lifecycle.new
    @client = ""
    @owner = ""
    @subscribed = false

    def initialize(@socket : CodexTransport, @task : String, @control : Control)
      handshake
    end

    private def handshake
      @socket.read_timeout = 250.milliseconds
      @socket.write_timeout = 2.seconds
      response = rpc("initialize", {clientType: "tinrelay-codex-bridge"}, 0)
      @client = response.as_h["result"].as_h["clientId"].as_s
      raise Blocked.new("invalid_client_id") if @client.empty?
      response = rpc("thread-owner-discovery", {hostId: "local", conversationId: @task}, 1)
      @owner = response.as_h["handledByClientId"].as_s
      raise Blocked.new("invalid_owner_id") if @owner.empty?
      unless response.as_h["result"].as_h["supportsUntrustedAppInput"].as_bool
        raise Blocked.new("untrusted_input_unsupported")
      end
    rescue TypeCastError | KeyError
      raise Blocked.new("invalid_ipc_handshake")
    end

    def subscribe
      @subscribed = true
      refresh
    end

    def refresh
      lifecycle.invalidate
      following(true)
      deadline = Time.instant + REQUEST_TIMEOUT
      while lifecycle.revision.nil?
        receive(deadline)
      end
    rescue Deadline
      raise Blocked.new("lifecycle_snapshot_unavailable")
    end

    def close
      begin
        following(false) if @subscribed && !@socket.closed?
      rescue Disconnected | Stopped
      ensure
        @socket.close
      end
    end

    private def following(value)
      send_frame({type: "broadcast", method: "thread-stream-following-changed", version: 1,
                  sourceClientId: @client, targetClientIds: [@owner],
                  params: {hostId: "local", conversationId: @task, following: value}})
    end

    private def rpc(method, params, version, target : String? = nil)
      request_id = UUID.random.to_s
      message = JSON.parse({type: "request", requestId: request_id, method: method,
                            params: params, version: version, timeoutMs: 20_000}.to_json)
      message.as_h["sourceClientId"] = JSON::Any.new(@client) unless @client.empty?
      message.as_h["targetClientId"] = JSON::Any.new(target) if target
      send_frame(message)
      deadline = Time.instant + REQUEST_TIMEOUT
      loop do
        response = receive(deadline)
        next unless response.as_h["type"]?.try(&.as_s?) == "response" &&
                    response.as_h["requestId"]?.try(&.as_s?) == request_id
        if response.as_h["resultType"]?.try(&.as_s?) == "error"
          reason = response.as_h["error"]?.try(&.as_s?)
          if method == "thread-follower-start-turn" &&
             reason == "App context must wait until the current turn finishes"
            raise Busy.new
          end
          failure = if reason == "no-client-found"
                      raise DeliveryUnavailable.new("no_compatible_task_owner")
                    else
                      "ipc_request_rejected"
                    end
          raise Blocked.new(failure)
        end
        unless response.as_h["resultType"]?.try(&.as_s?) == "success"
          raise Blocked.new("invalid_ipc_result")
        end
        if method != "initialize" && response.as_h["method"]?.try(&.as_s?) != method
          raise Blocked.new("ipc_response_method_mismatch")
        end
        if target && response.as_h["handledByClientId"]?.try(&.as_s?) != target
          raise Blocked.new("ipc_response_owner_mismatch")
        end
        return response
      end
    end

    def start(event : Event, instruction : String = Event::INSTRUCTION) : String
      response = rpc("thread-follower-start-turn", event.operation(@task, instruction), 2, @owner)
      turn = response.as_h["result"].as_h["result"].as_h["turn"]
      id = turn.as_h["id"].as_s
      raise Blocked.new("invalid_accepted_turn") if id.empty?
      id
    rescue TypeCastError | KeyError
      raise Blocked.new("invalid_start_response")
    end

    def wait_idle
      refreshed_unknown = false
      loop do
        @control.check
        refresh if lifecycle.revision.nil?
        case lifecycle.runtime
        when "idle" then return
        when "active"
          receive
        else
          raise Blocked.new("unknown_task_runtime") if refreshed_unknown
          refresh
          refreshed_unknown = true
        end
      end
    end

    def wait_terminal(id : String)
      refreshed_unknown = false
      loop do
        @control.check
        refresh if lifecycle.revision.nil?
        turn_state = lifecycle.turn_status(id)
        if {"completed", "failed", "interrupted"}.includes?(turn_state)
          wait_idle
          return
        elsif turn_state == "inProgress"
          receive
        else
          raise Blocked.new("accepted_turn_unresolved") if refreshed_unknown
          refresh
          refreshed_unknown = true
        end
      end
    end

    private def send_frame(value)
      @control.check
      bytes = value.to_json.to_slice
      raise Blocked.new("ipc_frame_too_large") if bytes.size > MAX_FRAME
      @socket.write_bytes(bytes.size.to_u32, IO::ByteFormat::LittleEndian)
      @socket.write(bytes)
      @socket.flush
    rescue IO::Error
      raise Disconnected.new
    end

    # Keep partial header/body bytes across read timeouts. A timeout does not
    # mean a new frame starts at the next byte.
    private def read_exact(size, deadline : Time::Instant?)
      bytes = Bytes.new(size)
      offset = 0
      while offset < size
        @control.check
        raise Deadline.new if deadline && Time.instant >= deadline
        begin
          count = @socket.read(bytes[offset..])
          raise Disconnected.new if count == 0
          offset += count
        rescue IO::TimeoutError
        rescue IO::Error
          raise Disconnected.new
        end
      end
      bytes
    end

    private def receive(deadline : Time::Instant? = nil) : JSON::Any
      header = read_exact(4, deadline)
      size = IO::ByteFormat::LittleEndian.decode(UInt32, header)
      raise Blocked.new("invalid_ipc_frame_length") unless 0 < size <= MAX_FRAME
      frame = JSON.parse(String.new(read_exact(size.to_i, deadline)))
      case frame.as_h["type"]?.try(&.as_s?)
      when "client-discovery-request"
        send_frame({
          type:      "client-discovery-response",
          requestId: frame.as_h["requestId"].as_s,
          response:  {canHandle: false},
        })
      when "broadcast"
        if frame.as_h["method"]?.try(&.as_s?) == "thread-stream-state-changed" &&
           frame.as_h["sourceClientId"]?.try(&.as_s?) == @owner
          params = frame.as_h["params"]
          if params.as_h["hostId"]?.try(&.as_s?) == "local" &&
             params.as_h["conversationId"]?.try(&.as_s?) == @task
            unless frame.as_h["version"].as_i == 11
              raise Blocked.new("unsupported_lifecycle_version")
            end
            lifecycle.update(params.as_h["change"])
          end
        elsif frame.as_h["method"]?.try(&.as_s?) == "client-status-changed"
          params = frame.as_h["params"]
          if params.as_h["clientId"]?.try(&.as_s?) == @owner &&
             params.as_h["status"]?.try(&.as_s?) == "disconnected"
            raise Disconnected.new
          end
        end
      end
      frame
    rescue JSON::ParseException | TypeCastError | KeyError
      raise Blocked.new("invalid_ipc_message")
    end
  end
end
