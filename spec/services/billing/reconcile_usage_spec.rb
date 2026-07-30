require "rails_helper"

# NO `:continuous_aggregate` TAG, and that is worth recording because it is not
# obvious: all three aggregates are created with `timescaledb.materialized_only =
# false`, so a query against events_by_hour unions the materialized rows with
# anything newer straight from the hypertable — including rows this example inserted
# a moment ago inside its own uncommitted transaction. Only a spec that needs
# refresh_continuous_aggregate (which TimescaleDB refuses inside a transaction) has
# to drop the transactional fixture; see spec/services/sites/delete_spec.rb.
#
# Every window here stays inside the current calendar month. The test database can
# carry materialized rows for low site ids left behind by a truncating spec, and a
# wider window would quietly pick them up.
RSpec.describe Billing::ReconcileUsage do
  let(:account) { create(:account, plan: "free") }
  let(:site) { create(:site, account: account) }

  before do
    delete_all_events
    Billing::EventQuota.clear!
  end

  # THE IDENTITY THE WHOLE SERVICE RESTS ON.
  #
  # events_by_hour's two counters FILTER on `event_name = 'pageview'` and on its
  # negation, so their sum is COUNT(*) with no third case — which is what makes
  # "pageviews + custom_events" a safe definition of "events recorded". If a future
  # migration ever makes event_name nullable, a row would fall through both filters
  # and this example is what notices.
  it "defines a recorded event the same way the events table does" do
    create_event(site, path: "/", at: 2.hours.ago)
    create_event(site, path: "/pricing", at: 90.minutes.ago)
    create_event(site, event_name: "Signup", at: 1.hour.ago)

    from, to = Billing::UsageMeter.period_bounds
    aggregate = ActiveRecord::Base.connection.select_value(
      ActiveRecord::Base.sanitize_sql_array(
        ["SELECT COALESCE(SUM(pageviews + custom_events), 0)::bigint FROM events_by_hour " \
         "WHERE site_id = ? AND bucket >= ? AND bucket < ?", site.id, from, to]
      )
    )

    expect(aggregate).to eq(3)
    expect(Event.where(site_id: site.id).count).to eq(3)
  end

  describe "repairing the meter" do
    before { 5.times { |i| create_event(site, visitor: "v#{i}", at: (i + 1).hours.ago) } }

    # The failure this exists for: Redis is restarted, or a deploy drops increments,
    # and the counter that enforcement reads is now below what was actually stored.
    # Every count lost is quota given away, and nothing raises.
    it "brings a counter that has fallen behind up to what was stored" do
      expect { described_class.call(notify: false) }
        .to change { Billing::UsageMeter.used(account.id) }.from(0).to(5)
    end

    # The counter counts events received, the aggregate counts events stored, so the
    # counter being higher is the truth rather than drift. Lowering it would reset an
    # account parked at its limit every hour and let another hour through, forever.
    it "leaves a counter that is ahead of the database alone" do
      Billing::UsageMeter.record(account.id, count: 40)

      expect { described_class.call(notify: false) }
        .not_to change { Billing::UsageMeter.used(account.id) }
    end

    it "reports what it touched" do
      report = described_class.call(notify: false).value!

      expect(report.accounts_checked).to eq(1)
      expect(report.accounts_repaired).to eq(1)
    end
  end

  # An account with no traffic cannot be near its limit and has nothing to repair,
  # so scanning every account row hourly would be work with no possible outcome.
  it "does not visit accounts with no traffic this month" do
    quiet = create(:account)
    create(:site, account: quiet)

    report = described_class.call(notify: false).value!

    expect(report.accounts_checked).to eq(0)
    expect(Billing::UsageMeter.used(quiet.id)).to eq(0)
  end

  it "attributes events to the owning account across all of its sites" do
    account.update!(site_limit_override: 5)
    second = create(:site, account: account, domain: "second.example.com")
    create_event(site, at: 1.hour.ago)
    create_event(second, at: 1.hour.ago)
    create_event(second, at: 30.minutes.ago)

    described_class.call(notify: false)

    expect(Billing::UsageMeter.used(account.id)).to eq(3)
  end

  it "warns the account when it asked to" do
    account.update!(event_limit_override: 4)
    create(:membership, account: account, user: create(:user), role: "owner")
    5.times { |i| create_event(site, visitor: "v#{i}", at: (i + 1).hours.ago) }

    expect { described_class.call }
      .to have_enqueued_mail(BillingMailer, :usage_threshold)

    expect(described_class.call(notify: true).value!.accounts_notified).to eq(0),
           "the notice is claimed once per level per month"
  end

  it "does not send anything when told not to" do
    account.update!(event_limit_override: 4)
    create(:membership, account: account, user: create(:user), role: "owner")
    5.times { |i| create_event(site, visitor: "v#{i}", at: (i + 1).hours.ago) }

    expect { described_class.call(notify: false) }.not_to have_enqueued_mail(BillingMailer, :usage_threshold)
  end

  describe "on a self-hosted install" do
    before { allow(Tastatur).to receive(:self_hosted?).and_return(true) }

    it "does nothing at all, because there is nothing to meter" do
      create_event(site, at: 1.hour.ago)

      report = described_class.call.value!

      expect(report.accounts_checked).to eq(0)
      expect(Billing::UsageMeter.used(account.id)).to eq(0)
    end
  end
end
