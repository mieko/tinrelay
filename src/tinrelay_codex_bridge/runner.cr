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

    def initialize(@config : Config, @control = Control.new, @reporter = Reporter.new)
      @child = Child.new(@config, @control)
      @notifier = Notifier.new(@config, @control)
      @pending_target = PendingTarget.new(@config.pending_target_path)
      @desktop_control = CodexBridge::Control.new
      @control.desktop = @desktop_control
      @desktop = CodexBridge::Client.new(@config.codex_home, @desktop_control)
    end

    def check
      @child.version
      case result = @desktop.check(@config.task)
      when CodexBridge::Ready
        @reporter.emit("ready", "desktop_delivery_available")
      when CodexBridge::Retryable
        raise DeliveryUnavailable.new(product_reason(result.reason))
      when CodexBridge::Incompatible
        raise Blocked.new(product_reason(result.reason))
      end
    end

    def run
      path = @config.lock_path
      Dir.mkdir_p(File.dirname(path), mode: 0o700)
      File.open(path, "a", perm: 0o600) do |lock|
        lock.close_on_exec = true
        begin
          lock.flock_exclusive(false)
        rescue IO::Error
          raise AlreadyRunning.new("bridge_already_running")
        end
        delivery_path = @config.local_delivery_lock_path
        Dir.mkdir_p(File.dirname(delivery_path), mode: 0o700)
        File.open(delivery_path, "a", perm: 0o600) do |delivery_lock|
          delivery_lock.close_on_exec = true
          File.chmod(delivery_path, 0o600)
          begin
            delivery_lock.flock_exclusive(false)
          rescue IO::Error
            raise Blocked.new("local_delivery_already_owned")
          end
          @child.version
          loop do
            @control.check
            pending_target = @pending_target.load
            if pending_target && @child.routed?(pending_target.local_id)
              @pending_target.clear(pending_target.local_id)
              next
            end
            @reporter.emit("listening")
            deliver(@child.wait_event, pending_target)
          end
        end
      end
    rescue ex : AlreadyRunning
      raise ex
    rescue ex : Blocked
      @notifier.fault(ex.message || "bridge_blocked") if @notifier.configured?
      raise ex
    end

    private def deliver(event, pending_target : PendingTargetBinding?)
      if pending_target && pending_target.local_id != event.id
        unless @child.routed?(pending_target.local_id)
          raise Blocked.new("pending_target_conflict")
        end
        @pending_target.clear(pending_target.local_id)
        pending_target = nil
      end
      if @child.routed?(event)
        @pending_target.clear(event.id) if pending_target
        return
      end
      target = pending_target || @pending_target.bind(event.id, @config.task)
      loop do
        begin
          deliver_through_desktop(event, target.task_id)
          break
        rescue ex : DeliveryUnavailable
          @reporter.emit("waiting_for_radio_room", ex.message, local_id: event.id)
          unless @notifier.configured?
            break if wait_for_radio_room(event, target.task_id)
            next
          end
          seconds = unavailable_cooldown(event)
          break if wait_for_radio_room(event, target.task_id, seconds)
        end
      end
      @pending_target.clear(event.id)
    end

    private def unavailable_cooldown(event) : Int32
      case @notifier.wait
      when Notifier::Cooldown::OpenIt
        @reporter.emit(
          "radio_room_reminder_deferred",
          "five_minutes",
          local_id: event.id
        )
        OPEN_IT_COOLDOWN_SECONDS
      when Notifier::Cooldown::NotToday
        @reporter.emit(
          "radio_room_reminder_deferred",
          "twenty_four_hours",
          local_id: event.id
        )
        NOT_TODAY_SECONDS
      when Notifier::Cooldown::Failed
        @reporter.emit("waiting_for_radio_room", "notifier_failed", local_id: event.id)
        OPEN_IT_COOLDOWN_SECONDS
      else
        raise Blocked.new("unknown_notifier_cooldown")
      end
    end

    private def wait_for_radio_room(event, target_task_id,
                                    cooldown_seconds : Int32? = nil)
      started = Time.instant
      deadline = cooldown_seconds.try { |seconds| Time.instant + seconds.seconds }
      loop do
        begin
          deliver_through_desktop(event, target_task_id)
          return true
        rescue DeliveryUnavailable
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

    private def logical_message_id(event, ordinal)
      "tinrelay-turn:#{event.id}:#{ordinal}"
    end

    private def delivery(event, target_task_id, ordinal)
      CodexBridge::Delivery.new(
        task_id: target_task_id,
        instruction: Event::INSTRUCTION,
        attachments: [event.attachment],
        logical_message_id: logical_message_id(event, ordinal),
        mode: CodexBridge::DeliveryMode::Queue
      )
    end

    private def reconcile(event, target_task_id, ordinal)
      id = logical_message_id(event, ordinal)
      started = Time.instant
      loop do
        case result = @desktop.reconcile(target_task_id, id)
        when CodexBridge::LogicalMessageObserved, CodexBridge::LogicalMessageNotObserved
          return result
        when CodexBridge::LogicalMessageProvisional
          @reporter.emit(
            "waiting_for_submission_resolution",
            "submission_provisional",
            local_id: event.id
          )
          @control.pause(retry_seconds(Time.instant - started))
        when CodexBridge::Retryable
          reason = product_reason(result.reason)
          @reporter.emit("waiting_for_radio_room", reason, local_id: event.id)
          raise DeliveryUnavailable.new(reason)
        when CodexBridge::Incompatible
          raise Blocked.new(product_reason(result.reason))
        end
      end
    end

    private def submit(event, target_task_id, ordinal) : String?
      uncertain = false
      started = Time.instant
      loop do
        case result = @desktop.deliver(delivery(event, target_task_id, ordinal))
        when CodexBridge::Accepted
          @reporter.emit(
            "accepted",
            uncertain ? "accepted_after_reconnect" : nil,
            local_id: event.id,
            turn_id: result.turn_id
          )
          return result.turn_id
        when CodexBridge::Ambiguous
          uncertain = true
          report_ambiguous(event, result.reason)
          return if @child.routed?(event)
          if {"submission_not_observed", "submission_provisional"}.includes?(result.reason)
            @control.pause(retry_seconds(Time.instant - started))
            if result.reason == "submission_provisional"
              case recovered = reconcile(event, target_task_id, ordinal)
              when CodexBridge::LogicalMessageObserved
                @reporter.emit(
                  "accepted",
                  "accepted_after_reconnect",
                  local_id: event.id,
                  turn_id: recovered.turn_id
                )
                return recovered.turn_id
              when CodexBridge::LogicalMessageNotObserved
                @reporter.emit("submission_not_observed", local_id: event.id)
              end
            end
          else
            raise DeliveryUnavailable.new(product_reason(result.reason))
          end
        when CodexBridge::Retryable
          raise DeliveryUnavailable.new(product_reason(result.reason))
        when CodexBridge::Incompatible
          raise Blocked.new(product_reason(result.reason))
        end
      end
    end

    private def report_ambiguous(event, reason)
      @reporter.emit(
        "waiting_for_submission_resolution",
        reason == "submission_not_observed" ? "submission_outcome_unknown" : reason,
        local_id: event.id
      )
      if reason == "submission_not_observed"
        @reporter.emit("submission_not_observed", local_id: event.id)
      end
    end

    private def observe(event, target_task_id, turn_id)
      @reporter.emit("waiting_for_routing", local_id: event.id, turn_id: turn_id)
      case result = @desktop.observe_until_terminal(target_task_id, turn_id)
      when CodexBridge::Terminal
        result
      when CodexBridge::Retryable
        raise DeliveryUnavailable.new(product_reason(result.reason))
      when CodexBridge::Incompatible
        raise Blocked.new(product_reason(result.reason))
      end
    end

    private def observe_recovered(event, target_task_id, observed)
      @reporter.emit(
        "accepted",
        "accepted_after_reconnect",
        local_id: event.id,
        turn_id: observed.turn_id
      )
      observe(event, target_task_id, observed.turn_id)
    end

    private def deliver_through_desktop(event, target_task_id)
      return if @child.routed?(event)

      second = reconcile(event, target_task_id, 2)
      if second.is_a?(CodexBridge::LogicalMessageObserved)
        observe_recovered(event, target_task_id, second)
        return if @child.routed?(event)
        raise Blocked.new("recovery_exhausted")
      end

      first = reconcile(event, target_task_id, 1)
      if first.is_a?(CodexBridge::LogicalMessageObserved)
        observe_recovered(event, target_task_id, first)
      else
        turn_id = submit(event, target_task_id, 1) || return
        observe(event, target_task_id, turn_id)
      end
      return if @child.routed?(event)

      second_turn_id = submit(event, target_task_id, 2) || return
      observe(event, target_task_id, second_turn_id)
      return if @child.routed?(event)
      raise Blocked.new("recovery_exhausted")
    end

    private def product_reason(reason)
      case reason
      when "codex_transport_unavailable"
        "codex_socket_unavailable"
      when "duplicate_logical_message_id"
        "duplicate_client_message_id"
      when /^history_(.+)$/
        "ipc_retryable_rejection:thread-follower-load-complete-history:#{$1}"
      else
        reason
      end
    end
  end
end
