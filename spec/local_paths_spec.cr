require "./spec_helper"

describe Tinrelay::LocalPaths do
  it "derives every private path from one validated ship selector" do
    paths = Tinrelay::LocalPaths.new("harbor", "/home/caller")

    paths.keyring.should eq("/home/caller/.config/tinrelay/harbor/keyring")
    paths.owner_key.should eq("/home/caller/.config/tinrelay/harbor/owner-key")
    paths.passphrase.should eq("/home/caller/.config/tinrelay/harbor/passphrase")
    paths.spool.should eq("/home/caller/.local/share/tinrelay/harbor/inbox")
    paths.outbox.should eq("/home/caller/.local/share/tinrelay/harbor/outbox")
  end

  it "rejects a ship name before using it as a path component" do
    expect_raises(Tinrelay::Invalid, "invalid ship name") do
      Tinrelay::LocalPaths.new("../harbor", "/home/caller")
    end
  end
end
