module TinrelayCodexBridge
  class Child
    MAX_BYTES = 64 * 1024

    def initialize(@config : Config, @control : Control)
    end

    # Pipes are owned here, so Process#wait cannot close them before the readers
    # drain. Capture is bounded and never copied into diagnostics.
    def execute(args : Array(String)) : Tuple(Process::Status, String, String)
      @control.check
      stdout_read, stdout_write = IO.pipe
      stderr_read, stderr_write = IO.pipe
      process = Process.new(
        @config.tinrelay,
        args,
        input: Process::Redirect::Close,
        output: stdout_write,
        error: stderr_write,
      )
      @control.child = process
      stdout_write.close
      stderr_write.close
      output = capture(stdout_read)
      error = capture(stderr_read)
      result = process.wait
      @control.child = nil
      @control.check
      {result, captured(output), captured(error)}
    rescue IO::Error
      raise Blocked.new("tinrelay_process_io_failure")
    ensure
      stdout_write.try(&.close)
      stderr_write.try(&.close)
      stdout_read.try(&.close)
      stderr_read.try(&.close)
    end

    private def capture(io : IO)
      channel = Channel(String | Exception).new(1)
      spawn do
        begin
          buffer = IO::Memory.new
          scratch = Bytes.new(4096)
          while (count = io.read(scratch)) > 0
            raise Blocked.new("tinrelay_output_too_large") if buffer.size + count > MAX_BYTES
            buffer.write(scratch[0, count])
          end
          channel.send(buffer.to_s)
        rescue ex
          @control.terminate_child
          channel.send(ex)
        end
      end
      channel
    end

    private def captured(channel)
      select
      when value = channel.receive
        raise Blocked.new("tinrelay_capture_failure") if value.is_a?(Exception)
        value
      when timeout(1.second)
        raise Blocked.new("tinrelay_pipe_not_closed")
      end
    end

    def version
      result, output, _ = execute(["version"])
      unless result.success? && output.starts_with?("tinrelay ")
        raise Blocked.new("tinrelay_version_failed")
      end
    end

    def wait_event
      result, output, _ = execute(["radio", "wait", "--local", "--ship", @config.ship])
      raise Blocked.new("tinrelay_local_wait_failed") unless result.success?
      raise Blocked.new("invalid_radio_output") unless output.lines.size == 1
      Event.new(output.strip)
    end

    def routed?(event : Event)
      result, output, _ = execute(["radio", "status", event.id, "--ship", @config.ship])
      raise Blocked.new("tinrelay_status_failed") unless result.success?
      value = JSON.parse(output)
      raise Blocked.new("status_id_mismatch") unless value.as_h["local_id"].as_s == event.id
      raise Blocked.new("status_kind_mismatch") unless value.as_h["kind"].as_s == event.kind
      case value.as_h["state"].as_s
      when "routed"
        value.as_h["routed_at"].as_i64
        true
      when "pending"
        raise Blocked.new("invalid_pending_status") unless value.as_h["routed_at"].raw.nil?
        false
      else
        raise Blocked.new("invalid_radio_status")
      end
    rescue JSON::ParseException | TypeCastError | KeyError
      raise Blocked.new("invalid_radio_status")
    end
  end
end
