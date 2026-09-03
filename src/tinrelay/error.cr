module Tinrelay
  class Error < Exception
  end

  class Invalid < Error
  end

  class Unauthorized < Error
  end

  class Conflict < Error
  end

  class Unavailable < Error
  end

  class Maintenance < Unavailable
    getter back_at : Time?

    def initialize(@back_at = nil)
      suffix = back_at.try { |time| "; expected return #{time.to_rfc3339}" } || ""
      super("relay is temporarily unavailable for maintenance#{suffix}")
    end
  end

  class NotFound < Error
  end

  class Expired < Error
  end

  class AcceptanceUnknown < Error
    getter transmission_id : String
    getter sender_ship : String

    def initialize(@transmission_id, @sender_ship, detail : String? = nil)
      suffix = detail ? ": #{detail}" : ""
      super("relay acceptance is unknown for transmission #{transmission_id}; exact encrypted envelope retained; retry with: tinrelay outbox retry #{transmission_id} --ship #{sender_ship}#{suffix}")
    end
  end

  class HailAcceptanceUnknown < Error
    getter sender_ship : String
    getter recipient_ship : String

    def initialize(@sender_ship, @recipient_ship, detail : String? = nil)
      suffix = detail ? ": #{detail}" : ""
      super("relay acceptance is unknown for hail#{suffix}; run again with: tinrelay hail #{recipient_ship} --ship #{sender_ship}")
    end
  end

  class ProtocolMismatch < Error
    getter client_protocol : Int32
    getter supported_min : Int32
    getter supported_max : Int32
    getter relation : String

    def initialize(@client_protocol, @supported_min, @supported_max, @relation)
      super("client protocol #{client_protocol} is #{relation} than supported range #{supported_min}..#{supported_max}")
    end
  end
end
