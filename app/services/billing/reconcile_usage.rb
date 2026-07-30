module Billing
  # Repairs the usage meters from the database, and warns anyone getting close.
  #
  # WHY THE METER NEEDS REPAIRING AT ALL. Enforcement counts events in Redis
  # because it cannot afford a SQL aggregate per pageview (see
  # Billing::UsageMeter). Redis is the right store for that and the wrong store to
  # trust: a restart, an eviction, or a deploy mid-increment loses counts, and
  # every count lost is quota given away. So the number that gets enforced is
  # reconciled hourly against events_by_hour, which is the same aggregate the
  # dashboard reads and is therefore the same definition of "an event" the
  # customer sees.
  #
  # UPWARD ONLY. UsageMeter#repair never lowers a counter, for the reason set out
  # there: the meter counts events received and the aggregate counts events
  # stored, so the meter being higher is the truth rather than drift.
  #
  # ONE QUERY FOR THE WHOLE INSTANCE. Per-account queries would be an hourly job
  # whose cost grows linearly with customers; a single grouped scan of one month of
  # events_by_hour is a handful of milliseconds because the aggregate has already
  # collapsed millions of events into hours.
  class ReconcileUsage < ApplicationService
    Report = Struct.new(:accounts_checked, :accounts_repaired, :accounts_notified, :accounts_failed,
                        keyword_init: true)

    def initialize(at: Time.current, notify: true)
      @at = at
      @notify = notify
    end

    def call
      # Nothing to meter and nothing to sell. Returning success rather than a
      # failure because "there is no billing here" is the correct outcome for a
      # self-hosted install — or an unconfigured one — not an error to report every
      # hour.
      return Success(empty_report) unless Tastatur.billing_enabled?

      period_start, period_end = UsageMeter.period_bounds(@at)
      recorded = recorded_events_by_account(period_start, period_end)

      repaired = 0
      notified = 0
      failed = 0

      # Only accounts with traffic this month. An account with no events cannot be
      # near its limit and has nothing to repair, so scanning every account row
      # hourly would be work with no possible outcome.
      Account.where(id: recorded.keys).includes(:sites).find_each do |account|
        # ONE ACCOUNT MUST NOT ABORT THE SWEEP. Everything in this block can raise —
        # Redis on the meter, the queue on the warning email — and an exception used
        # to propagate out of find_each, so a single bad account left every account
        # after it in the batch unrepaired and unwarned for that hour, silently and
        # in the same order every time. Reported to Sentry rather than swallowed.
        begin
          before = UsageMeter.used(account.id, at: @at)
          after = UsageMeter.repair(account.id, recorded: recorded.fetch(account.id, 0), at: @at)
          repaired += 1 if after > before

          # A repair must not spend a grandfathered allowance.
          #
          # Billing::SyncSubscription sizes a downgrade's grant from the meter:
          # "what you have used, plus the new plan's allowance". If the meter was
          # behind at that moment — Redis had been flushed, or billing was switched
          # off for part of the month and nothing was counting — the grant is sized
          # against a number that is too small, and then THIS repair raises the meter
          # to the true stored total while the ceiling stays where it was. The
          # customer is instantly over a limit they were just promised the whole of.
          #
          # So the ceiling moves with the counter, by the same amount. Only for a
          # grant with an expiry: one without is a deliberate support decision and is
          # not a reconciliation's to change.
          carry_grandfathering(account, after - before) if after > before

          # The cached limit in this process may predate a plan change; drop it so
          # the account is measured against what it is on now.
          EventQuota.forget(account.id)

          notified += 1 if @notify && notify_thresholds(account)
        rescue StandardError => e
          failed += 1
          Sentry.capture_exception(e) if defined?(Sentry)
          Rails.logger.error("[tastatur] usage reconciliation failed for account #{account.id}: #{e.class}: #{e.message}")
        end
      end

      Rails.logger.info(
        "[tastatur] usage: checked #{recorded.size} accounts, repaired #{repaired}, " \
        "notified #{notified}, failed #{failed}"
      )

      Success(Report.new(accounts_checked: recorded.size, accounts_repaired: repaired,
                         accounts_notified: notified, accounts_failed: failed))
    end

    private

    def empty_report
      Report.new(accounts_checked: 0, accounts_repaired: 0, accounts_notified: 0, accounts_failed: 0)
    end

    # Keeps a downgrade's month-long grant worth what it was worth when it was made.
    def carry_grandfathering(account, shortfall)
      return if shortfall <= 0
      return if account.event_limit_override.nil?
      return if account.event_limit_override_until.nil?
      return if account.event_limit_override_until.past?

      account.update!(event_limit_override: account.event_limit_override + shortfall)

      Rails.logger.info(
        "[tastatur] carried account #{account.id}'s grandfathered allowance up by #{shortfall} " \
        "to #{account.event_limit_override}, following a meter repair"
      )
    end

    def notify_thresholds(account)
      NotifyUsageThreshold.call(account: account, at: @at).success?
    end

    # account_id => events stored this month.
    #
    # pageviews + custom_events is every row in the events table: the two FILTER
    # clauses in events_by_hour partition on `event_name = 'pageview'` and its
    # negation, so their sum is COUNT(*) with no third case. spec/services/billing/
    # reconcile_usage_spec.rb asserts that against raw rows so the identity cannot
    # quietly stop holding if a third event class is ever added.
    #
    # Reads the aggregate rather than the hypertable because it is orders of
    # magnitude smaller and, having timescaledb.materialized_only = false, still
    # includes events that arrived seconds ago.
    def recorded_events_by_account(period_start, period_end)
      rows = ActiveRecord::Base.connection.select_all(
        ActiveRecord::Base.sanitize_sql_array(
          [<<~SQL.squish, period_start, period_end]
            SELECT sites.account_id AS account_id,
                   COALESCE(SUM(events_by_hour.pageviews + events_by_hour.custom_events), 0)::bigint AS events
            FROM events_by_hour
            JOIN sites ON sites.id = events_by_hour.site_id
            WHERE events_by_hour.bucket >= ? AND events_by_hour.bucket < ?
            GROUP BY sites.account_id
          SQL
        ),
        "Billing::ReconcileUsage"
      )

      rows.to_a.to_h { |row| [row["account_id"], row["events"].to_i] }
    end
  end
end
