require "./spec_helper"

describe "local radio status" do
  it "reads one pending or routed record without scanning or mutating the spool" do
    root = TinrelaySpec.temporary_root
    spool_root = File.join(root, "inbox")
    spool = Tinrelay::Spool.new(spool_root)
    record = Tinrelay::RejectedTransmissionSpoolRecord.new(
      local_id: "tr_0123456789abcdef0123456789abcdef",
      received_at: 10_i64,
      relay_transmission_id: "11111111-1111-4111-8111-111111111111",
      rejection_reason: "unusable_envelope"
    )
    Tinrelay::AtomicPrivateFile.write(
      File.join(spool.pending, "#{record.local_id}.json"),
      record.to_pretty_json + "\n"
    )
    File.write(File.join(spool.history, "tr_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.json"), "corrupt")
    File.chmod(spool_root, 0o750)

    reader = Tinrelay::Spool.open_existing(spool_root)
    reader.status(record.local_id).should eq({
      state: "pending", local_id: record.local_id,
      kind: "rejected_transmission", routed_at: nil,
    })
    (File.info(spool_root).permissions.value & 0o777).should eq(0o750)

    Tinrelay::AtomicPrivateFile.write(
      File.join(spool_root, "routed", record.local_id), "20\n"
    )
    reader.status(record.local_id).should eq({
      state: "routed", local_id: record.local_id,
      kind: "rejected_transmission", routed_at: 20_i64,
    })
    File.file?(File.join(spool.pending, "#{record.local_id}.json")).should be_true
  ensure
    FileUtils.rm_r(root) if root && Dir.exists?(root)
  end

  it "does not create a missing spool and reports missing or corrupt records" do
    root = TinrelaySpec.temporary_root
    missing = File.join(root, "missing")
    reader = Tinrelay::Spool.open_existing(missing)

    expect_raises(Tinrelay::NotFound, "inbox record not found") do
      reader.status("tr_0123456789abcdef0123456789abcdef")
    end
    Dir.exists?(missing).should be_false

    spool = Tinrelay::Spool.new(File.join(root, "inbox"))
    corrupt_id = "tr_bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
    File.write(File.join(spool.pending, "#{corrupt_id}.json"), "not json")
    expect_raises(Tinrelay::Error, "inbox record is corrupt: #{corrupt_id}.json") do
      Tinrelay::Spool.open_existing(spool.root).status(corrupt_id)
    end
  ensure
    FileUtils.rm_r(root) if root && Dir.exists?(root)
  end

  it "rejects an embedded ID mismatch before consulting that ID's routed marker" do
    root = TinrelaySpec.temporary_root
    spool = Tinrelay::Spool.new(File.join(root, "inbox"))
    requested_id = "tr_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    embedded_id = "tr_bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
    record = Tinrelay::RejectedTransmissionSpoolRecord.new(
      local_id: embedded_id,
      received_at: 10_i64,
      relay_transmission_id: "11111111-1111-4111-8111-111111111111",
      rejection_reason: "unusable_envelope"
    )
    record_path = File.join(spool.pending, "#{requested_id}.json")
    marker_path = File.join(spool.root, "routed", embedded_id)
    Tinrelay::AtomicPrivateFile.write(record_path, record.to_pretty_json + "\n")
    Tinrelay::AtomicPrivateFile.write(marker_path, "20\n")
    record_bytes = File.read(record_path)
    marker_bytes = File.read(marker_path)

    expect_raises(Tinrelay::Error, "inbox record id does not match requested id") do
      Tinrelay::Spool.open_existing(spool.root).status(requested_id)
    end
    File.read(record_path).should eq(record_bytes)
    File.read(marker_path).should eq(marker_bytes)
  ensure
    FileUtils.rm_r(root) if root && Dir.exists?(root)
  end

  it "reports a normally routed history record" do
    root = TinrelaySpec.temporary_root
    spool = Tinrelay::Spool.new(File.join(root, "inbox"))
    record = Tinrelay::RejectedTransmissionSpoolRecord.new(
      local_id: "tr_cccccccccccccccccccccccccccccccc",
      received_at: 10_i64,
      relay_transmission_id: "11111111-1111-4111-8111-111111111111",
      rejection_reason: "unusable_envelope"
    )
    Tinrelay::AtomicPrivateFile.write(
      File.join(spool.pending, "#{record.local_id}.json"),
      record.to_pretty_json + "\n"
    )

    spool.routed(record.local_id, 30_i64)

    File.file?(File.join(spool.history, "#{record.local_id}.json")).should be_true
    Tinrelay::Spool.open_existing(spool.root).status(record.local_id).should eq({
      state: "routed", local_id: record.local_id,
      kind: "rejected_transmission", routed_at: 30_i64,
    })
  ensure
    FileUtils.rm_r(root) if root && Dir.exists?(root)
  end
end
