module Tinrelay
  class SubmissionWindow
    @mutex = Mutex.new
    @attempts = {} of String => Array(Int64)

    def initialize(@limit : Int32 = Store::MAX_TRANSMISSIONS_PER_HOUR,
                   @period_seconds : Int64 = 3600)
    end

    def allow?(ship : String, now : Int64 = Time.utc.to_unix) : Bool
      @mutex.synchronize do
        cutoff = now - @period_seconds
        timestamps = @attempts[ship]?
        if timestamps
          timestamps.reject! { |timestamp| timestamp < cutoff }
          @attempts.delete(ship) if timestamps.empty?
        end
        timestamps = @attempts[ship] ||= [] of Int64
        return false if timestamps.size >= @limit
        timestamps << now
        true
      end
    end
  end

  # One-process rendezvous between a parked radio wait and a sender request.
  # It never owns durable state: a handoff either reaches the destination spool
  # acknowledgement or the caller persists the prepared envelope in SQLite.
  class DirectHandoff
    class Waiter
      getter envelope = Channel(SignedRelayEnvelope).new(1)
    end

    class Attempt
      getter prepared : PreparedRelayEnvelope
      getter completed = Channel(Nil).new(1)

      def initialize(@prepared)
      end
    end

    @mutex = Mutex.new
    @waiters = {} of String => Waiter
    @attempts = {} of String => Attempt

    def wait(ship : String, duration : Time::Span) : SignedRelayEnvelope?
      waiter = Waiter.new
      @mutex.synchronize do
        if @waiters.has_key?(ship)
          raise Conflict.new("a radio wait is already parked for this ship")
        end
        @waiters[ship] = waiter
      end
      select
      when envelope = waiter.envelope.receive
        envelope
      when timeout(duration)
        nil
      end
    ensure
      @mutex.synchronize do
        @waiters.delete(ship) if @waiters[ship]? == waiter
      end
    end

    def waiting?(ship : String) : Bool
      @mutex.synchronize { @waiters.has_key?(ship) }
    end

    def waiting_count : Int32
      @mutex.synchronize { @waiters.size }
    end

    def deliver(prepared : PreparedRelayEnvelope, duration : Time::Span) : Bool
      owned_attempt = nil.as(Attempt?)
      existing_attempt = nil.as(Attempt?)
      waiter = @mutex.synchronize do
        if current = @attempts[prepared.envelope.transmission_id]?
          unless Crypto.constant_time_equal?(current.prepared.digest, prepared.digest)
            raise Conflict.new("transmission id was reused with different contents")
          end
          existing_attempt = current
          next nil
        end
        found = @waiters.delete(prepared.envelope.recipient_ship)
        if found
          owned_attempt = Attempt.new(prepared)
          @attempts[prepared.envelope.transmission_id] = owned_attempt.not_nil!
        end
        found
      end
      if current = existing_attempt
        deadline = Time.instant + duration
        loop do
          active = @mutex.synchronize do
            @attempts[prepared.envelope.transmission_id]? == current
          end
          return false unless active
          return false if Time.instant >= deadline
          sleep 10.milliseconds
        end
      end
      return false unless waiter
      waiter.envelope.send(prepared.envelope)
      attempt = owned_attempt.not_nil!
      select
      when attempt.completed.receive
        true
      when timeout(duration)
        false
      end
    ensure
      if attempt = owned_attempt
        @mutex.synchronize do
          transmission_id = prepared.envelope.transmission_id
          @attempts.delete(transmission_id) if @attempts[transmission_id]? == attempt
        end
      end
    end

    def prepared_for_ack(transmission_id : String, ship : String) : PreparedRelayEnvelope?
      @mutex.synchronize do
        attempt = @attempts[transmission_id]?
        next nil unless attempt
        next nil unless attempt.prepared.envelope.recipient_ship == ship
        attempt.prepared
      end
    end

    def complete(transmission_id : String) : Nil
      attempt = @mutex.synchronize { @attempts.delete(transmission_id) }
      attempt.try(&.completed.send(nil))
    end
  end
end
