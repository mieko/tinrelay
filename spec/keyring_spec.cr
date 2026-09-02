require "./spec_helper"

describe Tinrelay::Keyring do
  it "writes only encrypted private material with restrictive permissions" do
    root = TinrelaySpec.temporary_root
    path = File.join(root, "keys", "keyring")
    passphrase = "test passphrase is long"
    keyring = Tinrelay::Keyring.create(path, "http://localhost:8787", "alpha", passphrase)
    contents = File.read(path)
    contents.should_not contain(keyring.data.radio!.signing.secret_key)
    owner = keyring.owner(passphrase)
    contents.should_not contain(owner.key.secret_key)
    File.read(keyring.owner_path).should_not contain(owner.key.secret_key)
    (File.info(path).permissions.value & 0o777).should eq(0o600)
    (File.info(keyring.owner_path).permissions.value & 0o777).should eq(0o600)
    loaded = Tinrelay::Keyring.load(path, passphrase)
    loaded.data.ship.should eq("alpha")
    loaded.owner(passphrase).generation.should eq(1)
  ensure
    FileUtils.rm_r(root) if root && Dir.exists?(root)
  end

  it "prunes expired invitation secrets while preserving live ones" do
    root = TinrelaySpec.temporary_root
    path = File.join(root, "keys", "keyring")
    passphrase = "invitation pruning passphrase"
    now = Time.utc.to_unix
    keyring = Tinrelay::Keyring.create(path, "http://localhost:8787", "alpha", passphrase)
    keyring.remember_invitation_secret(Tinrelay::Ids.uuid, "expired", now)
    live_id = Tinrelay::Ids.uuid
    keyring.remember_invitation_secret(live_id, "live", now + 60)
    keyring.save(passphrase)

    Tinrelay::Client.new(keyring, passphrase, Tinrelay::Remote.new("http://localhost:8787"))
    reloaded = Tinrelay::Keyring.load(path, passphrase)
    reloaded.data.invitation_secrets.map(&.invitation_id).should eq([live_id])
  ensure
    FileUtils.rm_r(root) if root && Dir.exists?(root)
  end

  it "rejects every encrypted-file KDF profile except the fixed Argon2id13 profile" do
    root = TinrelaySpec.temporary_root
    path = File.join(root, "keys", "keyring")
    passphrase = "fixed kdf profile passphrase"
    keyring = Tinrelay::Keyring.create(path, "http://localhost:8787", "alpha", passphrase)

    keyring_envelope = JSON.parse(File.read(path))
    keyring_envelope["kdf"].as_s.should eq(Tinrelay::Crypto::KDF_PROFILE)
    keyring_envelope.as_h["kdf"] = JSON::Any.new("argon2id-opslimit4-mem64m")
    File.write(path, keyring_envelope.to_pretty_json)
    expect_raises(Tinrelay::Invalid, "unsupported keyring KDF profile") do
      Tinrelay::Keyring.load(path, passphrase)
    end

    owner_envelope = JSON.parse(File.read(keyring.owner_path))
    owner_envelope.as_h["kdf"] = JSON::Any.new("scrypt")
    File.write(keyring.owner_path, owner_envelope.to_pretty_json)
    expect_raises(Tinrelay::Invalid, "unsupported owner key KDF profile") do
      keyring.owner(passphrase)
    end
  ensure
    FileUtils.rm_r(root) if root && Dir.exists?(root)
  end
end
