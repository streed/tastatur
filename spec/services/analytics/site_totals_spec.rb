require "rails_helper"

# The numbers on the sites index: one query, every site on the page, all time.
#
# NO `:continuous_aggregate` TAG. All three aggregates are created with
# `timescaledb.materialized_only = false`, so a read of events_by_hour unions the
# materialized rows with anything newer straight from the hypertable — including
# rows inserted a moment ago inside this example's own uncommitted transaction.
# Same reasoning as spec/services/billing/reconcile_usage_spec.rb.
#
# `clear_materialized_aggregates!` IS needed, and only because these totals are
# all-time. Every other report is bounded by a period and simply never asks for
# the buckets a `:continuous_aggregate` spec left behind for a since-recycled site
# id; this one has no window to exclude them with. See spec/support/test_database.rb.
RSpec.describe Analytics::SiteTotals do
  # An override rather than Pro: what this file needs is room for a second site,
  # not a paying customer. See Site#account_within_site_limit.
  let(:account) { create(:account, site_limit_override: 5) }
  let(:site) { create(:site, account: account, domain: "one.example.com") }
  let(:other) { create(:site, account: account, domain: "two.example.com") }

  before do
    delete_all_events
    Tastatur::TestDatabase.clear_materialized_aggregates!
  end

  def totals_for(*sites)
    described_class.call(sites: sites).value!
  end

  describe "what it counts" do
    before do
      create_event(site, path: "/", visitor: "a", at: 3.hours.ago, is_entry: true)
      create_event(site, path: "/pricing", visitor: "a", at: 3.hours.ago + 1.minute)
      create_event(site, event_name: "Signup", path: "/pricing", visitor: "a", at: 3.hours.ago + 2.minutes)
    end

    it "separates pageviews from custom events" do
      totals = totals_for(site).for_site(site)

      expect(totals.pageviews).to eq(2)
      expect(totals.custom_events).to eq(1)
    end

    # SUM(entries) rather than a distinct count of session_hash, because a
    # distinct count is exact only within a bucket and this query spans every
    # bucket a site has. An entry event happens once per session, so summing it
    # is exact across any number of them.
    it "counts a visit once, from the event that opened the session" do
      expect(totals_for(site).for_site(site).visits).to eq(1)
    end
  end

  # THE OTHER HALF OF THE VIEW, and the one an all-time total actually rests on.
  #
  # Every example above reads its events through real-time aggregation, which
  # covers only what is newer than the refresh watermark. A year-old pageview is
  # not there — it is a materialized row — and a query that read only the live
  # union would report a plausible, recent-looking number for a total that claims
  # to be lifetime. So this one materializes, which means no transaction.
  describe "events old enough to have been materialized", :continuous_aggregate do
    # Well past every refresh policy's start_offset, so nothing but the explicit
    # refresh below puts these in the aggregate.
    let(:long_ago) { 200.days.ago }

    before do
      create_event(site, path: "/", visitor: "old", at: long_ago, is_entry: true)
      create_event(site, event_name: "Signup", visitor: "old", at: long_ago + 1.minute)
      Tastatur::TestDatabase.refresh_aggregate!("events_by_hour")
    end

    # This example is not transactional, so its materialized rows would otherwise
    # outlive it and land on whichever site id the sequence hands out next — the
    # exact hazard the outer `clear_materialized_aggregates!` exists for. Emptying
    # the raw table and re-refreshing the same window recomputes those buckets to
    # nothing, which is what Analytics::ReconcileAggregates does in production.
    after do
      delete_all_events
      Tastatur::TestDatabase.refresh_aggregate!(
        "events_by_hour", from: long_ago - 2.days, to: long_ago + 2.days
      )
    end

    it "counts them, because the total is all time" do
      totals = totals_for(site).for_site(site)

      expect(totals.pageviews).to eq(1)
      expect(totals.custom_events).to eq(1)
      expect(totals.visits).to eq(1)
    end
  end

  describe "across a list of sites" do
    before do
      create_event(site, path: "/", visitor: "a", at: 2.hours.ago, is_entry: true)
      create_event(site, path: "/", visitor: "b", at: 2.hours.ago, is_entry: true)
      create_event(other, path: "/", visitor: "c", at: 2.hours.ago, is_entry: true)
      create_event(other, event_name: "Signup", visitor: "c", at: 2.hours.ago)
    end

    it "keeps each site's traffic on its own row" do
      result = totals_for(site, other)

      expect(result.for_site(site).pageviews).to eq(2)
      expect(result.for_site(other).pageviews).to eq(1)
      expect(result.for_site(other).custom_events).to eq(1)
    end

    it "adds the sites up" do
      total = totals_for(site, other).total

      expect(total.pageviews).to eq(3)
      expect(total.custom_events).to eq(1)
      expect(total.visits).to eq(3)
    end

    # The caller decides which sites are in scope — on the index that is
    # `policy_scope(Site)` — so a site left out of the list contributes nothing,
    # not even to the total.
    it "ignores a site it was not given" do
      result = totals_for(site)

      expect(result.total.pageviews).to eq(2)
      expect(result.by_site_id).not_to have_key(other.id)
    end
  end

  # A site with no events has no buckets at all, so there is no row to read. The
  # index still has to draw it, which means zero has to be a value rather than a
  # nil the view guards against.
  it "reports zero for a site that has never received an event" do
    totals = totals_for(site).for_site(site)

    expect(totals.pageviews).to be_zero
    expect(totals.custom_events).to be_zero
    expect(totals.visits).to be_zero
  end

  it "answers an empty list without going to the database" do
    expect(ActiveRecord::Base.connection).not_to receive(:select_all)

    expect(described_class.call(sites: []).value!.total.pageviews).to be_zero
  end
end
