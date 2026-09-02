require "./tinrelay/server"
require "./tinrelay/private_input"

module Tinrelay
  module ServerCLI
    def self.run(argv : Array(String)) : Nil
      command = argv.shift? || "help"
      case command
      when "help", "--help", "-h"
        puts HELP
      when "version", "--version", "-v"
        puts "tinrelayd #{VERSION} protocol #{PROTOCOL} build #{BUILD_LABEL}"
      when "migrate"
        database = Database.new(required(argv, "--database"))
        database.close
        no_extra!(argv)
        puts({state: "migrated"}.to_json)
      when "cleanup"
        database = Database.new(required(argv, "--database"))
        result = Store.new(database).cleanup
        database.close
        no_extra!(argv)
        puts result.to_json
      when "admission"
        admission(argv)
      when "serve"
        serve(argv)
      else
        raise Invalid.new("unknown tinrelayd command: #{command}")
      end
    rescue ex : Error
      STDERR.puts({error: ex.class.name.split("::").last.underscore, message: ex.message}.to_json)
      exit 2
    end

    private def self.admission(argv) : Nil
      operation = argv.shift? || raise Invalid.new("admission requires create or revoke")
      database = Database.new(required(argv, "--database"))
      store = Store.new(database)
      case operation
      when "create"
        ship = Names.ship!(required(argv, "--ship"))
        server = required(argv, "--server").rstrip('/')
        Origin.validate!(server)
        ttl = (extract(argv, "--ttl-seconds") || "86400").to_i64
        no_extra!(argv)
        id = Ids.uuid
        secret_bytes = Crypto.random(32)
        secret = Crypto.b64(secret_bytes)
        expires_at = Time.utc.to_unix + ttl
        store.create_admission(
          id, ship, Digest::SHA256.digest(secret_bytes), expires_at
        )
        capability = ShipAdmission.new(
          server, id, ship, secret, expires_at
        )
        fragment = Base64.urlsafe_encode(capability.to_json, padding: false)
        puts({state: "created", admission_id: id, expires_at: expires_at,
              ship: ship, url: "#{server}/meet##{fragment}"}.to_json)
      when "revoke"
        id = argv.shift? || raise Invalid.new("admission revoke requires an admission id")
        no_extra!(argv)
        raise NotFound.new("admission not found") unless store.revoke_admission(id)
        puts({state: "revoked", admission_id: id}.to_json)
      else
        raise Invalid.new("admission requires create or revoke")
      end
    ensure
      database.try(&.close)
    end

    private def self.serve(argv) : Nil
      database_path = required(argv, "--database")
      bind = extract(argv, "--bind") || "127.0.0.1"
      port = (extract(argv, "--port") || "8787").to_i
      template = extract(argv, "--bootstrap-template") || "templates/common-bootstrap.md"
      source_repository = extract(argv, "--source-repository") || "https://github.com/mieko/tinrelay"
      bootstrap_token_file = extract(argv, "--bootstrap-token-file")
      art_manifest_path = ENV["TINRELAY_ART_MANIFEST"]?
      threads = ServerRuntime.thread_count(extract(argv, "--threads"))
      no_extra!(argv)
      ServerRuntime.enable_multicore(threads)
      bootstrap_hash = bootstrap_token_file.try do |path|
        Digest::SHA256.digest(PrivateInput.read(path, "bootstrap token"))
      end
      config = ServerConfig.new(
        bind, port, database_path, bootstrap_hash, template,
        source_repository, threads, art_manifest_path
      )
      api = API.new(config)
      server = HTTP::Server.new(api.handler)
      server.bind_tcp(bind, port)
      stopping = false
      stop = -> {
        unless stopping
          stopping = true
          STDERR.puts({event: "shutdown_requested"}.to_json)
          server.close
        end
      }
      Signal::INT.trap { stop.call }
      Signal::TERM.trap { stop.call }
      spawn do
        loop do
          sleep 60.seconds
          break if stopping
          result = api.store.cleanup
          STDERR.puts({event: "cleanup", expired: result[:expired], deleted: result[:deleted]}.to_json) if result.values.any?(&.> 0)
        rescue ex
          STDERR.puts({event: "cleanup_failed", error: ex.class.name}.to_json)
        end
      end
      STDERR.puts({event: "ready", bind: bind, port: port, protocol: PROTOCOL,
                   threads: threads}.to_json)
      server.listen
    ensure
      api.try(&.close)
      STDERR.puts({event: "stopped"}.to_json)
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

    HELP = {{ read_file("templates/tinrelayd-help.txt") }}
  end
end

Tinrelay::ServerCLI.run(ARGV.dup)
