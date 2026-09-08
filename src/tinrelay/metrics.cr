module Tinrelay
  class Metrics
    REGISTRATION_OUTCOMES = %w[accepted rate_limited cidr_denied closed capacity invalid conflict]
    TRANSMISSION_OUTCOMES = %w[direct queued acknowledged expired rejected]
    HAIL_OUTCOMES         = %w[accepted collected allowed expired rejected]
    RADIO_WAIT_OUTCOMES   = %w[transmission hail contact_update timeout disconnect error]
    RELOAD_OUTCOMES       = %w[accepted rejected]
    CLEANUP_KINDS         = %w[
      transmissions_expired transmissions_deleted hails_expired
      relationships_deleted transitions_deleted errors
    ]

    getter process_started_at : Int64

    def initialize(@process_started_at = Time.utc.to_unix)
      @mutex = Mutex.new
      @counters = Hash(Tuple(Symbol, String), Int64).new(0_i64)
    end

    def registration(outcome : String, count = 1_i64) : Nil
      increment(:registration, outcome, REGISTRATION_OUTCOMES, count)
    end

    def transmission(outcome : String, count = 1_i64) : Nil
      increment(:transmission, outcome, TRANSMISSION_OUTCOMES, count)
    end

    def hail(outcome : String, count = 1_i64) : Nil
      increment(:hail, outcome, HAIL_OUTCOMES, count)
    end

    def radio_wait(outcome : String, count = 1_i64) : Nil
      increment(:radio_wait, outcome, RADIO_WAIT_OUTCOMES, count)
    end

    def configuration_reload(outcome : String) : Nil
      increment(:configuration_reload, outcome, RELOAD_OUTCOMES, 1_i64)
    end

    def cleanup(result) : Nil
      increment(:cleanup, "transmissions_expired", CLEANUP_KINDS, result[:expired].to_i64)
      increment(:cleanup, "transmissions_deleted", CLEANUP_KINDS, result[:deleted].to_i64)
      increment(:cleanup, "hails_expired", CLEANUP_KINDS, result[:hails_deleted].to_i64)
      increment(
        :cleanup, "relationships_deleted", CLEANUP_KINDS,
        result[:relationships_deleted].to_i64
      )
      increment(
        :cleanup, "transitions_deleted", CLEANUP_KINDS,
        result[:transitions_deleted].to_i64
      )
    end

    def cleanup_error : Nil
      increment(:cleanup, "errors", CLEANUP_KINDS, 1_i64)
    end

    def render(store : Store, handoffs : DirectHandoff,
               now = Time.utc.to_unix) : String
      database = store.metrics_snapshot(now)
      counters = @mutex.synchronize { @counters.dup }
      String.build do |io|
        gauge(io, "tinrelay_process_start_time_seconds", process_started_at)
        io << "# TYPE tinrelay_registered_ships gauge\n"
        database[:ships].each do |state, count|
          sample(io, "tinrelay_registered_ships", count, "state", state)
        end
        gauge(io, "tinrelay_radio_waits_active", handoffs.waiting_count)
        gauge(io, "tinrelay_queued_transmissions", database[:queued_transmissions])
        gauge(io, "tinrelay_queued_hails", database[:queued_hails])
        gauge(
          io, "tinrelay_oldest_queued_transmission_age_seconds",
          database[:oldest_transmission_age]
        )
        gauge(io, "tinrelay_oldest_queued_hail_age_seconds", database[:oldest_hail_age])
        gauge(io, "tinrelay_retained_ciphertext_bytes", database[:ciphertext_bytes])
        counter_family(
          io, counters, :registration, "tinrelay_registrations_total",
          REGISTRATION_OUTCOMES
        )
        counter_family(
          io, counters, :transmission, "tinrelay_transmissions_total",
          TRANSMISSION_OUTCOMES
        )
        counter_family(io, counters, :hail, "tinrelay_hails_total", HAIL_OUTCOMES)
        counter_family(
          io, counters, :radio_wait, "tinrelay_radio_waits_total", RADIO_WAIT_OUTCOMES
        )
        counter_family(
          io, counters, :configuration_reload,
          "tinrelay_configuration_reloads_total", RELOAD_OUTCOMES
        )
        counter_family(io, counters, :cleanup, "tinrelay_cleanup_items_total", CLEANUP_KINDS)
      end
    end

    private def increment(family : Symbol, outcome : String,
                          allowed : Array(String), count : Int64) : Nil
      raise ArgumentError.new("unknown metrics outcome") unless allowed.includes?(outcome)
      return if count == 0
      @mutex.synchronize { @counters[{family, outcome}] += count }
    end

    private def gauge(io : IO, name : String, value) : Nil
      io << "# TYPE " << name << " gauge\n"
      io << name << ' ' << value << '\n'
    end

    private def sample(io : IO, name : String, value,
                       label : String, label_value : String) : Nil
      io << name << '{' << label << "=\"" << label_value << "\"} " << value << '\n'
    end

    private def counter_family(io : IO,
                               counters : Hash(Tuple(Symbol, String), Int64),
                               family : Symbol, name : String,
                               outcomes : Array(String)) : Nil
      io << "# TYPE " << name << " counter\n"
      outcomes.each do |outcome|
        sample(io, name, counters[{family, outcome}], "outcome", outcome)
      end
    end
  end
end
