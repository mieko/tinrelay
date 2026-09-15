module TinrelayCodexBridge
  class AddressBook
    MAX_BYTES = 64 * 1024

    def initialize(@path : String)
    end

    def check
      addresses = read
      raise Blocked.new("empty_address_book") if addresses.empty?
      addresses.each_value { |value| task_id(value) }
    end

    def resolve(event : Event) : String
      addresses = read
      key = if event.kind == "transmission" && addresses.has_key?(event.name.not_nil!)
              event.name.not_nil!
            else
              "*"
            end
      value = addresses[key]? || raise Blocked.new("address_not_found")
      task_id(value)
    end

    private def read
      bytes = File.open(@path) do |file|
        buffer = IO::Memory.new
        count = IO.copy(file, buffer, MAX_BYTES + 1)
        raise Blocked.new("address_book_too_large") if count > MAX_BYTES
        buffer.to_s
      end
      JSON.parse(bytes).as_h
    rescue File::Error
      raise Blocked.new("address_book_unreadable")
    rescue JSON::ParseException | TypeCastError
      raise Blocked.new("invalid_address_book")
    end

    private def task_id(value)
      address = value.as_h
      unless address.keys.sort == ["hostId", "threadId"] &&
             address["hostId"]?.try(&.as_s?) == "local"
        raise Blocked.new("invalid_address")
      end
      id = address["threadId"]?.try(&.as_s?) || raise Blocked.new("invalid_address")
      unless /\A[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}\z/.matches?(id)
        raise Blocked.new("invalid_address")
      end
      id
    rescue TypeCastError
      raise Blocked.new("invalid_address")
    end
  end
end
