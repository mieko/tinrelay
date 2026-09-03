module Tinrelay
  class Outbox
    UUID = /\A[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/

    getter directory : String

    def initialize(@directory)
      ensure_directory
    end

    def store(envelope : SignedRelayEnvelope) : String
      encoded = envelope.to_json
      target = path(envelope.transmission_id)
      temporary = "#{target}.tmp.#{Process.pid}"
      begin
        File.open(temporary, "w", perm: 0o600) do |file|
          file << encoded << '\n'
          file.flush
          file.fsync
        end
        File.chmod(temporary, 0o600)
        File.rename(temporary, target)
        File.open(directory, "r", &.fsync)
      ensure
        File.delete(temporary) if File.exists?(temporary)
      end
      encoded
    end

    def read(id : String) : Tuple(SignedRelayEnvelope, String)
      target = path(id)
      encoded = File.read(target).strip
      envelope = SignedRelayEnvelope.from_json(encoded)
      raise Invalid.new("outbox transmission id does not match its file") unless envelope.transmission_id == id
      {envelope, encoded}
    rescue ex : File::NotFoundError
      raise NotFound.new("outbox transmission not found")
    rescue ex : JSON::ParseException
      raise Invalid.new("outbox transmission is invalid")
    end

    def list(now : Int64 = Time.utc.to_unix) : Array(SignedRelayEnvelope)
      cleanup(now)
      Dir.glob(File.join(directory, "*.json")).sort.compact_map do |file|
        id = File.basename(file, ".json")
        next unless UUID.matches?(id)
        read(id)[0]
      end
    end

    def delete(id : String) : Nil
      target = path(id)
      return unless File.exists?(target)
      File.delete(target)
      File.open(directory, "r", &.fsync)
    end

    def cleanup(now : Int64 = Time.utc.to_unix) : Int32
      removed = 0
      Dir.glob(File.join(directory, "*.json")).each do |file|
        next unless UUID.matches?(File.basename(file, ".json"))
        begin
          envelope = SignedRelayEnvelope.from_json(File.read(file))
          next if envelope.expires_at > now
          File.delete(file)
          removed += 1
        rescue JSON::ParseException
          # Preserve malformed evidence for deliberate inspection.
        end
      end
      File.open(directory, "r", &.fsync) if removed > 0
      removed
    end

    private def path(id : String) : String
      raise Invalid.new("invalid transmission id") unless UUID.matches?(id)
      File.join(directory, "#{id}.json")
    end

    private def ensure_directory : Nil
      unless Dir.exists?(directory)
        Dir.mkdir_p(directory, mode: 0o700)
      end
      File.chmod(directory, 0o700)
    end
  end

end
