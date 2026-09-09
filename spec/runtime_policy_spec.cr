require "./spec_helper"

module TinrelayRuntimePolicySpec
  def self.server_config(root : String, configuration_path : String) : Tinrelay::ServerConfig
    Tinrelay::ServerConfig.new(
      database_path: File.join(root, "service.db"),
      bootstrap_template: File.expand_path("../templates/common-bootstrap.md", __DIR__),
      source_repository: "https://example.test/tinrelay.git",
      configuration_path: configuration_path
    )
  end

  def self.write_site_only(path : String) : Nil
    File.write(path, {
      site: {
        site_name: "First Site", base_url: "https://first.example",
        wordmark: "First Mark", art_manifest_path: nil,
      },
    }.to_json)
  end

  def self.write_complete(path : String, exclude = [] of String) : Nil
    File.write(path, {
      site: {
        site_name: "Second Site", base_url: "https://second.example",
        wordmark: "Second Mark", art_manifest_path: nil,
      },
      registration: {
        global_hour: 301, global_day: 1001,
        per_source_hour: 5, per_source_day: 6,
        deny_cidrs: ["192.0.2.0/24", "2001:db8::/32"],
        exclude: exclude,
      },
      client_address: {
        mode:                  "trusted_proxy",
        trusted_ingress_cidrs: ["198.51.100.0/24"],
      },
    }.to_json)
  end

  def self.claim(api : Tinrelay::API, ship : String) : Nil
    owner = Tinrelay::Crypto.signing_keypair
    signing = Tinrelay::Crypto.signing_keypair
    encryption = Tinrelay::Crypto.box_keypair
    certificate = Tinrelay::ShipRadioCertificate.new(
      ship, 1, Tinrelay::Crypto.b64(signing.public_key),
      Tinrelay::Crypto.b64(encryption.public_key), Time.utc.to_unix, 1
    )
    certificate.owner_signature = Tinrelay::Crypto.b64(
      Tinrelay::Crypto.sign(certificate.unsigned_bytes, owner.secret_key)
    )
    api.store.claim(api.store.prepare_claim(Tinrelay::ShipClaim.new(
      ship, Tinrelay::Crypto.b64(owner.public_key), certificate
    )))
  end
end

