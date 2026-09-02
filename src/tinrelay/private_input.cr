module Tinrelay
  module PrivateInput
    def self.read(path : String, label : String, stdin : IO = STDIN) : String
      value = if path == "-"
                stdin.gets_to_end
              else
                raise NotFound.new("#{label} file not found") unless File.file?(path)
                permissions = File.info(path).permissions.value & 0o777
                if permissions & 0o077 != 0
                  raise Invalid.new("#{label} file must not be accessible by group or others")
                end
                File.read(path)
              end
      value = value.chomp
      raise Invalid.new("#{label} is empty") if value.empty?
      value
    end
  end
end
