require "./spec_helper"

class Tinrelay::SubmissionWindow
  def retained_ship_count_for_spec : Int32
    @mutex.synchronize { @attempts.size }
  end
end

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
    window.allow?("alpha", now + 3600).should be_true
  end

  it "removes an inactive identity exactly when its final attempt expires" do
    window = Tinrelay::SubmissionWindow.new(1, 10_i64)
    window.allow?("expired", 0_i64).should be_true

    window.allow?("trigger", 10_i64).should be_true

    window.retained_ship_count_for_spec.should eq(1)
  end

  it "expires inactive identities without resetting active transmission or hail quotas" do
    configurations = [
      {Tinrelay::Store::MAX_TRANSMISSIONS_PER_HOUR, 3600_i64},
      {Tinrelay::Store::MAX_HAILS_PER_DAY, 24_i64 * 60 * 60},
    ]

    configurations.each do |limit, period|
      window = Tinrelay::SubmissionWindow.new(limit, period)
      1_000.times do |index|
        window.allow?("expired-#{index}", 0_i64).should be_true
      end
      window.allow?("active", period).should be_true

      window.allow?("trigger", period + 1).should be_true

      window.retained_ship_count_for_spec.should eq(2)
      (limit - 1).times do
        window.allow?("active", period + 1).should be_true
      end
      window.allow?("active", period + 1).should be_false
    end
  end
end
