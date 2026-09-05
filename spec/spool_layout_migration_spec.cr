require "./spec_helper"

module TinrelaySpoolMigrationSpec
  FIXTURES = File.expand_path("fixtures/legacy_spool", __DIR__)

  def self.record(id : String, reason : String) : Tinrelay::RejectedTransmissionSpoolRecord
    Tinrelay::RejectedTransmissionSpoolRecord.new(
      local_id: id,
      received_at: 10_i64,
      relay_transmission_id: "11111111-1111-4111-8111-111111111111",
      rejection_reason: reason
    )
  end

  def self.write(path : String, record : Tinrelay::SpoolRecord) : String
    bytes = record.to_pretty_json + "\n"
    Tinrelay::AtomicPrivateFile.write(path, bytes)
    bytes
  end

  def self.copy_fixture(name : String, destination : String) : String
    bytes = File.read(File.join(FIXTURES, name))
    Tinrelay::AtomicPrivateFile.write(destination, bytes)
    bytes
  end
end

describe "local spool layout migration" do
  it "creates only pending and routed directories for a fresh spool" do
    root = TinrelaySpec.temporary_root
    spool_root = File.join(root, "inbox")

    spool = Tinrelay::Spool.new(spool_root)

    Dir.exists?(spool.pending).should be_true
    Dir.exists?(spool.routed).should be_true
    Dir.exists?(File.join(spool_root, "history")).should be_false
  ensure
    FileUtils.rm_r(root) if root && Dir.exists?(root)
  end

  it "requires an explicit migration and preserves frozen legacy bytes" do
    root = TinrelaySpec.temporary_root
    spool_root = File.join(root, "inbox")
    pending = File.join(spool_root, "pending")
    history = File.join(spool_root, "history")
    legacy_routed = File.join(spool_root, "routed")
    [pending, history, legacy_routed].each { |directory| Dir.mkdir_p(directory) }

    pending_record = TinrelaySpoolMigrationSpec.record(
      "tr_11111111111111111111111111111111", "pending"
    )
    marked_pending = TinrelaySpoolMigrationSpec.record(
      "tr_33333333333333333333333333333333", "marked_pending"
    )
    pending_bytes = TinrelaySpoolMigrationSpec.write(
      File.join(pending, "#{pending_record.local_id}.json"), pending_record
    )
    history_id = "tr_22222222222222222222222222222222"
    history_bytes = TinrelaySpoolMigrationSpec.copy_fixture(
      "rejected-transmission.json", File.join(history, "#{history_id}.json")
    )
    marked_bytes = TinrelaySpoolMigrationSpec.write(
      File.join(pending, "#{marked_pending.local_id}.json"), marked_pending
    )
    TinrelaySpoolMigrationSpec.copy_fixture(
      "routed-marker.txt", File.join(legacy_routed, history_id)
    )
    Tinrelay::AtomicPrivateFile.write(
      File.join(legacy_routed, marked_pending.local_id), "30\n"
    )

    error = expect_raises(Tinrelay::Error) { Tinrelay::Spool.new(spool_root) }
    error.message.to_s.should contain("tinrelay inbox migrate --ship \"$SHIP\"")
    expect_raises(Tinrelay::Error) { Tinrelay::Spool.open_existing(spool_root) }
    File.read(File.join(history, "#{history_id}.json")).should eq(history_bytes)

    Tinrelay::LegacySpoolMigration.run(spool_root).should be_true
    spool = Tinrelay::Spool.new(spool_root)

    File.read(File.join(spool.pending, "#{pending_record.local_id}.json"))
      .should eq(pending_bytes)
    File.read(File.join(spool.routed, "#{history_id}.json")).should eq(history_bytes)
    File.read(File.join(spool.routed, "#{marked_pending.local_id}.json"))
      .should eq(marked_bytes)
    spool.status(history_id)[:state].should eq("routed")
    spool.status(marked_pending.local_id)[:state].should eq("routed")
    spool.next_unrouted.not_nil!.local_id.should eq(pending_record.local_id)
    Dir.exists?(history).should be_false
    Dir.children(spool.routed).all?(&.ends_with?(".json")).should be_true
    Tinrelay::LegacySpoolMigration.run(spool_root).should be_false
  ensure
    FileUtils.rm_r(root) if root && Dir.exists?(root)
  end

  it "finishes an interrupted identical migration and rejects conflicting evidence" do
    root = TinrelaySpec.temporary_root
    spool_root = File.join(root, "inbox")
    history = File.join(spool_root, "history")
    routed = File.join(spool_root, "routed")
    pending = File.join(spool_root, "pending")
    [pending, history, routed].each { |directory| Dir.mkdir_p(directory) }
    id = "tr_44444444444444444444444444444444"
    record = TinrelaySpoolMigrationSpec.record(id, "same")
    bytes = TinrelaySpoolMigrationSpec.write(File.join(history, "#{id}.json"), record)
    TinrelaySpoolMigrationSpec.write(File.join(routed, "#{id}.json"), record)
    Tinrelay::AtomicPrivateFile.write(File.join(routed, id), "40\n")

    Tinrelay::LegacySpoolMigration.run(spool_root).should be_true
    File.read(File.join(routed, "#{id}.json")).should eq(bytes)
    Tinrelay::Spool.new(spool_root).status(id)[:state].should eq("routed")

    marker = File.join(routed, id)
    Tinrelay::AtomicPrivateFile.write(marker, "41\n")
    Tinrelay::LegacySpoolMigration.run(spool_root).should be_true
    File.exists?(marker).should be_false

    Dir.mkdir(history)
    conflict = TinrelaySpoolMigrationSpec.record(id, "different")
    conflict_bytes = TinrelaySpoolMigrationSpec.write(
      File.join(history, "#{id}.json"), conflict
    )
    expect_raises(Tinrelay::Conflict) do
      Tinrelay::LegacySpoolMigration.run(spool_root)
    end
    File.read(File.join(history, "#{id}.json")).should eq(conflict_bytes)
    File.read(File.join(routed, "#{id}.json")).should eq(bytes)
    Tinrelay::AtomicPrivateFile.write(marker, "42\n")
    expect_raises(Tinrelay::Conflict) do
      Tinrelay::LegacySpoolMigration.run(spool_root)
    end
    File.read(marker).should eq("42\n")
  ensure
    FileUtils.rm_r(root) if root && Dir.exists?(root)
  end

  it "fails closed on corrupt and orphan legacy markers" do
    root = TinrelaySpec.temporary_root
    spool_root = File.join(root, "inbox")
    pending = File.join(spool_root, "pending")
    routed = File.join(spool_root, "routed")
    [pending, routed].each { |directory| Dir.mkdir_p(directory) }
    corrupt_id = "tr_55555555555555555555555555555555"
    corrupt_record = TinrelaySpoolMigrationSpec.record(corrupt_id, "corrupt_marker")
    corrupt_source = File.join(pending, "#{corrupt_id}.json")
    corrupt_marker = File.join(routed, corrupt_id)
    source_bytes = TinrelaySpoolMigrationSpec.write(corrupt_source, corrupt_record)
    Tinrelay::AtomicPrivateFile.write(corrupt_marker, "not-an-int64\n")

    expect_raises(Tinrelay::Error, "legacy inbox marker is corrupt: #{corrupt_id}") do
      Tinrelay::LegacySpoolMigration.run(spool_root)
    end
    File.read(corrupt_source).should eq(source_bytes)
    File.read(corrupt_marker).should eq("not-an-int64\n")

    File.delete(corrupt_marker)
    orphan_id = "tr_66666666666666666666666666666666"
    orphan_marker = File.join(routed, orphan_id)
    Tinrelay::AtomicPrivateFile.write(orphan_marker, "60\n")
    expect_raises(
      Tinrelay::Error,
      "legacy inbox marker has no matching record: #{orphan_id}"
    ) do
      Tinrelay::LegacySpoolMigration.run(spool_root)
    end
    File.read(orphan_marker).should eq("60\n")
  ensure
    FileUtils.rm_r(root) if root && Dir.exists?(root)
  end
end
