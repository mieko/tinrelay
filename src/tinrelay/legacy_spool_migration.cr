module Tinrelay
  # Temporary, removable bridge from the first live spool layout. Ordinary
  # spool operations know only pending/*.json and routed/*.json.
  class LegacySpoolMigration
    LOCAL_ID = /\Atr_[0-9a-f]{32}\z/
    COMMAND  = "tinrelay inbox migrate --ship \"$SHIP\""

    def self.run(root : String) : Bool
      new(root).run
    end

    def self.reject_if_present!(root : String) : Nil
      return unless new(root).legacy_layout?
      raise Error.new("legacy inbox layout requires: #{COMMAND}")
    end

    private def initialize(@root : String)
      @pending = File.join(root, "pending")
      @history = File.join(root, "history")
      @routed = File.join(root, "routed")
    end

    def run : Bool
      return false unless Dir.exists?(@root)
      return false unless legacy_layout?
      migrate_history
      migrate_marked_pending
      remove_empty_history
      true
    end

    private def migrate_history : Nil
      return unless Dir.exists?(@history)
      Dir.children(@history).sort.each do |entry|
        entry.match(/\A(tr_[0-9a-f]{32})\.json\z/) ||
          raise Error.new("legacy inbox history contains an unexpected entry")
        id = entry.rchop(".json")
        marker = File.join(@routed, id)
        validate_marker!(marker, id) if File.file?(marker)
        move_record(
          File.join(@history, entry), File.join(@routed, entry),
          "legacy routed destination conflicts"
        )
        delete_if_present(marker, @routed)
      end
    end

    private def migrate_marked_pending : Nil
      legacy_markers.each do |marker|
        id = File.basename(marker)
        validate_marker!(marker, id)
        source = File.join(@pending, "#{id}.json")
        destination = File.join(@routed, "#{id}.json")
        if File.file?(source)
          move_record(
            source, destination,
            "legacy routed destination conflicts"
          )
        elsif !valid_routed_record?(destination, id)
          raise Error.new("legacy inbox marker has no matching record: #{id}")
        end
        delete_if_present(marker, @routed)
      end
    end

    private def remove_empty_history : Nil
      return unless Dir.exists?(@history)
      unless Dir.children(@history).empty?
        raise Error.new("legacy inbox history migration is incomplete")
      end
      Dir.delete(@history)
      File.open(@root, "r", &.fsync)
    end

    def legacy_layout? : Bool
      Dir.exists?(@history) || !legacy_markers.empty?
    end

    private def legacy_markers : Array(String)
      return [] of String unless Dir.exists?(@routed)
      Dir.glob(File.join(@routed, "tr_[0-9a-f]*")).select do |path|
        File.file?(path) && File.basename(path).matches?(LOCAL_ID)
      end
    end

    private def validate_marker!(path : String, id : String) : Nil
      unless File.read(path).strip.to_i64?
        raise Error.new("legacy inbox marker is corrupt: #{id}")
      end
    end

    private def valid_routed_record?(path : String, id : String) : Bool
      return false unless File.file?(path)
      SpoolRecord.from_json(File.read(path)).local_id == id
    rescue JSON::ParseException
      false
    end

    private def move_record(source : String, destination : String,
                            conflict : String) : Nil
      source_bytes = File.read(source)
      if File.exists?(destination)
        unless File.file?(destination) && File.read(destination) == source_bytes
          raise Conflict.new(conflict)
        end
        delete_if_present(source, File.dirname(source))
        return
      end

      File.rename(source, destination)
      File.open(File.dirname(source), "r", &.fsync)
      File.open(File.dirname(destination), "r", &.fsync)
    end

    private def delete_if_present(path : String, directory : String) : Nil
      File.delete(path)
      File.open(directory, "r", &.fsync)
    rescue File::NotFoundError
    end
  end
end
