require "./spec_helper"
require "../src/tinrelay/private_input"

describe Tinrelay::PrivateInput do
  it "accepts owner-only files and protected stdin without retaining line endings" do
    root = TinrelaySpec.temporary_root
    path = File.join(root, "capability")
    File.write(path, "one-use-secret\n", perm: 0o600)

    Tinrelay::PrivateInput.read(path, "capability").should eq("one-use-secret")
    Tinrelay::PrivateInput.read("-", "capability", IO::Memory.new("stdin-secret\n"))
      .should eq("stdin-secret")
  ensure
    FileUtils.rm_r(root) if root && Dir.exists?(root)
  end

  it "rejects files readable outside the owner" do
    root = TinrelaySpec.temporary_root
    path = File.join(root, "capability")
    File.write(path, "exposed", perm: 0o644)

    expect_raises(Tinrelay::Invalid, /must not be accessible/) do
      Tinrelay::PrivateInput.read(path, "capability")
    end
  ensure
    FileUtils.rm_r(root) if root && Dir.exists?(root)
  end
end
