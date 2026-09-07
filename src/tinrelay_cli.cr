require "io/console"

require "./tinrelay/client_runtime"
require "./tinrelay/body_input"
require "./tinrelay/private_input"

module Tinrelay
  module CLI
    def self.run(argv : Array(String)) : Nil
      selected_ship = extract_unique(argv, "--ship")
      command = argv.shift? || "help"
      if command.in?({"help", "--help", "-h"})
        puts HELP
        return
      end
      if command.in?({"version", "--version", "-v"})
        puts "tinrelay #{VERSION} protocol #{PROTOCOL} build #{BUILD_LABEL}"
        return
      end

      ship = Names.ship!(selected_ship || raise Invalid.new("--ship SHIP is required"))
      paths = LocalPaths.new(ship, home)
      passphrase_file = extract(argv, "--passphrase-file")

      case command
      when "join"
        server = required(argv, "--server")
        no_extra!(argv)
        joined = Client.join(
          paths.keyring, server, ship, passphrase(paths, passphrase_file), paths.owner_key
        )
        puts({state: "claimed", ship: ship, radio_keyring: paths.keyring,
              owner_key: joined.keyring.owner_path}.to_json)
      when "who"
        target_ship = argv.shift? ||
                      raise Invalid.new("who requires a ship name or local@ship coordinate")
        no_extra!(argv)
        puts client(paths, passphrase_file).who(target_ship)
      when "hail"
        recipient_ship = argv.shift? || raise Invalid.new("hail requires a destination ship name")
        no_extra!(argv)
        hail = client(paths, passphrase_file).hail(recipient_ship)
        puts hail.submission_evidence.to_json
      when "send"
        recipient = argv.shift? || raise Invalid.new("send requires local@ship")
        from_label = extract(argv, "--as")
        Names.coordinate!(recipient)
        from_label.try { |label| Names.label!(label) }
        no_extra!(argv)
        if passphrase_file == "-"
          raise Invalid.new("transmission body and passphrase cannot both read stdin")
        end
        sender = client(paths, passphrase_file)
        body = BodyInput.read
        envelope = sender.send(
          recipient, body, from_label, outbox: Outbox.new(paths.outbox),
          observer: OutgoingObserver.from_config(paths.outgoing_observer)
        )
        puts envelope.submission_evidence.to_json
      when "outbox"
        outbox(argv, paths, passphrase_file)
      when "radio"
        radio(argv, ship, paths, passphrase_file)
      when "inbox"
        inbox(argv, paths)
      when "owner"
        owner(argv, paths, passphrase_file)
      when "contact"
        contact(argv, ship, paths, passphrase_file)
      when "ship"
        operation = argv.shift? || raise Invalid.new("ship requires freeze, activate, or revoke")
        unless operation.in?({"freeze", "activate", "revoke"})
          raise Invalid.new("invalid ship operation")
        end
        no_extra!(argv)
        client(paths, passphrase_file).ship_change(operation)
        puts({state: operation}.to_json)
      else
        raise Invalid.new("unknown command: #{command}")
      end
    rescue ex : ProtocolMismatch
      STDERR.puts({
        error: "protocol_incompatible", product_version: VERSION,
        client_protocol: PROTOCOL, build_label: BUILD_LABEL,
        server_supported_min: ex.supported_min,
        server_supported_max: ex.supported_max, relation: ex.relation,
        message: "This source-built TinRelay client is incompatible with the service. " +
                 "Inspect the retained checkout, the actual error, tests, local configuration, " +
                 "safe logs, and relevant upstream changes; explain and test any proposed " +
                 "repair before adoption.",
      }.to_json)
      exit 2
    rescue ex : TransportUnavailable
      report_transport_unavailable(ex)
      exit 2
    rescue ex : Error
      STDERR.puts({error: ex.class.name.split("::").last.underscore, message: ex.message}.to_json)
      exit 2
    rescue ex : ArgumentError
      STDERR.puts({error: "invalid_argument", message: ex.message}.to_json)
      exit 2
    end

    private def self.owner(argv, paths, passphrase_file) : Nil
      operation = argv.shift? || raise Invalid.new("owner requires rotate")
      raise Invalid.new("invalid owner operation") unless operation == "rotate"
      no_extra!(argv)
      generation = client(paths, passphrase_file).rotate_owner
      puts({state: "rotated", owner_generation: generation}.to_json)
    end

    private def self.contact(argv, ship, paths, passphrase_file) : Nil
      operation = argv.shift? || raise Invalid.new("contact requires allow, close, or unblock")
      case operation
      when "allow"
        local_hail_id = argv.shift? || raise Invalid.new("contact allow requires a local hail ID")
        no_extra!(argv)
        allowed = client(paths, passphrase_file)
          .allow_contact(local_hail_id, Spool.new(paths.spool))
        puts({state: "relationship_active", ship: ship, peer_ship: allowed.ship,
              local_hail_id: local_hail_id}.to_json)
      when "close"
        peer = argv.shift? || raise Invalid.new("contact close requires a peer ship")
        no_extra!(argv)
        generation = client(paths, passphrase_file).close_contact(peer)
        puts({state: "closed", ship: ship, peer_ship: peer,
              radio_generation: generation}.to_json)
      when "unblock"
        peer = argv.shift? || raise Invalid.new("contact unblock requires a peer ship")
        no_extra!(argv)
        unblocked = client(paths, passphrase_file).unblock_contact(peer)
        puts({state: "unblocked", ship: ship, peer_ship: unblocked.ship}.to_json)
      else
        raise Invalid.new("invalid contact operation")
      end
    end

    private def self.radio(argv, ship, paths, passphrase_file) : Nil
      operation = argv.shift? ||
                  raise Invalid.new("radio requires collect, wait, poll, status, or routed")
      case operation
      when "collect"
        spool = Spool.new(paths.spool)
        no_extra!(argv)
        receiver = client(paths, passphrase_file)
        retry_delay = 1
        loop do
          begin
            event = receiver.radio_collect(spool)
            retry_delay = 1
            puts({state: "collected", local_id: event.local_id, kind: event.kind}.to_json)
            STDOUT.flush
          rescue ex : TransportUnavailable
            report_transport_unavailable(ex)
            sleep retry_delay.seconds
            retry_delay = Math.min(retry_delay * 2, 30)
          end
        end
      when "wait"
        local = !!argv.delete("--local")
        spool = Spool.new(paths.spool)
        no_extra!(argv)
        event = if local
                  LocalRadio.wait(ship, spool)
                else
                  client(paths, passphrase_file).radio_wait(spool)
                end
        puts event.to_json
      when "poll"
        spool = Spool.new(paths.spool)
        no_extra!(argv)
        event = client(paths, passphrase_file).radio_poll(spool)
        puts(event ? event.to_json : %({"state":"quiet"}))
      when "routed"
        id = argv.shift? || raise Invalid.new("radio routed requires a local transmission id")
        spool = Spool.new(paths.spool)
        no_extra!(argv)
        record = spool.routed(id)
        puts({state: "routed", id: record.local_id}.to_json)
      when "status"
        id = argv.shift? || raise Invalid.new("radio status requires a local transmission id")
        spool = Spool.open_existing(paths.spool)
        no_extra!(argv)
        puts spool.status(id).to_json
      else
        raise Invalid.new("radio requires collect, wait, poll, status, or routed")
      end
    end

    private def self.inbox(argv, paths) : Nil
      operation = argv.shift? || raise Invalid.new("inbox requires list or show")
      case operation
      when "list"
        no_extra!(argv)
        spool = Spool.new(paths.spool)
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
                received_at: record.received_at,
                state: record.routed ? "routed" : "pending"}.merge(source).to_json)
        end
      when "show"
        id = argv.shift? || raise Invalid.new("inbox show requires a local transmission id")
        no_extra!(argv)
        spool = Spool.new(paths.spool)
        puts spool.inspection(id)
      else
        raise Invalid.new("inbox requires list or show")
      end
    end

    private def self.outbox(argv, paths, passphrase_file) : Nil
      operation = argv.shift? || raise Invalid.new("outbox requires list or retry")
      box = Outbox.new(paths.outbox)
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
        envelope = client(paths, passphrase_file).retry(box, id)
        puts envelope.submission_evidence.to_json
      else
        raise Invalid.new("outbox requires list or retry")
      end
    end

    private def self.client(paths, passphrase_file) : Client
      phrase = passphrase(paths, passphrase_file)
      Client.new(Keyring.load(paths.keyring, phrase, paths.owner_key), phrase)
    end

    private def self.report_transport_unavailable(ex : TransportUnavailable) : Nil
      STDERR.puts({
        error: "transport_unavailable", retryable: true,
        message: ex.message,
      }.to_json)
      STDERR.flush
    end

    private def self.passphrase(paths : LocalPaths, path : String?) : String
      return PrivateInput.read(path, "passphrase") if path
      default_path = paths.passphrase
      return PrivateInput.read(default_path, "passphrase") if File.file?(default_path)
      unless STDIN.tty?
        raise Invalid.new(
          "passphrase file not found at #{default_path}; create that owner-only file or use " +
          "--passphrase-file PATH (no interactive terminal is available)"
        )
      end
      STDERR.print "TinRelay passphrase: "
      value = STDIN.noecho &.gets
      STDERR.puts
      (value || raise Invalid.new("passphrase input ended unexpectedly")).chomp
    end

    private def self.extract(argv : Array(String), name : String) : String?
      index = argv.index(name)
      return nil unless index
      raise Invalid.new("#{name} requires a value") unless index + 1 < argv.size
      argv.delete_at(index)
      argv.delete_at(index)
    end

    private def self.extract_unique(argv : Array(String), name : String) : String?
      raise Invalid.new("#{name} may be provided only once") if argv.count(name) > 1
      extract(argv, name)
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
