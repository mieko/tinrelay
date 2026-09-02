require "./spec_helper"

describe Tinrelay::ServerRuntime do
  it "uses detected processors by default and bounds an explicit thread count" do
    Tinrelay::ServerRuntime.thread_count(nil).should eq(System.cpu_count)
    Tinrelay::ServerRuntime.thread_count("1").should eq(1)
    expect_raises(Tinrelay::Invalid, /between 1/) do
      Tinrelay::ServerRuntime.thread_count("0")
    end
    expect_raises(Tinrelay::Invalid, /between 1/) do
      Tinrelay::ServerRuntime.thread_count((System.cpu_count + 1).to_s)
    end
  end
end

describe Tinrelay::SubmissionWindow do
  it "bounds direct attempts without a per-transmission relay write" do
    window = Tinrelay::SubmissionWindow.new
    now = 1_000_000_i64
    Tinrelay::Store::MAX_TRANSMISSIONS_PER_HOUR.times do
      window.allow?("alpha", now).should be_true
    end
    window.allow?("alpha", now).should be_false
    window.allow?("alpha", now + 3601).should be_true
  end
end
