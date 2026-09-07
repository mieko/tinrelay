require "json"
require "base64"
require "digest/sha256"
require "uri"

require "./version"
require "./error"
require "./crypto"
require "./model"

module Tinrelay
  MAX_SHIP_REGISTRATIONS_PER_HOUR = 300

  MAX_ORDINARY_RESPONSE_BYTES = 72_i64 * 1024

  module IdentityResponseBounds
    PERMANENT_ROW_SEPARATOR_BYTES = 1_i64
    FIXED_ENVELOPE_BYTES          = MAX_ORDINARY_RESPONSE_BYTES

    def self.maximum_permanent_row_bytes : Int64
      ship = "s" * 63 # Names::SHIP's longest ASCII value.
      generation = Int32::MAX
      timestamp = Int64::MAX
      signing_key = Crypto.b64(Bytes.new(Crypto::SIGN_PUBLIC_BYTES))
      encryption_key = Crypto.b64(Bytes.new(Crypto::BOX_PUBLIC_BYTES))
      signature = Crypto.b64(Bytes.new(Crypto::SIGNATURE_BYTES))
      fingerprint = "f" * 32

      sizes = [
        {
          ship: ship, claimed_at: timestamp, state: "revoked",
          admin_generation: timestamp,
          authority_notice: "ship namespace administration only; " +
                            "never human sponsor authority",
          owner_keys: [] of String, radio_keys: [] of String,
        }.to_json.bytesize,
        {
          generation: generation, public_key: signing_key,
          fingerprint: fingerprint, state: "rotated", valid_from: timestamp,
          revoked_at: timestamp, authorization_signature: signature,
        }.to_json.bytesize,
        {
          generation: generation, signing_public_key: signing_key,
          encryption_public_key: encryption_key,
          signing_fingerprint: fingerprint, encryption_fingerprint: fingerprint,
          state: "rotated", issued_at: timestamp, owner_generation: generation,
          owner_signature: signature, prior_radio_signature: signature,
          revoked_at: timestamp,
        }.to_json.bytesize,
        {
          ship: ship, to_generation: generation,
          owner_chain: [] of String, chain: [] of String,
        }.to_json.bytesize,
        {
          generation: generation, public_key: signing_key,
          authorization_signature: signature,
        }.to_json.bytesize,
        {
          certificate: {
            ship: ship, generation: generation, signing_public_key: signing_key,
            encryption_public_key: encryption_key, issued_at: timestamp,
            owner_generation: generation, owner_signature: signature,
          },
          prior_radio_signature: signature,
        }.to_json.bytesize,
      ]
      sizes.max.to_i64
    end
  end

  # Protocol 1 carries complete continuity history. For one waiting ship, each
  # contact update has a distinct owner and charges its wrapper to that owner's
  # relationship row; its owner/radio links are distinct charged history rows.
  # The ceiling therefore follows from the service's row allowance, one encoded
  # contribution and separator per row, plus fixed JSON framing.
  DEFAULT_PERMANENT_METADATA_LIMIT =  25_000_i64
  MAX_PERMANENT_METADATA_LIMIT     = 100_000_i64
  MAX_IDENTITY_RESPONSE_BYTES      =
    MAX_PERMANENT_METADATA_LIMIT *
      (IdentityResponseBounds.maximum_permanent_row_bytes +
        IdentityResponseBounds::PERMANENT_ROW_SEPARATOR_BYTES) +
      IdentityResponseBounds::FIXED_ENVELOPE_BYTES

  module Ids
    def self.uuid : String
      bytes = Crypto.random(16)
      bytes[6] = (bytes[6] & 0x0f) | 0x40
      bytes[8] = (bytes[8] & 0x3f) | 0x80
      hex = bytes.hexstring
      "#{hex[0, 8]}-#{hex[8, 4]}-#{hex[12, 4]}-#{hex[16, 4]}-#{hex[20, 12]}"
    end
  end

  module Origin
    def self.validate!(origin : String) : Nil
      uri = URI.parse(origin)
      local = uri.host.in?({"127.0.0.1", "localhost", "::1"})
      unless uri.scheme == "https" || (uri.scheme == "http" && local)
        raise Invalid.new("server URL must use https outside localhost")
      end
      unless uri.path.empty? || uri.path == "/"
        raise Invalid.new("server URL must not include a path")
      end
      if uri.user || uri.password || uri.query || uri.fragment
        raise Invalid.new("server URL must not contain credentials, query, or fragment")
      end
    end
  end
end
