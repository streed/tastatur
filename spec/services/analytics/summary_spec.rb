require "rails_helper"

RSpec.describe Analytics::Summary do
  let(:site) { create(:site, timezone: "Etc/UTC") }
  let(:period) { Analytics::Period.new("7d", site: site) }
  let(:base) { 2.days.ago.change(hour: 12) }

  # Bounce rate and duration are session-level, and a dimension filter has to
  # choose which SESSIONS are counted rather than which of their events are
  # visible. Applying the filter inside the rollup left every session holding only
  # its matching events, so each one looked like a single pageview with no
  # duration.
  #
  # Measured before the fix, on the fixture below: filtering to page=/pricing
  # reported a 100% bounce rate and 0s average duration, against a true 50% and
  # 150s. The error is always in the same direction — filtered bounce rate tends to
  # 100% and duration to 0 — which is what made it dangerous: it reads as a
  # plausible, alarming finding about the page rather than as a bug.
  describe "session metrics under a filter" do
    before do
      # An engaged session: /pricing plus two other pages, over five minutes.
      engaged = "engaged-session"
      create_event(site, path: "/pricing", visitor: engaged, session: engaged, at: base)
      create_event(site, path: "/features", visitor: engaged, session: engaged, at: base + 2.minutes)
      create_event(site, path: "/signup", visitor: engaged, session: engaged, at: base + 5.minutes)

      # A genuine bounce: /pricing and nothing else.
      bounced = "bounced-session"
      create_event(site, path: "/pricing", visitor: bounced, session: bounced, at: base + 1.hour)
    end

    let(:metrics) do
      described_class.call(
        site: site, period: period, filters: Analytics::Filters.new(page: "/pricing")
      ).value!
    end

    it "counts both sessions that touched the page" do
      expect(metrics.sessions).to eq(2)
    end

    it "counts only the session that genuinely bounced" do
      expect(metrics.bounce_rate).to eq(50.0)
    end

    it "measures each session over all of its events, not just the matching ones" do
      # (300s + 0s) / 2. Reading the filtered events alone gives 0.
      expect(metrics.avg_duration.round).to eq(150)
    end

    it "excludes sessions that never touched the page" do
      elsewhere = "elsewhere-session"
      create_event(site, path: "/blog", visitor: elsewhere, session: elsewhere, at: base + 2.hours)

      expect(metrics.sessions).to eq(2)
    end
  end

  # The filter still has to actually filter. A rollup that reads every event in the
  # period regardless would make these numbers identical to the unfiltered ones,
  # which is the opposite failure and just as wrong.
  describe "a filter that matches one session" do
    before do
      only = "solo-session"
      create_event(site, path: "/solo", visitor: only, session: only, at: base)
      create_event(site, path: "/solo", visitor: only, session: only, at: base + 1.minute)

      other = "other-session"
      create_event(site, path: "/other", visitor: other, session: other, at: base + 1.hour)
    end

    it "reports only the qualifying session" do
      metrics = described_class.call(
        site: site, period: period, filters: Analytics::Filters.new(page: "/solo")
      ).value!

      expect(metrics.sessions).to eq(1)
      expect(metrics.bounce_rate).to eq(0.0)
      expect(metrics.avg_duration.round).to eq(60)
    end

    it "reports nothing for a filter that matches no session" do
      metrics = described_class.call(
        site: site, period: period, filters: Analytics::Filters.new(page: "/nowhere")
      ).value!

      expect(metrics.sessions).to be_zero
      expect(metrics.bounce_rate).to eq(0.0)
    end
  end

  describe "pageviews and visitors under a filter" do
    before do
      one = "one-session"
      create_event(site, path: "/pricing", visitor: one, session: one, at: base)
      create_event(site, path: "/features", visitor: one, session: one, at: base + 1.minute)
    end

    # Event-grain metrics are the other half of the contract: those SHOULD only
    # count matching events, unlike the session-grain ones above.
    it "counts only the matching events" do
      metrics = described_class.call(
        site: site, period: period, filters: Analytics::Filters.new(page: "/pricing")
      ).value!

      expect(metrics.pageviews).to eq(1)
      expect(metrics.visitors).to eq(1)
    end
  end
end
