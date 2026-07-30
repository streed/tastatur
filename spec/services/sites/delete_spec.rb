require "rails_helper"

# Erasure has to be complete, because the UI and docs/privacy/data-requests.md
# both promise it is. These examples exist because it was not: deleting a site
# removed every raw event and left 100% of the rows in all three continuous
# aggregates, including visitor_days, which holds visitor hashes.
#
# Tagged :continuous_aggregate because asserting on materialized data means
# calling refresh_continuous_aggregate, which TimescaleDB refuses to run inside a
# transaction.
RSpec.describe Sites::Delete, :continuous_aggregate do
  let(:account) { create(:account) }
  let(:site) { create(:site, account: account, domain: "erased.example.com") }
  let(:survivor) { create(:site, account: account, domain: "kept.example.com") }

  def refresh_aggregates!
    %w[events_by_hour visitor_days session_days].each do |view|
      Tastatur::TestDatabase.refresh_aggregate!(view)
    end
  end

  def aggregate_counts(site_id)
    %w[events_by_hour visitor_days session_days].to_h do |view|
      [view, ActiveRecord::Base.connection.select_value(
        ActiveRecord::Base.sanitize_sql_array(["SELECT COUNT(*) FROM #{view} WHERE site_id = ?", site_id])
      ).to_i]
    end
  end

  before do
    delete_all_events
    # Backdated well past every refresh policy's start_offset (3 and 10 days), so
    # the scheduled refresh would never reconcile these on its own.
    20.times { |i| create_event(site, visitor: "gone-#{i}", at: 200.days.ago + i.hours) }
    10.times { |i| create_event(survivor, visitor: "stay-#{i}", at: 200.days.ago + i.hours) }
    refresh_aggregates!
  end

  it "materializes into the aggregates first, so the test is meaningful" do
    expect(aggregate_counts(site.id).values).to all(be_positive)
  end

  it "removes every raw event for the site" do
    described_class.call(site: site)
    expect(Event.where(site_id: site.id).count).to eq(0)
  end

  it "removes the site" do
    id = site.id
    described_class.call(site: site)
    expect(Site.find_by(id: id)).to be_nil
  end

  describe "the aggregates" do
    it "enqueues reconciliation with the site's actual event window" do
      expect { described_class.call(site: site) }
        .to have_enqueued_job(ReconcileAggregatesJob)
    end

    # THE REGRESSION. Raw deletion alone leaves the aggregate rows in place, and
    # because the refresh policies only look back a few days, they stay there
    # forever.
    it "leaves no aggregate rows once reconciliation has run" do
      described_class.call(site: site)
      perform_enqueued_jobs(only: ReconcileAggregatesJob)

      expect(aggregate_counts(site.id)).to eq(
        "events_by_hour" => 0, "visitor_days" => 0, "session_days" => 0
      )
    end

    it "removes the visitor-grain rows specifically, since those hold hashes" do
      described_class.call(site: site)
      perform_enqueued_jobs(only: ReconcileAggregatesJob)

      remaining = ActiveRecord::Base.connection.select_value(
        ActiveRecord::Base.sanitize_sql_array(
          ["SELECT COUNT(*) FROM visitor_days WHERE site_id = ?", site.id]
        )
      ).to_i
      expect(remaining).to eq(0)
    end

    it "does not disturb another site's aggregate rows" do
      before_counts = aggregate_counts(survivor.id)

      described_class.call(site: site)
      perform_enqueued_jobs(only: ReconcileAggregatesJob)

      expect(aggregate_counts(survivor.id)).to eq(before_counts)
    end

    it "does not disturb another site's raw events" do
      expect { described_class.call(site: site) }
        .not_to change { Event.where(site_id: survivor.id).count }
    end
  end

  it "does not enqueue reconciliation for a site that never received data" do
    empty = create(:site, account: account, domain: "never-used.example.com")
    expect { described_class.call(site: empty) }.not_to have_enqueued_job(ReconcileAggregatesJob)
  end

  it "clears the ingest token cache so collection stops at once" do
    token = site.public_token
    Rails.cache.write("site/token/#{token}", site)

    described_class.call(site: site)
    expect(Rails.cache.read("site/token/#{token}")).to be_nil
  end
end
