module Tinrelay
  @[Link("sodium")]
  lib LibSodium
    fun sodium_init : Int32
    fun sodium_memcmp(a : Void*, b : Void*, len : LibC::SizeT) : Int32
    fun sodium_memzero(pointer : Void*, length : LibC::SizeT)
    fun randombytes_buf(buf : Void*, size : LibC::SizeT)

    fun crypto_sign_keypair(pk : UInt8*, sk : UInt8*) : Int32
    fun crypto_sign_seed_keypair(pk : UInt8*, sk : UInt8*, seed : UInt8*) : Int32
    fun crypto_sign_detached(
      sig : UInt8*,
      siglen : UInt64*,
      message : UInt8*,
      message_len : UInt64,
      sk : UInt8*,
    ) : Int32
    fun crypto_sign_verify_detached(
      sig : UInt8*,
      message : UInt8*,
      message_len : UInt64,
      pk : UInt8*,
    ) : Int32

    fun crypto_box_keypair(pk : UInt8*, sk : UInt8*) : Int32
    fun crypto_box_seal(
      ciphertext : UInt8*,
      message : UInt8*,
      message_len : UInt64,
      pk : UInt8*,
    ) : Int32
    fun crypto_box_seal_open(
      message : UInt8*,
      ciphertext : UInt8*,
      ciphertext_len : UInt64,
      pk : UInt8*,
      sk : UInt8*,
    ) : Int32

    fun crypto_pwhash(
      out : UInt8*,
      out_len : UInt64,
      password : UInt8*,
      password_len : UInt64,
      salt : UInt8*,
      opslimit : UInt64,
      memlimit : LibC::SizeT,
      algorithm : Int32,
    ) : Int32
    fun crypto_pwhash_alg_argon2id13 : Int32

    fun crypto_aead_xchacha20poly1305_ietf_encrypt(
      ciphertext : UInt8*,
      ciphertext_len : UInt64*,
      message : UInt8*,
      message_len : UInt64,
      additional : UInt8*,
      additional_len : UInt64,
      nsec : UInt8*,
      nonce : UInt8*,
      key : UInt8*,
    ) : Int32
    fun crypto_aead_xchacha20poly1305_ietf_decrypt(
      message : UInt8*,
      message_len : UInt64*,
      nsec : UInt8*,
      ciphertext : UInt8*,
      ciphertext_len : UInt64,
      additional : UInt8*,
      additional_len : UInt64,
      nonce : UInt8*,
      key : UInt8*,
    ) : Int32
  end

  module Crypto
    SIGN_PUBLIC_BYTES   = 32
    SIGN_SECRET_BYTES   = 64
    SIGNATURE_BYTES     = 64
    SIGN_SEED_BYTES     = 32
    BOX_PUBLIC_BYTES    = 32
    BOX_SECRET_BYTES    = 32
    SEAL_OVERHEAD_BYTES = 48
    PWHASH_SALT_BYTES   = 16
    KEY_BYTES           = 32
    XCHACHA_NONCE_BYTES = 24
    XCHACHA_TAG_BYTES   = 16
    KDF_PROFILE         = "argon2id13-opslimit3-mem64m"
    KEYRING_AD          = "tinrelay-keyring-v1".to_slice
    OWNER_KEY_AD        = "tinrelay-owner-key-v1".to_slice

    record SigningKeyPair, public_key : Bytes, secret_key : Bytes
    record BoxKeyPair, public_key : Bytes, secret_key : Bytes

    @@initialized = false

    def self.init : Nil
      return if @@initialized
      raise Error.new("libsodium initialization failed") if LibSodium.sodium_init < 0
      @@initialized = true
    end

    def self.random(size : Int32) : Bytes
      init
      bytes = Bytes.new(size)
      LibSodium.randombytes_buf(bytes, bytes.size)
      bytes
    end

    def self.signing_keypair : SigningKeyPair
      init
      public_key = Bytes.new(SIGN_PUBLIC_BYTES)
      secret_key = Bytes.new(SIGN_SECRET_BYTES)
      check LibSodium.crypto_sign_keypair(public_key, secret_key), "signing key generation"
      SigningKeyPair.new(public_key, secret_key)
    end

    def self.signing_keypair(seed : Bytes) : SigningKeyPair
      require_size(seed, SIGN_SEED_BYTES, "signing seed")
      init
      public_key = Bytes.new(SIGN_PUBLIC_BYTES)
      secret_key = Bytes.new(SIGN_SECRET_BYTES)
      check(
        LibSodium.crypto_sign_seed_keypair(public_key, secret_key, seed),
        "seeded signing key generation"
      )
      SigningKeyPair.new(public_key, secret_key)
    end

    def self.box_keypair : BoxKeyPair
      init
      public_key = Bytes.new(BOX_PUBLIC_BYTES)
      secret_key = Bytes.new(BOX_SECRET_BYTES)
      check LibSodium.crypto_box_keypair(public_key, secret_key), "encryption key generation"
      BoxKeyPair.new(public_key, secret_key)
    end

    def self.sign(message : Bytes, secret_key : Bytes) : Bytes
      require_size(secret_key, SIGN_SECRET_BYTES, "signing secret key")
      signature = Bytes.new(SIGNATURE_BYTES)
      signature_len = 0_u64
      check(
        LibSodium.crypto_sign_detached(
          signature,
          pointerof(signature_len),
          message,
          message.size.to_u64,
          secret_key
        ),
        "signature"
      )
      raise Error.new("unexpected signature length") unless signature_len == SIGNATURE_BYTES
      signature
    end

    def self.verify(message : Bytes, signature : Bytes, public_key : Bytes) : Bool
      require_size(signature, SIGNATURE_BYTES, "signature")
      require_size(public_key, SIGN_PUBLIC_BYTES, "signing public key")
      LibSodium.crypto_sign_verify_detached(
        signature,
        message,
        message.size.to_u64,
        public_key
      ) == 0
    end

    def self.seal(message : Bytes, public_key : Bytes) : Bytes
      require_size(public_key, BOX_PUBLIC_BYTES, "encryption public key")
      ciphertext = Bytes.new(message.size + SEAL_OVERHEAD_BYTES)
      check(
        LibSodium.crypto_box_seal(ciphertext, message, message.size.to_u64, public_key),
        "sealed-box encryption"
      )
      ciphertext
    end

    def self.open(ciphertext : Bytes, public_key : Bytes, secret_key : Bytes) : Bytes
      require_size(public_key, BOX_PUBLIC_BYTES, "encryption public key")
      require_size(secret_key, BOX_SECRET_BYTES, "encryption secret key")
      raise Invalid.new("sealed box is too short") if ciphertext.size < SEAL_OVERHEAD_BYTES
      message = Bytes.new(ciphertext.size - SEAL_OVERHEAD_BYTES)
      result = LibSodium.crypto_box_seal_open(
        message,
        ciphertext,
        ciphertext.size.to_u64,
        public_key,
        secret_key
      )
      raise Unauthorized.new("ciphertext authentication failed") unless result == 0
      message
    end

    def self.memzero(bytes : Bytes) : Nil
      LibSodium.sodium_memzero(bytes, bytes.size)
    end

    def self.constant_time_equal?(a : Bytes, b : Bytes) : Bool
      return false unless a.size == b.size
      LibSodium.sodium_memcmp(a, b, a.size) == 0
    end

    def self.derive_key(passphrase : String, salt : Bytes) : Bytes
      require_size(salt, PWHASH_SALT_BYTES, "keyring salt")
      key = Bytes.new(KEY_BYTES)
      password = passphrase.to_slice
      result = LibSodium.crypto_pwhash(
        key, key.size.to_u64, password, password.size.to_u64, salt,
        3_u64, (64 * 1024 * 1024).to_u64, LibSodium.crypto_pwhash_alg_argon2id13
      )
      unless result == 0
        memzero(key)
        raise Error.new("key derivation failed")
      end
      key
    end

    def self.encrypt_keyring(plaintext : Bytes, passphrase : String) : Tuple(Bytes, Bytes, Bytes)
      encrypt_blob(plaintext, passphrase, KEYRING_AD)
    end

    def self.encrypt_owner_key(plaintext : Bytes, passphrase : String) : Tuple(Bytes, Bytes, Bytes)
      encrypt_blob(plaintext, passphrase, OWNER_KEY_AD)
    end

    def self.encrypt_blob(
      plaintext : Bytes,
      passphrase : String,
      additional : Bytes,
    ) : Tuple(Bytes, Bytes, Bytes)
      salt = random(PWHASH_SALT_BYTES)
      nonce = random(XCHACHA_NONCE_BYTES)
      key = derive_key(passphrase, salt)
      begin
        # The fixed Argon2id13 profile turns the passphrase into a transient key;
        # versioned associated data keeps radio and cold-owner files in separate domains.
        ciphertext = Bytes.new(plaintext.size + XCHACHA_TAG_BYTES)
        ciphertext_len = 0_u64
        check LibSodium.crypto_aead_xchacha20poly1305_ietf_encrypt(
          ciphertext, pointerof(ciphertext_len), plaintext, plaintext.size.to_u64,
          additional, additional.size.to_u64, Pointer(UInt8).null, nonce, key
        ), "keyring encryption"
        {salt, nonce, ciphertext[0, ciphertext_len.to_i]}
      ensure
        memzero(key)
      end
    end

    def self.decrypt_keyring(
      ciphertext : Bytes,
      salt : Bytes,
      nonce : Bytes,
      passphrase : String,
    ) : Bytes
      decrypt_blob(ciphertext, salt, nonce, passphrase, KEYRING_AD)
    end

    def self.decrypt_owner_key(
      ciphertext : Bytes,
      salt : Bytes,
      nonce : Bytes,
      passphrase : String,
    ) : Bytes
      decrypt_blob(ciphertext, salt, nonce, passphrase, OWNER_KEY_AD)
    end

    def self.decrypt_blob(ciphertext : Bytes, salt : Bytes, nonce : Bytes,
                          passphrase : String, additional : Bytes) : Bytes
      require_size(nonce, XCHACHA_NONCE_BYTES, "keyring nonce")
      raise Invalid.new("encrypted keyring is too short") if ciphertext.size < XCHACHA_TAG_BYTES
      key = derive_key(passphrase, salt)
      begin
        # Authentication covers both ciphertext and the file-type domain before
        # any decrypted key material is accepted.
        plaintext = Bytes.new(ciphertext.size - XCHACHA_TAG_BYTES)
        plaintext_len = 0_u64
        result = LibSodium.crypto_aead_xchacha20poly1305_ietf_decrypt(
          plaintext, pointerof(plaintext_len), Pointer(UInt8).null,
          ciphertext, ciphertext.size.to_u64, additional, additional.size.to_u64,
          nonce, key
        )
        raise Unauthorized.new("keyring passphrase or contents are invalid") unless result == 0
        plaintext[0, plaintext_len.to_i]
      ensure
        memzero(key)
      end
    end

    def self.b64(bytes : Bytes) : String
      Base64.strict_encode(bytes)
    end

    def self.unb64(value : String, label : String = "base64 value") : Bytes
      Base64.decode(value)
    rescue Base64::Error
      raise Invalid.new("invalid #{label}")
    end

    def self.fingerprint(public_key : Bytes) : String
      Digest::SHA256.hexdigest(public_key)[0, 32]
    end

    private def self.require_size(bytes : Bytes, size : Int32, label : String) : Nil
      raise Invalid.new("invalid #{label} length") unless bytes.size == size
    end

    private def self.check(result : Int32, operation : String) : Nil
      raise Error.new("#{operation} failed") unless result == 0
    end
  end
end
