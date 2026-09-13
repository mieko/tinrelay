require "../tinrelay/atomic_private_file"

module TinrelayCodexBridge
  record PendingTargetBinding, local_id : String, task_id : String

  class PendingTarget
    MAX_BYTES = 1024

    def initialize(@path : String)
    end

    def load : PendingTargetBinding?
      return unless File.exists?(@path)
      bytes = File.open(@path) do |file|
        buffer = IO::Memory.new
        count = IO.copy(file, buffer, MAX_BYTES + 1)
        raise Blocked.new("pending_target_too_large") if count > MAX_BYTES
        buffer.to_s
      end
      value = JSON.parse(bytes).as_h
      unless value.keys.sort == ["local_id", "task_id"]
        raise Blocked.new("invalid_pending_target")
      end
      local_id = value["local_id"].as_s
      task_id = value["task_id"].as_s
      raise Blocked.new("invalid_pending_target") unless valid_local_id?(local_id)
      raise Blocked.new("invalid_pending_target") unless valid_task_id?(task_id)
      PendingTargetBinding.new(local_id, task_id)
    rescue ex : File::Error
      raise Blocked.new("pending_target_unreadable")
    rescue JSON::ParseException | TypeCastError | KeyError
      raise Blocked.new("invalid_pending_target")
    end

    def bind(local_id : String, task_id : String) : PendingTargetBinding
      if current = load
        unless current.local_id == local_id
          raise Blocked.new("pending_target_conflict")
        end
        return current
      end
      binding = PendingTargetBinding.new(local_id, task_id)
      Tinrelay::AtomicPrivateFile.write(
        @path,
        {local_id: binding.local_id, task_id: binding.task_id}.to_json + '\n'
      )
      binding
    end

    def clear(local_id : String)
      current = load || return
      unless current.local_id == local_id
        raise Blocked.new("pending_target_conflict")
      end
      File.delete(@path)
      File.open(File.dirname(@path), "r", &.fsync)
    rescue ex : File::Error
      raise Blocked.new("pending_target_unwritable")
    end

    private def valid_local_id?(value)
      /\Atr_[0-9a-f]{32}\z/.matches?(value)
    end

    private def valid_task_id?(value)
      /\A[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}\z/.matches?(value)
    end
  end
end
