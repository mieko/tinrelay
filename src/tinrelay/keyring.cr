module Tinrelay
  class StoredKeyPair
    include JSON::Serializable

    property public_key : String
    property secret_key : String

    def initialize(@public_key, @secret_key)
    end
  end

  class ShipRadioIdentity
    include JSON::Serializable

    property generation : Int32
    property signing : StoredKeyPair
    property encryption : StoredKeyPair
    property certificate : ShipRadioCertificate
    property retire_after : Int64?

    def initialize(@generation, @signing, @encryption, @certificate,
                   @retire_after = nil)
    end
  end

  class ShipContact
    include JSON::Serializable

    property ship : String
    property owner_generation : Int32
    property owner_public_key : String
    property owner_chain : Array(OwnerKeyLink)
    property radio_certificate : ShipRadioCertificate
    property default_label : String
    property pinned_at : Int64
    property blocked_at : Int64?

    def initialize(@ship, @owner_generation, @owner_public_key,
                   @radio_certificate, @default_label,
                   @pinned_at = Time.utc.to_unix, @blocked_at = nil,
                   owner_chain : Array(OwnerKeyLink)? = nil)
      @owner_chain = owner_chain || [OwnerKeyLink.new(@owner_generation, @owner_public_key)]
    end

    def blocked? : Bool
      !blocked_at.nil?
    end
  end

  class KeyringData
    include JSON::Serializable

    property format : Int32
    property server : String
    property ship : String
    property owner_generation : Int32
    property owner_public_key : String
    property active_radio_generation : Int32
    property radios : Array(ShipRadioIdentity)
    property pending_radio : ShipRadioIdentity?
    property contacts : Array(ShipContact)

    def initialize(@server, @ship, @owner_public_key, @radios,
                   @owner_generation = 1,
                   @active_radio_generation = 1,
                   @pending_radio = nil,
                   @contacts = [] of ShipContact,
                   @format = 2)
    end

    def radio!(generation : Int32? = nil) : ShipRadioIdentity
      wanted = generation || active_radio_generation
      identity = radios.find { |radio| radio.generation == wanted }
      identity || raise NotFound.new("ship radio key is not in this keyring")
    end

    def contact!(ship : String) : ShipContact
      contacts.find { |contact| contact.ship == ship } ||
        raise NotFound.new("ship #{ship} is not pinned")
    end
  end

  class OwnerKeyData
    include JSON::Serializable

    property format : Int32
    property ship : String
    property generation : Int32
    property key : StoredKeyPair
    property pending_generation : Int32?
    property pending_key : StoredKeyPair?

    def initialize(@ship, @generation, @key,
                   @pending_generation = nil, @pending_key = nil,
                   @format = 1)
    end
  end

  class EncryptedKeyring
    include JSON::Serializable

    property format : Int32
    property kdf : String
    property salt : String
    property nonce : String
    property ciphertext : String

    def initialize(@salt, @nonce, @ciphertext, @format = 1,
                   @kdf = Crypto::KDF_PROFILE)
    end
  end

  class Keyring
    getter path : String
    getter owner_path : String
    getter data : KeyringData

    def initialize(@path, @owner_path, @data)
    end

    def self.create(path : String, server : String, ship : String,
                    passphrase : String, owner_path : String? = nil,
                    now : Time = Time.utc) : Keyring
      Names.ship!(ship)
      ensure_passphrase!(passphrase)
      raise Conflict.new("keyring already exists") if File.exists?(path)
      owner_file = owner_path || "#{path}.owner"
      raise Conflict.new("owner key file already exists") if File.exists?(owner_file)

      owner_keys = Crypto.signing_keypair
      signing_keys = Crypto.signing_keypair
      encryption_keys = Crypto.box_keypair
      certificate = ShipRadioCertificate.new(
        ship, 1, Crypto.b64(signing_keys.public_key),
        Crypto.b64(encryption_keys.public_key), now.to_unix, 1
      )
      certificate.owner_signature = Crypto.b64(
        Crypto.sign(certificate.unsigned_bytes, owner_keys.secret_key)
      )
      owner = StoredKeyPair.new(
        Crypto.b64(owner_keys.public_key), Crypto.b64(owner_keys.secret_key)
      )
      radio = ShipRadioIdentity.new(
        1,
        StoredKeyPair.new(
          Crypto.b64(signing_keys.public_key),
          Crypto.b64(signing_keys.secret_key)
        ),
        StoredKeyPair.new(
          Crypto.b64(encryption_keys.public_key),
          Crypto.b64(encryption_keys.secret_key)
        ),
        certificate
      )
      keyring = new(
        path, owner_file,
        KeyringData.new(server, ship, owner.public_key, [radio])
      )
      begin
        keyring.save_owner(OwnerKeyData.new(ship, 1, owner), passphrase)
        keyring.save(passphrase)
      rescue ex
        File.delete(owner_file) if File.exists?(owner_file)
        File.delete(path) if File.exists?(path)
        raise ex
      end
      keyring
    end

    def self.load(path : String, passphrase : String,
                  owner_path : String? = nil) : Keyring
      encrypted = EncryptedKeyring.from_json(File.read(path))
      raise Invalid.new("unsupported keyring envelope format") unless encrypted.format == 1
      unless encrypted.kdf == Crypto::KDF_PROFILE
        raise Invalid.new("unsupported keyring KDF profile")
      end
      plaintext = Crypto.decrypt_keyring(
        Crypto.unb64(encrypted.ciphertext, "keyring ciphertext"),
        Crypto.unb64(encrypted.salt, "keyring salt"),
        Crypto.unb64(encrypted.nonce, "keyring nonce"),
        passphrase
      )
      data = KeyringData.from_json(String.new(plaintext))
      raise Invalid.new("unsupported ship keyring format") unless data.format == 2
      new(path, owner_path || "#{path}.owner", data)
    rescue ex : File::NotFoundError
      raise NotFound.new("keyring not found: #{path}")
    rescue ex : JSON::ParseException
      raise Invalid.new("keyring file is invalid")
    end

    def owner(passphrase : String) : OwnerKeyData
      encrypted = EncryptedKeyring.from_json(File.read(owner_path))
      raise Invalid.new("unsupported owner key envelope format") unless encrypted.format == 1
      unless encrypted.kdf == Crypto::KDF_PROFILE
        raise Invalid.new("unsupported owner key KDF profile")
      end
      plaintext = Crypto.decrypt_owner_key(
        Crypto.unb64(encrypted.ciphertext, "owner key ciphertext"),
        Crypto.unb64(encrypted.salt, "owner key salt"),
        Crypto.unb64(encrypted.nonce, "owner key nonce"), passphrase
      )
      owner = OwnerKeyData.from_json(String.new(plaintext))
      raise Invalid.new("unsupported owner key format") unless owner.format == 1
      unless owner.ship == data.ship && owner.generation == data.owner_generation &&
             owner.key.public_key == data.owner_public_key
        raise Unauthorized.new("owner key does not match the ship keyring")
      end
      owner
    rescue ex : File::NotFoundError
      raise NotFound.new("owner key not found: #{owner_path}")
    rescue ex : JSON::ParseException
      raise Invalid.new("owner key file is invalid")
    end

    def save_owner(owner : OwnerKeyData, passphrase : String) : Nil
      self.class.ensure_passphrase!(passphrase)
      salt, nonce, ciphertext = Crypto.encrypt_owner_key(
        owner.to_json.to_slice, passphrase
      )
      encoded = EncryptedKeyring.new(
        Crypto.b64(salt), Crypto.b64(nonce), Crypto.b64(ciphertext)
      ).to_pretty_json
      write_private(owner_path, encoded)
    end

    def save(passphrase : String) : Nil
      self.class.ensure_passphrase!(passphrase)
      salt, nonce, ciphertext = Crypto.encrypt_keyring(
        data.to_json.to_slice, passphrase
      )
      encoded = EncryptedKeyring.new(
        Crypto.b64(salt), Crypto.b64(nonce), Crypto.b64(ciphertext)
      ).to_pretty_json
      write_private(path, encoded)
    end

    private def write_private(target : String, encoded : String) : Nil
      directory = File.dirname(target)
      unless Dir.exists?(directory)
        Dir.mkdir_p(directory, mode: 0o700)
        File.chmod(directory, 0o700)
      end
      temporary = "#{target}.tmp.#{Process.pid}"
      begin
        File.open(temporary, "w", perm: 0o600) do |file|
          file << encoded << '\n'
          file.flush
          file.fsync
        end
        File.chmod(temporary, 0o600)
        File.rename(temporary, target)
        File.open(directory, "r", &.fsync)
      ensure
        File.delete(temporary) if File.exists?(temporary)
      end
    end

    def pin_hail(record : HailSpoolRecord) : ShipContact
      ship = Names.ship!(record.sender_ship)
      certificate = record.sender_radio_certificate
      owner = record.sender_owner_chain.last? ||
              raise Invalid.new("hail has no ship owner identity")
      prior = data.contacts.find { |item| item.ship == ship }
      return prior if prior
      contact = ShipContact.new(
        ship, owner.generation, owner.public_key, certificate,
        "unresolved",
        owner_chain: record.sender_owner_chain
      )
      data.contacts << contact
      contact
    end

    def block!(ship : String, now : Int64 = Time.utc.to_unix) : ShipContact
      contact = data.contact!(Names.ship!(ship))
      contact.blocked_at ||= now
      contact
    end

    def unblock!(ship : String) : ShipContact
      contact = data.contact!(Names.ship!(ship))
      contact.blocked_at = nil
      contact
    end

    def prune_retired_radios!(now : Int64 = Time.utc.to_unix) : Bool
      before = data.radios.size
      data.radios.reject! do |radio|
        radio.generation != data.active_radio_generation &&
          radio.retire_after.try { |deadline| deadline <= now }
      end
      data.radios.size != before
    end

    def self.ensure_passphrase!(passphrase : String) : Nil
      if passphrase.bytesize < 12
        raise Invalid.new("keyring passphrase must contain at least 12 characters")
      end
    end
  end
end
