require "./tinrelay/server"

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
      when "serve"
        serve(argv)
      else
        raise Invalid.new("unknown tinrelayd command: #{command}")
      end
    rescue ex : Error
      STDERR.puts({error: ex.class.name.split("::").last.underscore, message: ex.message}.to_json)
      exit 2
    end

    private def self.serve(argv) : Nil
      database_path = required(argv, "--database")
      bind = extract(argv, "--bind") || "127.0.0.1"
      port = (extract(argv, "--port") || "8787").to_i
      template = extract(argv, "--bootstrap-template") || "templates/common-bootstrap.md"
      source_repository = extract(argv, "--source-repository") ||
                          "https://github.com/mieko/tinrelay"
      art_manifest_path = ENV["TINRELAY_ART_MANIFEST"]?
      threads = ServerRuntime.thread_count(extract(argv, "--threads"))
      no_extra!(argv)
      ServerRuntime.enable_multicore(threads)
      config = ServerConfig.new(
        bind, port, database_path, template,
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
          if result.values.any?(&.> 0)
            STDERR.puts({
              event:   "cleanup",
              expired: result[:expired],
              deleted: result[:deleted],
            }.to_json)
          end
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
