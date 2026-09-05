module TinrelayCodexBridge
  class Runner
    IMMEDIATE_RETRY_SECONDS  = 2
    IMMEDIATE_RETRY_WINDOW   = 5 * 60
    RESPONSIVE_RETRY_SECONDS = 5
    RESPONSIVE_RETRY_WINDOW  = 10 * 60
    BACKGROUND_RETRY_SECONDS = 15
    BACKGROUND_RETRY_WINDOW  = 60 * 60
    IDLE_RETRY_SECONDS       = 60
    OPEN_IT_COOLDOWN_SECONDS = 5 * 60
    NOT_TODAY_SECONDS        = 24 * 60 * 60

    @ipc : IPC? = nil

    def initialize(@config : Config, @control = Control.new, @reporter = Reporter.new)
      @child = Child.new(@config, @control)
      @notifier = Notifier.new(@config, @control)
    end

    def check
      @child.version
      connection = connect
      connection.wait_idle if connection.lifecycle.runtime != "active"
      @reporter.emit("ready", "desktop_delivery_available")
    ensure
      @ipc.try(&.close)
    end

    def run
      path = @config.lock_path
      Dir.mkdir_p(File.dirname(path), mode: 0o700)
      File.open(path, "a", perm: 0o600) do |lock|
        lock.close_on_exec = true
        begin
          lock.flock_exclusive(false)
        rescue IO::Error
          raise Blocked.new("bridge_already_running")
        end
        @child.version
        loop do
          @control.check
          @reporter.emit("listening")
          deliver(@child.wait_event)
        end
      end
    ensure
      @ipc.try(&.close)
    end

    private def connect : IPC
      @ipc.try(&.close)
      @ipc = nil
      @control.check
      begin
        socket = open_socket
      rescue IO::Error
        raise DeliveryUnavailable.new("codex_socket_unavailable")
      end
      begin
        connection = IPC.new(socket, @config.task, @control)
        @ipc = connection
        connection.subscribe
        connection
      rescue Disconnected
        socket.close
        raise DeliveryUnavailable.new("codex_handshake_unavailable")
      rescue ex
        socket.close
        raise ex
      end
    end

    private def open_socket : CodexTransport
      {% if flag?(:win32) %}
        File.open(@config.socket_path, "r+", blocking: false)
      {% else %}
        UNIXSocket.new(@config.socket_path)
      {% end %}
    end

    private def connection
      @ipc || connect
    end

    private def idle_connection
      loop do
        begin
          ipc = connection
          ipc.wait_idle
          return ipc
        rescue Disconnected
          @ipc = nil
        end
      end
    end

    private def observe(id)
      loop do
        begin
          connection.wait_terminal(id)
          return
        rescue Disconnected
          @ipc = nil
        end
      end
    end

    private def deliver(event)
      return if @child.routed?(event)
      loop do
        begin
          deliver_through_desktop(event)
          return
        rescue ex : DeliveryUnavailable
          @reporter.emit("waiting_for_radio_room", ex.message, local_id: event.id)
          unless @notifier.configured?
            return if wait_for_radio_room(event)
            next
          end
          cooldown = @notifier.wait
          seconds, reason = reminder_cooldown(cooldown)
          @reporter.emit("radio_room_reminder_deferred", reason, local_id: event.id)
          return if wait_for_radio_room(event, seconds)
        end
      end
    end

    private def reminder_cooldown(cooldown)
      case cooldown
      when Notifier::Cooldown::OpenIt
        {OPEN_IT_COOLDOWN_SECONDS, "five_minutes"}
      when Notifier::Cooldown::NotToday
        {NOT_TODAY_SECONDS, "twenty_four_hours"}
      else
        raise Blocked.new("unknown_notifier_cooldown")
      end
    end

    private def wait_for_radio_room(event, cooldown_seconds : Int32? = nil)
      started = Time.instant
      deadline = cooldown_seconds.try { |seconds| Time.instant + seconds.seconds }
      loop do
        begin
          deliver_through_desktop(event)
          return true
        rescue DeliveryUnavailable
          disconnect
          return false if deadline.try { |value| Time.instant >= value }
          @control.pause(retry_seconds(Time.instant - started))
        end
      end
    end

    private def retry_seconds(elapsed)
      seconds = elapsed.total_seconds
      return IMMEDIATE_RETRY_SECONDS if seconds < IMMEDIATE_RETRY_WINDOW
      return RESPONSIVE_RETRY_SECONDS if seconds < RESPONSIVE_RETRY_WINDOW
      return BACKGROUND_RETRY_SECONDS if seconds < BACKGROUND_RETRY_WINDOW
      IDLE_RETRY_SECONDS
    end

    private def disconnect
      @ipc.try(&.close)
      @ipc = nil
    end

    private def deliver_through_desktop(event)
      attempts = 0
      loop do
        ipc = idle_connection
        return if @child.routed?(event)
        raise Blocked.new("recovery_exhausted") if attempts == 2
        begin
          id = ipc.start(event)
        rescue Busy
          # Refresh through idle_connection so a disconnect immediately after
          # the busy rejection follows the ordinary reconnect path.
          ipc.lifecycle.invalidate
          next
        rescue Disconnected
          # No accepted turn ID: reacquire state and reconcile, but never guess
          # which turn consumed the event or automatically submit it again.
          @ipc = nil
          idle_connection
          return if @child.routed?(event)
          raise Blocked.new("submission_outcome_unknown")
        end
        attempts += 1
        @reporter.emit("accepted", local_id: event.id, turn_id: id)
        @reporter.emit("waiting_for_routing", local_id: event.id, turn_id: id)
        observe(id)
      end
    end
  end
end
