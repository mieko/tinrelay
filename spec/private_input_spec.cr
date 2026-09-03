require "./spec_helper"
require "../src/tinrelay/private_input"

describe Tinrelay::PrivateInput do
  it "accepts owner-only files and protected stdin without retaining line endings" do
    root = TinrelaySpec.temporary_root
    path = File.join(root, "passphrase")
    File.write(path, "private-secret\n", perm: 0o600)

    Tinrelay::PrivateInput.read(path, "passphrase").should eq("private-secret")
    Tinrelay::PrivateInput.read("-", "passphrase", IO::Memory.new("stdin-secret\n"))
      .should eq("stdin-secret")
  ensure
    FileUtils.rm_r(root) if root && Dir.exists?(root)
  end

  it "rejects files readable outside the owner" do
    root = TinrelaySpec.temporary_root
    path = File.join(root, "passphrase")
    File.write(path, "exposed", perm: 0o644)

    expect_raises(Tinrelay::Invalid, /must not be accessible/) do
      Tinrelay::PrivateInput.read(path, "passphrase")
    end
  ensure
    FileUtils.rm_r(root) if root && Dir.exists?(root)
  end

  it "reopens a claimed ship noninteractively from its inferred passphrase file" do
    root = TinrelaySpec.temporary_root
    home = File.join(root, "home")
    paths = Tinrelay::LocalPaths.new("harbor", home)
    Dir.mkdir_p(File.dirname(paths.passphrase))
    File.write(paths.passphrase, "protected ship passphrase\n", perm: 0o600)

    TinrelaySpec.with_server do |_server_root, origin, _api|
      phrase = Tinrelay::PrivateInput.read(paths.passphrase, "passphrase")
      client = Tinrelay::Client.join(
        paths.keyring, origin, "harbor", phrase, paths.owner_key
      )
      client.send("test@harbor", "radio restart proof")

      reopened_phrase = Tinrelay::PrivateInput.read(paths.passphrase, "passphrase")
      restarted = Tinrelay::Client.new(
        Tinrelay::Keyring.load(
          paths.keyring, reopened_phrase, paths.owner_key
        ),
        reopened_phrase
      )
      event = restarted.radio_wait(Tinrelay::Spool.new(paths.spool), hold_seconds: 0)
      event.kind.should eq("transmission")
      event.name.should eq("test")
    end
  ensure
    FileUtils.rm_r(root) if root && Dir.exists?(root)
  end
end
