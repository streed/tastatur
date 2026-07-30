module Privacy
  # Deletes events older than each account's retention window.
  #
  # There are two retention mechanisms and they are complementary, not
  # redundant:
  #
  #   1. TimescaleDB's own retention policy on the events hypertable, set in the
  #      migration. It DROPS whole chunks, which is fast and physically reclaims
  #      the storage — but it can only apply one global window, because a chunk
  #      holds rows for every site at once.
  #
  #   2. This job, which enforces the per-account window. Retention is a
  #      compliance control a controller may be obliged to set tighter than our
  #      default, so it has to be per-account, which means a DELETE rather than
  #      a chunk drop.
  #
  # A DELETE leaves dead tuples for autovacuum rather than reclaiming space
  # immediately. That is the unavoidable cost of per-tenant retention; the
  # global chunk-drop policy is what keeps total storage bounded.
  class EnforceDataRetention < ApplicationService
    Report = Struct.new(:accounts_processed, :events_deleted, keyword_init: true)

    def initialize(account: nil)
      @accounts = account ? [account] : Account.all
    end

    def call
      deleted = 0
      processed = 0
      newest_cutoff = nil

      @accounts.each do |account|
        site_ids = account.sites.pluck(:id)
        next if site_ids.empty?

        cutoff = account.data_retention_days.days.ago
        removed = delete_events(site_ids, cutoff)
        next if removed.zero?

        deleted += removed
        processed += 1
        # The latest cutoff across all accounts bounds the window that needs
        # reconciling; everything deleted is older than it.
        newest_cutoff = cutoff if newest_cutoff.nil? || cutoff > newest_cutoff
      end

      # Deleting raw rows does not remove them from the continuous aggregates,
      # and the scheduled refresh policies only look back 3 to 10 days, so an
      # invalidation this old is never processed. Without this the aggregates
      # keep reporting data that retention has already deleted, permanently,
      # which means retention is not actually being enforced for anything a
      # report reads. See Analytics::ReconcileAggregates.
      if newest_cutoff
        ReconcileAggregatesJob.perform_later(oldest_event_at || newest_cutoff - 1.day, newest_cutoff)
      end

      Rails.logger.info("[tastatur] retention: deleted #{deleted} events across #{processed} accounts")
      Success(Report.new(accounts_processed: processed, events_deleted: deleted))
    end

    private

    # The earliest event still present bounds how far back the aggregates could
    # hold stale rows. Cheap: it is an index-ordered lookup on the hypertable.
    def oldest_event_at
      ActiveRecord::Base.connection.select_value("SELECT MIN(occurred_at) FROM events")
    end

    def delete_events(site_ids, cutoff)
      result = ActiveRecord::Base.connection.exec_delete(
        ActiveRecord::Base.sanitize_sql_array(
          ["DELETE FROM events WHERE site_id IN (?) AND occurred_at < ?", site_ids, cutoff]
        ),
        "EnforceDataRetention"
      )
      result.to_i
    end
  end
end
