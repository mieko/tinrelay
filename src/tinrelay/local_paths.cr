module Tinrelay
  struct LocalPaths
    getter keyring : String
    getter owner_key : String
    getter passphrase : String
    getter spool : String
    getter outbox : String

    def initialize(ship : String, home : String)
      ship = Names.ship!(ship)
      config = File.join(home, ".config", "tinrelay", ship)
      @keyring = File.join(config, "keyring")
      @owner_key = File.join(config, "owner-key")
      @passphrase = File.join(config, "passphrase")
      @spool = File.join(home, ".local", "share", "tinrelay", ship, "inbox")
      @outbox = File.join(home, ".local", "share", "tinrelay", ship, "outbox")
    end
  end
end
