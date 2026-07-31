module Revenue
  # Computes `attribution_rollups` for one site over a range of its LOCAL days.
  #
  # THE ONLY WRITER OF THAT TABLE. It recomputes a day from scratch and upserts,
  # so re-running is always safe and always converges — which is what lets the
  # nightly job re-do yesterday after the day has fully closed, and lets a
  # backfill re-do two years without anybody reasoning about overlap.
  #
  # WHY THIS IS FOUR QUERIES AND NOT ONE. Visitors live in a TimescaleDB
  # hypertable; signups, conversions and money live in ordinary PostgreSQL tables.
  # A single statement joining them would put a hypertable scan on the inside of a
  # nested loop over customers, which is the shape that turns a 200ms report into
  # a 40-second one on the first site with real traffic. Four indexed aggregate
  # queries, merged in Ruby over a few hundred channel keys, is both faster and
  # legible.
  #
  # DAYS ARE THE SITE'S LOCAL DAYS. Every other screen in this product reports in
  # `site.timezone` — §13 explains why the salt rotates on the same boundary — and
  # a revenue table that disagreed with the traffic table about where Tuesday ends
  # would make the two halves of the flagship screen not add up.
  class RollupAttribution < ApplicationService
    def initialize(site:, from:, to: from)
      @site = site
      @from = from.to_date
      @to = to.to_date
    end

    def call
      rows = (@from..@to).flat_map { |date| rows_for(date) }
      return Success(0) if rows.empty?

      # ONE UPSERT FOR THE WHOLE RANGE. `update_only` names every value column
      # (AttributionRollup::VALUE_COLUMNS) so a re-run REPLACES a day rather than
      # ignoring it — an `ON CONFLICT DO NOTHING` here would make the nightly
      # re-run of yesterday a no-op, leaving a day computed while events were
      # still arriving permanently half-counted.
      AttributionRollup.upsert_all(
        rows,
        unique_by: :idx_attr_rollups_unique,
        update_only: AttributionRollup::VALUE_COLUMNS,
        record_timestamps: true
      )

      Success(rows.length)
    end

    private

    def rows_for(date)
      range = day_range(date)

      traffic = visitors_by_channel(range)
      funnel = funnel_by_channel(range)
      money = money_by_channel(range)
      lifetime = lifetime_by_channel

      keys = traffic.keys | funnel.keys | money.keys
      keys.map { |key| row(date, key, traffic, funnel, money, lifetime) }
    end

    def row(date, key, traffic, funnel, money, lifetime)
      source, medium, campaign = key
      counts = funnel[key] || {}
      cash = money[key] || {}

      {
        site_id: @site.id, date: date, source: source, medium: medium, campaign: campaign,
        visitors: traffic[key] || 0,
        signups: counts[:signups] || 0,
        trials: counts[:trials] || 0,
        conversions: counts[:conversions] || 0,
        new_mrr_cents: cash[RevenueEvent::NEW] || 0,
        expansion_mrr_cents: cash[RevenueEvent::EXPANSION] || 0,
        contraction_mrr_cents: cash[RevenueEvent::CONTRACTION] || 0,
        # STORED POSITIVE, though the ledger holds it negative.
        #
        # `churned_mrr_cents` is read as "how much did we lose", and a column
        # holding -4000 under a heading that says "Churned MRR" gets rendered as
        # "-$40 churned" — which reads as a gain. The sign lives in the ledger,
        # where it belongs for arithmetic; the report column is a magnitude.
        churned_mrr_cents: (cash[RevenueEvent::CHURN] || 0).abs,
        net_mrr_cents: RevenueEvent::MRR_KINDS.sum { |kind| cash[kind] || 0 },
        lifetime_revenue_cents: lifetime[key] || 0,
        unconverted_events: cash[:unconverted] || 0
      }
    end

    # --- Traffic --------------------------------------------------------------

    # Distinct visitors per channel, from the raw hypertable.
    #
    # RAW EVENTS, NOT AN AGGREGATE, and that is not an oversight — it is the rule
    # §12 states for every breakdown in this product. The continuous aggregates
    # carry no dimension columns on purpose, because a wide one would be roughly
    # one row per event. A channel is a dimension, so this scans.
    #
    # COUNT(DISTINCT) is exact here, across chunk boundaries and across
    # incremental refresh — verified against this TimescaleDB version, and the
    # reason we need neither timescaledb_toolkit nor hyperloglog. Note that the
    # result must not be summed across days by any caller; the report reads one
    # day's row or re-queries a range. §8 has the long version.
    def visitors_by_channel(range)
      sql = <<~SQL.squish
        SELECT #{Channel.events_source_sql}   AS source,
               #{Channel.events_medium_sql}   AS medium,
               #{Channel.events_campaign_sql} AS campaign,
               COUNT(DISTINCT visitor_hash)   AS visitors
        FROM events
        WHERE site_id = $1 AND occurred_at >= $2 AND occurred_at < $3
        GROUP BY 1, 2, 3
      SQL

      execute(sql, range).to_h { |r| [key_of(r), r["visitors"].to_i] }
    end

    # --- The funnel -----------------------------------------------------------

    # Signups, trials and conversions, counted against the day they HAPPENED.
    #
    # THE THREE DATES ARE DIFFERENT COLUMNS ON PURPOSE. A customer who signed up
    # on the 3rd and paid on the 17th is one signup on the 3rd and one conversion
    # on the 17th — not one of each on either day. Counting conversions against
    # the signup date is the commonest error here and it makes every paid campaign
    # look like it converts instantly, which flatters exactly the campaigns that
    # do not.
    def funnel_by_channel(range)
      sql = <<~SQL.squish
        SELECT COALESCE(NULLIF(c.attribution_source, ''),   $4) AS source,
               COALESCE(NULLIF(c.attribution_medium, ''),   $5) AS medium,
               COALESCE(NULLIF(c.attribution_campaign, ''), $5) AS campaign,
               COUNT(*) FILTER (WHERE c.identified_at >= $2 AND c.identified_at < $3) AS signups,
               COUNT(*) FILTER (WHERE c.converted_at  >= $2 AND c.converted_at  < $3) AS conversions,
               COUNT(DISTINCT s.id) FILTER (
                 WHERE s.status = 'trialing' AND s.created_at >= $2 AND s.created_at < $3
               ) AS trials
        FROM customers c
        LEFT JOIN customer_subscriptions s ON s.customer_id = c.id
        WHERE c.site_id = $1
          AND (
            (c.identified_at >= $2 AND c.identified_at < $3) OR
            (c.converted_at  >= $2 AND c.converted_at  < $3) OR
            (s.created_at    >= $2 AND s.created_at    < $3)
          )
        GROUP BY 1, 2, 3
      SQL

      binds = [@site.id, range.first, range.last, Channel::DIRECT, Channel::NONE]

      execute_with(sql, binds).to_h do |r|
        [key_of(r), { signups: r["signups"].to_i, trials: r["trials"].to_i, conversions: r["conversions"].to_i }]
      end
    end

    # --- Money ----------------------------------------------------------------

    # MRR movement per channel per day, plus a count of what could not be
    # converted into the site's base currency.
    #
    # `normalized_cents` is summed, NOT `amount_cents` — the whole point of the
    # column is that a report adds up one currency. Rows that could not be
    # converted contribute nothing to the total and are counted separately, so the
    # screen can say how much it is not showing rather than quietly under-reporting.
    def money_by_channel(range)
      sql = <<~SQL.squish
        SELECT COALESCE(NULLIF(c.attribution_source, ''),   $4) AS source,
               COALESCE(NULLIF(c.attribution_medium, ''),   $5) AS medium,
               COALESCE(NULLIF(c.attribution_campaign, ''), $5) AS campaign,
               r.kind                                            AS kind,
               COALESCE(SUM(r.normalized_cents), 0)              AS total,
               COUNT(*) FILTER (WHERE r.normalized_cents IS NULL) AS unconverted
        FROM revenue_events r
        JOIN customers c ON c.id = r.customer_id
        WHERE r.site_id = $1 AND r.occurred_at >= $2 AND r.occurred_at < $3
        GROUP BY 1, 2, 3, 4
      SQL

      binds = [@site.id, range.first, range.last, Channel::DIRECT, Channel::NONE]

      execute_with(sql, binds).each_with_object({}) do |r, out|
        bucket = out[key_of(r)] ||= Hash.new(0)
        bucket[r["kind"]] = r["total"].to_i
        bucket[:unconverted] += r["unconverted"].to_i
      end
    end

    # Lifetime revenue per channel, as of now.
    #
    # NOT SCOPED TO THE DAY, and that is the whole subtlety of this column.
    # Lifetime value is a property of a customer, not of a date — so it is
    # recomputed in full on every rollup and written onto each day's row as a
    # snapshot. The report reads it from the most recent row only and never sums
    # it across days, for exactly the reason §8 forbids summing a distinct count
    # across buckets: the same customer appears in every day's snapshot.
    def lifetime_by_channel
      sql = <<~SQL.squish
        SELECT COALESCE(NULLIF(attribution_source, ''),   $2) AS source,
               COALESCE(NULLIF(attribution_medium, ''),   $3) AS medium,
               COALESCE(NULLIF(attribution_campaign, ''), $3) AS campaign,
               COALESCE(SUM(lifetime_revenue_cents), 0)       AS total
        FROM customers
        WHERE site_id = $1
        GROUP BY 1, 2, 3
      SQL

      binds = [@site.id, Channel::DIRECT, Channel::NONE]
      execute_with(sql, binds).to_h { |r| [key_of(r), r["total"].to_i] }
    end

    # --- Plumbing -------------------------------------------------------------

    # The UTC instants bounding one of the site's local days. Half-open, so an
    # event at exactly midnight belongs to the day starting then and not to both.
    def day_range(date)
      zone = ActiveSupport::TimeZone[@site.timezone] || ActiveSupport::TimeZone["Etc/UTC"]
      start = zone.parse(date.to_s).beginning_of_day

      [start.utc, (start + 1.day).utc]
    end

    def key_of(row)
      [row["source"], row["medium"], row["campaign"]]
    end

    def execute(sql, range)
      execute_with(sql, [@site.id, range.first, range.last])
    end

    # Bound parameters throughout rather than interpolation. The channel sentinels
    # are constants and the site id is an integer, so nothing here is user input —
    # but this query is one edit away from taking a filter, and a habit of
    # interpolating is what makes that edit dangerous.
    def execute_with(sql, binds)
      ActiveRecord::Base.connection.exec_query(sql, "RollupAttribution", binds)
    end
  end
end
