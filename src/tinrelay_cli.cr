require "io/console"

require "./tinrelay/client_runtime"
require "./tinrelay/private_input"

module Tinrelay
  module CLI
    def self.run(argv : Array(String)) : Nil
      command = argv.shift? || "help"
      if command.in?({"help", "--help", "-h"})
        puts HELP
        return
      end
      if command.in?({"version", "--version", "-v"})
        puts "tinrelay #{VERSION} protocol #{PROTOCOL} build #{BUILD_LABEL}"
        return
      end

      selected_ship = extract(argv, "--ship")
      ship = Names.ship!(selected_ship || raise Invalid.new("--ship SHIP is required"))
      paths = LocalPaths.new(ship, home)
      keyring_path = extract(argv, "--keyring") || paths.keyring
      owner_path = extract(argv, "--owner-key") || paths.owner_key
      passphrase_file = extract(argv, "--passphrase-file")

      case command
      when "join"
        server = required(argv, "--server")
        no_extra!(argv)
        joined = Client.join(
          keyring_path, server, ship, passphrase(paths, passphrase_file), owner_path
        )
        puts({state: "claimed", ship: ship, radio_keyring: keyring_path,
              owner_key: joined.keyring.owner_path}.to_json)
      when "who"
        target_ship = argv.shift? || raise Invalid.new("who requires a ship name or local@ship coordinate")
        no_extra!(argv)
        puts client(keyring_path, owner_path, ship, passphrase_file).who(target_ship)
      when "hail"
        recipient_ship = argv.shift? || raise Invalid.new("hail requires a destination ship name")
        no_extra!(argv)
        hail = client(keyring_path, owner_path, ship, passphrase_file)
          .hail(recipient_ship)
        puts hail.submission_evidence.to_json
      when "send"
        recipient = argv.shift? || raise Invalid.new("send requires local@ship")
        from_label = extract(argv, "--as")
        outbox = Outbox.new(extract(argv, "--outbox") || paths.outbox)
        body = read_body(argv)
        expires = (extract(argv, "--expires-in") || FALLBACK_LIFETIME_SECONDS.to_s).to_i64
        no_extra!(argv)
        envelope = client(keyring_path, owner_path, ship, passphrase_file).send(
          recipient, body, from_label, expires_in: expires, outbox: outbox
        )
        puts envelope.submission_evidence.to_json
      when "outbox"
        outbox(argv, paths, keyring_path, owner_path, ship, passphrase_file)
      when "radio"
        radio(argv, ship, paths, keyring_path, owner_path, passphrase_file)
      when "inbox"
        inbox(argv, paths)
      when "owner-rotate"
        no_extra!(argv)
        generation = client(keyring_path, owner_path, ship, passphrase_file).rotate_owner
        puts({state: "rotated", owner_generation: generation}.to_json)
      when "ship"
        operation = argv.shift? || raise Invalid.new("ship requires freeze, activate, or revoke")
        raise Invalid.new("invalid ship operation") unless operation.in?({"freeze", "activate", "revoke"})
        no_extra!(argv)
        client(keyring_path, owner_path, ship, passphrase_file).ship_change(operation)
        puts({state: operation}.to_json)
      when "contact-close"
        peer = argv.shift? || raise Invalid.new("contact-close requires a peer ship")
        no_extra!(argv)
        generation = client(keyring_path, owner_path, ship, passphrase_file).close_contact(peer)
        puts({state: "closed", ship: ship, peer_ship: peer,
              radio_generation: generation}.to_json)
      when "contact-unblock"
        peer = argv.shift? || raise Invalid.new("contact-unblock requires a peer ship")
        no_extra!(argv)
        contact = client(keyring_path, owner_path, ship, passphrase_file).unblock_contact(peer)
        puts({state: "unblocked", ship: ship, peer_ship: contact.ship}.to_json)
      when "contact-allow"
        peer = argv.shift? || raise Invalid.new("contact-allow requires a peer ship")
        local_hail_id = required(argv, "--hail-id")
        spool = Spool.new(extract(argv, "--spool") || paths.spool)
        no_extra!(argv)
        client(keyring_path, owner_path, ship, passphrase_file)
          .allow_contact(peer, local_hail_id, spool)
        puts({state: "relationship_active", ship: ship, peer_ship: peer,
              local_hail_id: local_hail_id}.to_json)
      else
        raise Invalid.new("unknown command: #{command}")
      end
    rescue ex : ProtocolMismatch
      STDERR.puts({
        error: "protocol_incompatible", product_version: VERSION,
        client_protocol: PROTOCOL, build_label: BUILD_LABEL,
        server_supported_min: ex.supported_min,
        server_supported_max: ex.supported_max, relation: ex.relation,
        message: "This source-built Tinrelay client is incompatible with the service. Inspect the retained checkout, the actual error, tests, local configuration, safe logs, and relevant upstream changes; explain and test any proposed repair before adoption.",
      }.to_json)
      exit 2
    rescue ex : TransportUnavailable
      STDERR.puts({
        error: "transport_unavailable", retryable: true,
        message: ex.message,
      }.to_json)
      exit 2
    rescue ex : Error
      STDERR.puts({error: ex.class.name.split("::").last.underscore, message: ex.message}.to_json)
      exit 2
    rescue ex : ArgumentError
      STDERR.puts({error: "invalid_argument", message: ex.message}.to_json)
      exit 2
    end

    private def self.radio(argv, ship, paths, keyring_path, owner_path, passphrase_file) : Nil
      operation = argv.shift? || raise Invalid.new("radio requires wait, poll, status, or routed")
      case operation
      when "wait"
        spool = Spool.new(extract(argv, "--spool") || paths.spool)
        no_extra!(argv)
        puts client(keyring_path, owner_path, ship, passphrase_file).radio_wait(spool).to_json
      when "poll"
        spool = Spool.new(extract(argv, "--spool") || paths.spool)
        no_extra!(argv)
        event = client(keyring_path, owner_path, ship, passphrase_file).radio_poll(spool)
        puts(event ? event.to_json : %({"state":"quiet"}))
      when "routed"
        id = argv.shift? || raise Invalid.new("radio routed requires a local transmission id")
        spool = Spool.new(extract(argv, "--spool") || paths.spool)
        no_extra!(argv)
        record = spool.routed(id)
        puts({state: "routed", id: record.local_id, routed_at: record.routed_at}.to_json)
      when "status"
        id = argv.shift? || raise Invalid.new("radio status requires a local transmission id")
        spool = Spool.open_existing(extract(argv, "--spool") || paths.spool)
        no_extra!(argv)
        puts spool.status(id).to_json
      else
        raise Invalid.new("radio requires wait, poll, status, or routed")
      end
    end

    private def self.inbox(argv, paths) : Nil
      operation = argv.shift? || raise Invalid.new("inbox requires list or show")
      spool = Spool.new(extract(argv, "--spool") || paths.spool)
      case operation
      when "list"
        no_extra!(argv)
        spool.list.each do |record|
          source = case record
                   when TransmissionSpoolRecord
                     {sender_ship: record.sender_ship, attention_label: record.to_label}
                   when HailSpoolRecord
                     {sender_ship: record.sender_ship, attention_label: nil}
                   else
                     {sender_ship: nil, attention_label: nil}
                   end
          puts({id: record.local_id, kind: record.kind,
                received_at: record.received_at, routed_at: record.routed_at}.merge(source).to_json)
        end
      when "show"
        id = argv.shift? || raise Invalid.new("inbox show requires a local transmission id")
        no_extra!(argv)
        puts spool.inspection(id)
      else
        raise Invalid.new("inbox requires list or show")
      end
    end

    private def self.outbox(argv, paths, keyring_path, owner_path, ship,
                            passphrase_file) : Nil
      operation = argv.shift? || raise Invalid.new("outbox requires list or retry")
      box = Outbox.new(extract(argv, "--outbox") || paths.outbox)
      case operation
      when "list"
        no_extra!(argv)
        box.list.each do |envelope|
          puts({transmission_id: envelope.transmission_id, sender_ship: envelope.sender_ship,
                recipient_ship: envelope.recipient_ship,
                created_at: envelope.created_at,
                expires_at: envelope.expires_at,
                state: "acceptance_unknown"}.to_json)
        end
      when "retry"
        id = argv.shift? || raise Invalid.new("outbox retry requires a transmission id")
        no_extra!(argv)
        envelope = client(keyring_path, owner_path, ship, passphrase_file).retry(box, id)
        puts envelope.submission_evidence.to_json
      else
        raise Invalid.new("outbox requires list or retry")
      end
    end

    private def self.client(path, owner_path, ship, passphrase_file) : Client
      phrase = passphrase(LocalPaths.new(ship, home), passphrase_file)
      Client.new(Keyring.load(path, phrase, owner_path), phrase)
    end

    private def self.passphrase(paths : LocalPaths, path : String?) : String
      return PrivateInput.read(path, "passphrase") if path
      default_path = paths.passphrase
      return PrivateInput.read(default_path, "passphrase") if File.file?(default_path)
      unless STDIN.tty?
        raise Invalid.new("passphrase file not found at #{default_path}; create that owner-only file or use --passphrase-file PATH (no interactive terminal is available)")
      end
      STDERR.print "Tinrelay passphrase: "
      value = STDIN.noecho &.gets
      STDERR.puts
      (value || raise Invalid.new("passphrase input ended unexpectedly")).chomp
    end

    private def self.read_body(argv) : String
      body_file = extract(argv, "--body-file") ||
                  raise Invalid.new("provide --body-file PATH (or - for protected stdin)")
      body_file == "-" ? STDIN.gets_to_end : File.read(body_file)
    end

    private def self.extract(argv : Array(String), name : String) : String?
      index = argv.index(name)
      return nil unless index
      raise Invalid.new("#{name} requires a value") unless index + 1 < argv.size
      argv.delete_at(index)
      argv.delete_at(index)
    end

    private def self.required(argv, name) : String
      extract(argv, name) || raise Invalid.new("#{name} is required")
    end

    private def self.no_extra!(argv) : Nil
      raise Invalid.new("unexpected arguments: #{argv.join(' ')}") unless argv.empty?
    end

    private def self.home : String
      ENV["HOME"]? || "."
    end

    HELP = {{ read_file("templates/tinrelay-help.txt") }}
  end
end

Tinrelay::CLI.run(ARGV.dup)
