class CreateAnalyticsAggregates < ActiveRecord::Migration[8.1]
  # CREATE MATERIALIZED VIEW ... WITH DATA cannot run inside a transaction
  # block, and neither can refresh_continuous_aggregate(). Verified against
  # TimescaleDB 2.29 — see CLAUDE.md.
  disable_ddl_transaction!

  # ---------------------------------------------------------------------------
  # Which aggregates exist, and why only these three.
  #
  # A continuous aggregate is only worth its write cost where it collapses many
  # rows into few. These three do:
  #
  #   events_by_hour  millions of events -> 24 rows per site per day
  #   visitor_days    all events         -> one row per visitor per day
  #   session_days    all events         -> one row per session per day
  #
  # A wide "every dimension" aggregate was considered and rejected: grouping by
  # visitor AND path AND referrer AND country AND device produces roughly one
  # row per event for real traffic, so it would double storage while collapsing
  # nothing. Breakdowns are therefore answered from the raw hypertable, which
  # is what exact COUNT(DISTINCT) over arbitrary filters needs anyway. See
  # docs/architecture/aggregates.md for the scaling story.
  #
  # THE RULE THAT GOVERNS ALL OF THIS: distinct counts are correct *within* a
  # bucket and must never be summed *across* buckets. `events_by_hour.visitors`
  # is the unique visitor count for that hour; adding 24 of them does not give
  # you the day's unique visitors. Any range-wide unique count comes from
  # visitor_days.
  # ---------------------------------------------------------------------------

  def up
    # -- 1. Headline metrics and the timeseries chart -------------------------
    execute <<~SQL
      CREATE MATERIALIZED VIEW events_by_hour
      WITH (timescaledb.continuous) AS
      SELECT
        time_bucket(INTERVAL '1 hour', occurred_at) AS bucket,
        site_id,
        COUNT(*) FILTER (WHERE event_name = 'pageview')  AS pageviews,
        COUNT(*) FILTER (WHERE event_name <> 'pageview') AS custom_events,
        COUNT(DISTINCT visitor_hash)                     AS visitors,
        COUNT(DISTINCT session_hash)                     AS sessions,
        COUNT(*) FILTER (WHERE is_entry)                 AS entries,
        COALESCE(SUM(revenue_cents), 0)                  AS revenue_cents
      FROM events
      GROUP BY 1, 2
      WITH NO DATA;
    SQL

    # -- 2. Exact unique visitors over an arbitrary date range ----------------
    # One row per (day, site, visitor). COUNT(DISTINCT visitor_hash) over this
    # is exact for any range, and the table is orders of magnitude smaller than
    # raw events because a visitor's whole day collapses to a single row.
    execute <<~SQL
      CREATE MATERIALIZED VIEW visitor_days
      WITH (timescaledb.continuous) AS
      SELECT
        time_bucket(INTERVAL '1 day', occurred_at) AS bucket,
        site_id,
        visitor_hash,
        COUNT(*)                                        AS events,
        COUNT(*) FILTER (WHERE event_name = 'pageview') AS pageviews,
        MIN(occurred_at)                                AS first_seen_at,
        MAX(occurred_at)                                AS last_seen_at
      FROM events
      GROUP BY 1, 2, 3
      WITH NO DATA;
    SQL

    # -- 3. Bounce rate and visit duration ------------------------------------
    # Both are session-level metrics, so they need a session-grain rollup: you
    # cannot derive "how many sessions had exactly one pageview" from any
    # event-grain aggregate.
    execute <<~SQL
      CREATE MATERIALIZED VIEW session_days
      WITH (timescaledb.continuous) AS
      SELECT
        time_bucket(INTERVAL '1 day', occurred_at) AS bucket,
        site_id,
        session_hash,
        COUNT(*) FILTER (WHERE event_name = 'pageview') AS pageviews,
        MIN(occurred_at)                                AS started_at,
        MAX(occurred_at)                                AS ended_at
      FROM events
      GROUP BY 1, 2, 3
      WITH NO DATA;
    SQL

    # -- Refresh policies -----------------------------------------------------
    # end_offset is deliberately short. Combined with real-time aggregation
    # below, the dashboard is never more than a moment stale: anything newer
    # than the materialized window is read live from the hypertable and unioned
    # in by TimescaleDB.
    #
    # start_offset bounds how far back each refresh looks for late-arriving
    # data. Events can arrive late (a beacon retried after the tab was
    # backgrounded), so it is generously wider than the ingest buffer.
    #
    # ORDER MATTERS HERE. The initial materialisation must happen BEFORE the
    # refresh policy is added. Adding the policy first schedules a background
    # refresh that starts immediately, and the migration's own
    # refresh_continuous_aggregate() then collides with it:
    #
    #   PG::LockNotAvailable: could not refresh continuous aggregate
    #   "events_by_hour" due to a concurrent refresh
    #
    # which fails the migration, and therefore fails `db:prepare` on any fresh
    # database. Materialise first, then hand the view over to the scheduler.
    {
      "events_by_hour" => { start: "3 days",  finish: "1 hour",  every: "5 minutes" },
      "visitor_days"   => { start: "10 days", finish: "1 hour",  every: "30 minutes" },
      "session_days"   => { start: "10 days", finish: "1 hour",  every: "30 minutes" }
    }.each do |view, offsets|
      # Real-time aggregation: query results union the materialized rows with
      # anything newer straight from the hypertable. Without this the dashboard
      # would visibly lag by up to end_offset, which reads as "my analytics are
      # broken" on a site that has just been set up.
      execute "ALTER MATERIALIZED VIEW #{view} SET (timescaledb.materialized_only = false);"

      say "Materializing #{view} over any existing data..."
      execute "CALL refresh_continuous_aggregate('#{view}', NULL, NULL);"

      execute <<~SQL
        SELECT add_continuous_aggregate_policy('#{view}',
          start_offset      => INTERVAL '#{offsets[:start]}',
          end_offset        => INTERVAL '#{offsets[:finish]}',
          schedule_interval => INTERVAL '#{offsets[:every]}',
          if_not_exists     => true
        );
      SQL
    end

    # Aggregates are kept far longer than raw events: they hold no visitor
    # identifiers except visitor_days, and they are what long-range charts read.
    execute <<~SQL
      SELECT add_retention_policy('events_by_hour', drop_after => INTERVAL '5 years', if_not_exists => true);
    SQL

    # visitor_days and session_days DO contain per-visitor and per-session
    # rows, so they follow the raw-event retention window rather than the
    # longer aggregate one. Keeping a visitor-grain table for five years would
    # undercut the retention promise made about the events table itself.
    %w[visitor_days session_days].each do |view|
      execute <<~SQL
        SELECT add_retention_policy('#{view}', drop_after => INTERVAL '400 days', if_not_exists => true);
      SQL
    end
  end

  def down
    %w[events_by_hour visitor_days session_days].each do |view|
      execute "DROP MATERIALIZED VIEW IF EXISTS #{view} CASCADE;"
    end
  end
end