describe "tinrelayd runtime policy" do
  it "gives a site-only configuration the exact policy defaults" do
    root = TinrelaySpec.temporary_root
    path = File.join(root, "tinrelayd.json")
    TinrelayRuntimePolicySpec.write_site_only(path)
    api = Tinrelay::API.new(TinrelayRuntimePolicySpec.server_config(root, path))
    begin
      snapshot = api.runtime_snapshot
      allowances = snapshot.registration_allowances
      allowances.global_hour.should eq(300)
      allowances.global_day.should eq(1000)
      allowances.per_source_hour.should eq(4)
      allowances.per_source_day.should eq(4)
      snapshot.registration_deny_cidrs.should be_empty
      snapshot.client_address_policy.mode.should eq(Tinrelay::ClientAddressMode::Direct)
      snapshot.client_address_policy.trusted_ingress_cidrs.should be_empty
    ensure
      api.close
      FileUtils.rm_r(root)
    end
  end

  it "bounds exclusion names before registry validation" do
    names = Array.new(256) { |index| "ship-#{index}" }
    site = Tinrelay::TinrelaydConfig::Site.new(
      "TinRelay", "https://tinrelay.space", "Tin Relay"
    )
    registration = Tinrelay::TinrelaydConfig::Registration.from_json({
      exclude: names,
    }.to_json)
    config = Tinrelay::TinrelaydConfig.new(site, registration)
    config.rate_limit_exclusions.should eq(names)

    registration = Tinrelay::TinrelaydConfig::Registration.from_json({
      exclude: names + ["ship-256"],
    }.to_json)
    config = Tinrelay::TinrelaydConfig.new(site, registration)
    expect_raises(Tinrelay::Invalid, /too many/) do
      config.rate_limit_exclusions
    end
  end

  it "publishes one complete valid snapshot and retains it after invalid reloads" do
    root = TinrelaySpec.temporary_root
    path = File.join(root, "tinrelayd.json")
    TinrelayRuntimePolicySpec.write_site_only(path)
    api = Tinrelay::API.new(TinrelayRuntimePolicySpec.server_config(root, path))
    begin
      prior = api.runtime_snapshot
      TinrelayRuntimePolicySpec.write_complete(path)
      api.reload_configuration
      current = api.runtime_snapshot
      current.same?(prior).should be_false
      current.page.public_url("/").should eq("https://second.example/")
      allowances = current.registration_allowances
      {allowances.global_hour, allowances.global_day}.should eq({301, 1001})
      {allowances.per_source_hour, allowances.per_source_day}.should eq({5, 6})
      current.registration_deny_cidrs.size.should eq(2)
      policy = current.client_address_policy
      policy.mode.should eq(Tinrelay::ClientAddressMode::TrustedProxy)
      policy.trusted_ingress_cidrs.size.should eq(1)

      File.write(path, {
        site: {
          site_name: "Rejected Site", base_url: "https://rejected.example",
          wordmark: "Rejected Mark", art_manifest_path: nil,
        },
        client_address: {
          mode: "trusted_proxy", trusted_ingress_cidrs: [] of String,
        },
      }.to_json)
      expect_raises(Tinrelay::Invalid) { api.reload_configuration }
      api.runtime_snapshot.same?(current).should be_true

      File.delete(path)
      expect_raises(Tinrelay::Invalid) { api.reload_configuration }
      api.runtime_snapshot.same?(current).should be_true
    ensure
      api.close
      FileUtils.rm_r(root)
    end
  end

  it "publishes only canonical unique exclusions for already claimed ships" do
    root = TinrelaySpec.temporary_root
    path = File.join(root, "tinrelayd.json")
    TinrelayRuntimePolicySpec.write_site_only(path)
    api = Tinrelay::API.new(TinrelayRuntimePolicySpec.server_config(root, path))
    begin
      TinrelayRuntimePolicySpec.claim(api, "alpha")
      TinrelayRuntimePolicySpec.write_complete(path, ["alpha"])
      api.reload_configuration
      included = api.runtime_snapshot
      included.rate_limit_excluded?("alpha").should be_true
      included.rate_limit_excluded?("beta").should be_false

      [["alpha", "alpha"], ["Alpha"], ["unknown"]].each do |exclude|
        TinrelayRuntimePolicySpec.write_complete(path, exclude)
        expect_raises(Tinrelay::Invalid) { api.reload_configuration }
        api.runtime_snapshot.same?(included).should be_true
      end

      TinrelayRuntimePolicySpec.write_complete(path)
      api.reload_configuration
      api.runtime_snapshot.rate_limit_excluded?("alpha").should be_false
      included.rate_limit_excluded?("alpha").should be_true
    ensure
      api.close
      FileUtils.rm_r(root)
    end
  end

  it "resolves direct peers canonically and ignores the client header" do
    policy = Tinrelay::ClientAddressPolicy.new("direct", [] of String)
    headers = HTTP::Headers.new
    headers.add(Tinrelay::ClientAddressPolicy::HEADER, "203.0.113.1")
    headers.add(Tinrelay::ClientAddressPolicy::HEADER, "not-an-address")
    peer = Socket::IPAddress.new("::ffff:192.0.2.10", 4321)
    policy.resolve(peer, headers).address.should eq("192.0.2.10")

    expect_raises(Tinrelay::Invalid) { policy.resolve(nil, headers) }
    unix = Socket::UNIXAddress.new("/tmp/tinrelay-policy-spec")
    expect_raises(Tinrelay::Invalid) { policy.resolve(unix, headers) }
  end

  it "trusts exactly one literal client address only from a configured ingress" do
    policy = Tinrelay::ClientAddressPolicy.new(
      "trusted_proxy", ["192.0.2.0/24", "2001:db8::/32"]
    )
    headers = HTTP::Headers{
      Tinrelay::ClientAddressPolicy::HEADER => "2001:0db8:0:0::5",
    }
    mapped_peer = Socket::IPAddress.new("::ffff:192.0.2.8", 4321)
    policy.resolve(mapped_peer, headers).address.should eq("2001:db8::5")

    untrusted = Socket::IPAddress.new("198.51.100.8", 4321)
    expect_raises(Tinrelay::Invalid) { policy.resolve(untrusted, headers) }
    expect_raises(Tinrelay::Invalid) { policy.resolve(mapped_peer, HTTP::Headers.new) }

    duplicate = HTTP::Headers.new
    duplicate.add(Tinrelay::ClientAddressPolicy::HEADER, "192.0.2.9")
    duplicate.add(Tinrelay::ClientAddressPolicy::HEADER, "192.0.2.10")
    expect_raises(Tinrelay::Invalid) { policy.resolve(mapped_peer, duplicate) }

    ["192.0.2.9, 192.0.2.10", "client.example"].each do |value|
      bad = HTTP::Headers{Tinrelay::ClientAddressPolicy::HEADER => value}
      expect_raises(Tinrelay::Invalid) { policy.resolve(mapped_peer, bad) }
    end

    expect_raises(Tinrelay::Invalid) do
      Tinrelay::ClientAddressPolicy.new("trusted_proxy", [] of String)
    end
    expect_raises(Tinrelay::Invalid) do
      Tinrelay::ClientAddressPolicy.new("trusted_proxy", ["192.0.2.0/33"])
    end
  end
end
