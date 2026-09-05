require "./tinrelay_codex_bridge/bridge"

module TinrelayCodexBridge
  HELP = <<-TEXT
    tinrelay-codex-bridge run --ship SHIP --radio-room-task UUID
    tinrelay-codex-bridge check --ship SHIP --radio-room-task UUID
    tinrelay-codex-bridge help
    tinrelay-codex-bridge version

    Optional: --tinrelay PATH, --codex-home PATH
              --notify-command PATH --radio-room-name NAME
    run stays in the foreground. check never submits a model turn.
    Desktop must have a compatible live owner for the configured task.
    A blocked run prints a structured reason and exits 0; check failures exit 2.
    Unexpected failures exit 1. Quiet listening spends no model turns.
    TEXT

  def self.main(argv : Array(String)) : Int32
    command = argv.shift? || "help"
    case command
    when "help", "--help", "-h"
      puts HELP
      return 0
    when "version", "--version"
      puts "tinrelay-codex-bridge #{VERSION}"
      return 0
    end
    raise Blocked.new("unknown_command") unless {"run", "check"}.includes?(command)
    ship = task = ""
    executable = "tinrelay"
    notify_command = nil.as(String?)
    radio_room_name = nil.as(String?)
    codex_home = ENV["CODEX_HOME"]? || File.join(ENV["HOME"], ".codex")
    parser = OptionParser.new do |p|
      p.on("--ship SHIP", "Local ship") { |v| ship = v }
      p.on("--radio-room-task UUID", "Existing local task") { |v| task = v }
      p.on("--tinrelay PATH", "TinRelay executable") { |v| executable = v }
      p.on("--codex-home PATH", "Codex home") { |v| codex_home = v }
      p.on("--notify-command PATH", "Blocking unavailable-room notifier") do |v|
        notify_command = v
      end
      p.on("--radio-room-name NAME", "Radio-room display name") { |v| radio_room_name = v }
      p.invalid_option { raise Blocked.new("invalid_option") }
      p.missing_option { raise Blocked.new("missing_option_value") }
    end
    parser.parse(argv)
    raise Blocked.new("unexpected_arguments") unless argv.empty?
    config = Config.new(
      ship,
      task,
      executable,
      codex_home,
      radio_room_name: radio_room_name,
      notify_command: notify_command,
    )
    control = Control.new
    Signal::INT.trap { control.stop }
    Signal::TERM.trap { control.stop }
    runner = Runner.new(config, control)
    command == "run" ? runner.run : runner.check
    0
  rescue Stopped
    Reporter.new.emit("stopped", "signal")
    0
  rescue ex : Blocked
    Reporter.new.emit("blocked", ex.message)
    command == "run" ? 0 : 2
  rescue Exception
    Reporter.new(STDERR).emit("failed", "unexpected_bridge_failure")
    1
  end
end

exit TinrelayCodexBridge.main(ARGV.dup)
