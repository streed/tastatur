require "rails_helper"

RSpec.describe Billing::UsageSnapshot do
  def snapshot(**overrides)
    described_class.new(
      {
        plan: Billing::Plan.free,
        events_used: 0,
        event_limit: 100_000,
        events_used_last_month: 0,
        sites_used: 0,
        site_limit: 1,
        period_start: Time.utc(2026, 7, 1),
        period_end: Time.utc(2026, 8, 1)
      }.merge(overrides)
    )
  end

  describe "how far through the allowance" do
    it "reports the fraction and the percentage" do
      subject = snapshot(events_used: 40_000)

      expect(subject.fraction_used).to eq(0.4)
      expect(subject.percent_used).to eq(40)
      expect(subject.bar_percent).to eq(40)
    end

    # An account 18% over its allowance should read as 118%, not as a bar that has
    # stopped looking any worse. The unclamped figure is what gets printed; only the
    # bar's width is clamped.
    it "goes past 100% while the bar stops there" do
      subject = snapshot(events_used: 118_402)

      expect(subject.percent_used).to eq(118)
      expect(subject.bar_percent).to eq(100)
    end

    # A support-set override of zero means "record nothing", and the division that
    # produces a percentage has to survive it.
    it "does not divide by an allowance of zero" do
      subject = snapshot(events_used: 5, event_limit: 0)

      expect(subject.fraction_used).to eq(0.0)
      expect(subject.percent_used).to eq(0)
      expect(subject).to be_exceeded
      expect(subject.events_refused).to eq(5)
    end
  end

  describe "the thresholds" do
    it "is approaching the limit from 80% and not before" do
      expect(snapshot(events_used: 79_999)).not_to be_approaching_limit
      expect(snapshot(events_used: 80_000)).to be_approaching_limit
    end

    # Exactly at the allowance is not over it: every one of those events was
    # recorded. Billing::EventQuota refuses the next one.
    it "is not exceeded at exactly the allowance" do
      expect(snapshot(events_used: 100_000)).not_to be_exceeded
      expect(snapshot(events_used: 100_001)).to be_exceeded
    end

    # Two states, not three: an account that is over its limit is told it is over,
    # not that it is getting close.
    it "stops calling an exceeded account 'approaching'" do
      subject = snapshot(events_used: 150_000)

      expect(subject).to be_exceeded
      expect(subject).not_to be_approaching_limit
    end
  end

  describe "what was refused" do
    it "is nothing below the allowance and the difference above it" do
      expect(snapshot(events_used: 90_000).events_refused).to eq(0)
      expect(snapshot(events_used: 118_402).events_refused).to eq(18_402)
    end

    it "reports what is left, clamped at nothing" do
      expect(snapshot(events_used: 90_000).events_remaining).to eq(10_000)
      expect(snapshot(events_used: 150_000).events_remaining).to eq(0)
    end
  end

  describe "sites" do
    it "separates being at the limit from being over it" do
      at_limit = snapshot(sites_used: 1, site_limit: 1)
      over = snapshot(sites_used: 20, site_limit: 1)

      expect(at_limit).to be_at_site_limit
      expect(at_limit).not_to be_over_site_limit
      expect(over).to be_at_site_limit
      expect(over).to be_over_site_limit
      expect(over.sites_remaining).to eq(0)
    end
  end

  describe "an unlimited plan" do
    let(:subject) do
      snapshot(plan: Billing::Plan.self_hosted, events_used: 9_000_000,
               event_limit: Billing::Plan::UNLIMITED, sites_used: 40,
               site_limit: Billing::Plan::UNLIMITED)
    end

    it "is never near anything and never refuses" do
      expect(subject).to be_unlimited_events
      expect(subject).to be_unlimited_sites
      expect(subject.fraction_used).to eq(0.0)
      expect(subject).not_to be_exceeded
      expect(subject).not_to be_approaching_limit
      expect(subject.events_refused).to eq(0)
      expect(subject.events_remaining).to eq(Billing::Plan::UNLIMITED)
      expect(subject.sites_remaining).to eq(Billing::Plan::UNLIMITED)
      expect(subject).not_to be_at_site_limit
    end
  end
end
