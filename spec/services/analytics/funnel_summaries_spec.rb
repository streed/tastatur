require "rails_helper"

RSpec.describe Analytics::FunnelSummaries do
  let(:site) { create(:site, :no_suppression) }
  let(:period) { Analytics::Period.parse("30d", site: site) }

  let!(:signup) do
    create(:funnel, site: site, name: "Signup", steps: [
             { name: "Landed", match_value: "/" },
             { name: "Priced", match_value: "/pricing" }
           ])
  end

  let!(:checkout) do
    create(:funnel, site: site, name: "Checkout", steps: [
             { name: "Cart", match_value: "/cart" },
             { name: "Paid", match_value: "/thanks" }
           ])
  end

  before { delete_all_events }

  def summaries(funnels = site.funnels.ordered)
    described_class.call(funnels: funnels, period: period).value!
  end

  describe "reporting each funnel" do
    it "returns one row per funnel, in the order it was given them" do
      expect(summaries.map { |row| row.funnel.name }).to eq(%w[Checkout Signup])
    end

    it "carries the conversion the funnel's own page would show" do
      create_event(site, visitor: "v1", path: "/",        at: 3.hours.ago)
      create_event(site, visitor: "v1", path: "/pricing", at: 3.hours.ago + 1.minute)
      create_event(site, visitor: "v2", path: "/",        at: 2.hours.ago)

      row = summaries.find { |r| r.funnel == signup }

      expect(row).to be_reportable
      expect(row.report.entered).to eq(2)
      expect(row.report.completed).to eq(1)
      expect(row.report.overall_rate).to eq(50.0)
    end

    it "reports a funnel nobody entered as zero rather than omitting it" do
      row = summaries.find { |r| r.funnel == checkout }

      expect(row).to be_reportable
      expect(row.report.entered).to be_zero
      expect(row.report.overall_rate).to eq(0.0)
    end
  end

  # Both of these are forbidden by Funnel and FunnelStep, so they only arise
  # from a row written around the model — a migration, a console, a
  # `delete_all`. The index still has to render, with the broken funnel LISTED:
  # dropping it would hide the one thing the reader has to open to fix.
  describe "a funnel that cannot be reported on" do
    it "keeps the row and leaves the report empty when a step has no matcher" do
      signup.funnel_steps.first.conditions.delete_all

      row = summaries.find { |r| r.funnel == signup }

      expect(row).not_to be_reportable
      expect(row.report).to be_nil
    end

    it "keeps the row when the funnel is down to one step" do
      signup.funnel_steps.last.destroy

      row = summaries.find { |r| r.funnel == signup }

      expect(row).not_to be_reportable
      expect(summaries.map { |r| r.funnel.name }).to eq(%w[Checkout Signup])
    end

    it "still reports the funnels either side of it" do
      signup.funnel_steps.first.conditions.delete_all
      create_event(site, visitor: "v1", path: "/cart",   at: 2.hours.ago)
      create_event(site, visitor: "v1", path: "/thanks", at: 2.hours.ago + 1.minute)

      expect(summaries.find { |r| r.funnel == checkout }.report.overall_rate).to eq(100.0)
    end
  end

  it "returns Success even when there are no funnels at all" do
    expect(described_class.call(funnels: [], period: period)).to be_success
  end
end
