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
      command = @config.notify_command || raise Blocked.new("notify_command_unavailable")
      @control.check
      process = Process.new(
        command,
        [@config.radio_room_name.not_nil!],
        input: Process::Redirect::Close,
        output: Process::Redirect::Close,
        error: Process::Redirect::Close,
      )
      @control.child = process
      result = process.wait
      @control.child = nil
      @control.check
      case result.exit_code
      when  0 then Cooldown::OpenIt
      when 75 then Cooldown::NotToday
      else         raise Blocked.new("notifier_failed")
      end
    rescue IO::Error
      raise Blocked.new("notifier_failed")
    ensure
      @control.child = nil if process
    end
  end
end
