require "json"

module Tinrelay
  class TinrelaydConfig
    MAX_BYTES    = 64 * 1024
    DEFAULT_PATH = "tinrelayd.json"

    class Site
      include JSON::Serializable
      include JSON::Serializable::Strict

      getter site_name : String
      getter base_url : String
      getter wordmark : String
      getter art_manifest_path : String?

      def initialize(@site_name, @base_url, @wordmark,
                     @art_manifest_path = nil)
      end
    end

    include JSON::Serializable
    include JSON::Serializable::Strict

    getter site : Site

    def initialize(@site)
    end

    def self.load(explicit_path : String?) : self?
      path = explicit_path || DEFAULT_PATH
      bytes = File.open(path) do |file|
        buffer = IO::Memory.new
        count = IO.copy(file, buffer, MAX_BYTES + 1)
        if count > MAX_BYTES
          raise Invalid.new("tinrelayd configuration exceeds #{MAX_BYTES} bytes")
        end
        buffer.to_s
      end
      from_json(bytes)
    rescue File::NotFoundError
      return nil unless explicit_path
      raise Invalid.new("tinrelayd configuration cannot be read")
    rescue ex : File::Error
      raise Invalid.new("tinrelayd configuration cannot be read")
    rescue ex : JSON::ParseException | JSON::SerializableError
      raise Invalid.new("tinrelayd configuration is invalid")
    end
  end
end
