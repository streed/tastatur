module Analytics
  # Re-materializes the continuous aggregates over a time window, so that rows
  # deleted from the raw hypertable stop appearing in reports.
  #
  # WHY THIS IS NECESSARY, because it is not obvious and the failure is silent:
  #
  # Deleting from the raw hypertable does NOT remove the corresponding rows from
  # a continuous aggregate. TimescaleDB records an invalidation and reconciles it
  # on the next scheduled refresh — but each refresh policy only looks back
  # `start_offset` (3 days for events_by_hour, 10 for the others). An
  # invalidation older than that window is never processed, so the aggregate
  # keeps reporting data that no longer exists, permanently.
  #
  # Two callers delete historical rows and therefore must call this:
  #
  #   Sites::Delete            — "delete this site and all of its data"
  #   Privacy::EnforceDataRetention — the nightly per-account retention sweep
  #
  # Before this existed, deleting a site left 100% of its rows in all three
  # aggregates, including visitor_days, which holds visitor hashes. The UI and
  # docs promised erasure was immediate and complete; it was neither.
  #
  # Deleting straight from the aggregate is not an option: with real-time
  # aggregation enabled the view is a UNION, and PostgreSQL refuses
  # (`cannot delete from view ... not automatically updatable`). Re-refreshing
  # the window is the supported mechanism, and once the raw rows are gone the
  # refresh removes the materialized ones.
  class ReconcileAggregates < ApplicationService
    AGGREGATES = %w[events_by_hour visitor_days session_days].freeze

    # Refreshing is global across sites: the aggregates are not partitioned by
    # tenant, so recomputing a window recomputes every site's buckets in it.
    # That makes a needlessly wide window expensive, which is why callers pass
    # the actual range they deleted rather than (NULL, NULL).
    def initialize(from:, to:, aggregates: AGGREGATES)
      @from = from
      @to = to
      @aggregates = aggregates
    end

    def call
      return Failure(:empty_window) if @from.nil? || @to.nil? || @from >= @to

      # A bucket is only recomputed if the refresh window fully contains it, so
      # the range is widened to the coarsest bucket boundary (one day) on both
      # sides. Without this, deleting rows in the middle of a day would leave
      # that day's bucket untouched.
      from = @from.beginning_of_day - 1.day
      to = @to.beginning_of_day + 2.days

      refreshed = @aggregates.select { |view| refresh(view, from, to) }

      Rails.logger.info(
        "[tastatur] reconciled #{refreshed.join(', ')} over #{from.to_date}..#{to.to_date}"
      )
      Success(refreshed)
    end

    private

    def refresh(view, from, to)
      # refresh_continuous_aggregate cannot run inside a transaction, so this
      # must never be called from within one. The job that calls it does not open
      # one, and Sites::Delete deliberately calls it after its transaction
      # commits.
      ActiveRecord::Base.connection.execute(
        ActiveRecord::Base.sanitize_sql_array(
          ["CALL refresh_continuous_aggregate(?::regclass, ?, ?)", view, from, to]
        )
      )
      true
    rescue ActiveRecord::StatementInvalid => e
      # A concurrent refresh from the scheduled policy is expected under load and
      # is harmless: the policy is doing the same work. Anything else is a real
      # problem and should reach Sentry.
      raise unless e.message.include?("concurrent refresh")

      Rails.logger.info("[tastatur] #{view} refresh skipped, policy is already refreshing it")
      false
    end
  end
end
