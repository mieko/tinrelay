module TinrelayCodexBridge
  class Notifier
    enum Cooldown
      OpenIt
      NotToday
    end

    def initialize(@config : Config, @control : Control)
    end

    def configured?
      !@config.notify_command.nil?
    end

    def wait : Cooldown
      result = invoke([@config.radio_room_name.not_nil!])
      case result.exit_code
      when  0 then Cooldown::OpenIt
      when 75 then Cooldown::NotToday
      else         raise Blocked.new("notifier_failed")
      end
    rescue IO::Error
      raise Blocked.new("notifier_failed")
    end

    def fault(classification : String)
      return unless @config.notify_command
      safe = if /\A[a-z0-9_:-]{1,160}\z/.matches?(classification)
               classification
             else
               "bridge_blocked"
             end
      invoke(["--fault", safe])
    rescue IO::Error
      # The original terminal classification remains authoritative if its
      # best-effort local notification cannot be displayed.
    end

    private def invoke(args : Array(String))
      command = @config.notify_command || raise Blocked.new("notify_command_unavailable")
      @control.check
      process = Process.new(
        command,
        args,
        input: Process::Redirect::Close,
        output: Process::Redirect::Close,
        error: Process::Redirect::Close,
      )
      @control.child = process
      result = process.wait
      @control.check
      result
    ensure
      @control.child = nil if process
    end
  end
end
