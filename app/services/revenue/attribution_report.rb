module Revenue
  # Reads `attribution_rollups` for a period and returns the table the flagship
  # screen renders.
  #
  # SORTED BY MONEY, NOT BY TRAFFIC, and that single default is the product. Every
  # other analytics tool sorts this table by visitors, which reliably puts the
  # channel that sends the most people at the top — and the channel that sends the
  # most people is very often the one that sends the fewest customers. Sorting by
  # revenue is what makes the screenshot worth looking at.
  #
  # READS ONLY ROLLUPS, never `events` or `revenue_events` directly. That
  # constraint is what keeps this screen fast enough to leave open, and it is the
  # same rule the traffic dashboards follow.
  class AttributionReport < ApplicationService
    SORTS = {
      "revenue" => :net_mrr_cents,
      "lifetime" => :lifetime_revenue_cents,
      "visitors" => :visitors,
      "conversions" => :conversions
    }.freeze

    DEFAULT_SORT = "revenue".freeze

    def initialize(site:, period:, sort: DEFAULT_SORT, limit: 100)
      @site = site
      @period = period
      @sort = SORTS.key?(sort.to_s) ? sort.to_s : DEFAULT_SORT
      @limit = limit
    end

    def call
      rows = build_rows
      Success(
        rows: rows.first(@limit),
        totals: totals(rows),
        sort: @sort,
        truncated: rows.length > @limit,
        stale_since: stale_since
      )
    end

    private

    def scope
      @site.attribution_rollups.where(date: @period.from.to_date...@period.to.to_date)
    end

    # SUMS ACROSS DAYS FOR EVERY COLUMN EXCEPT LIFETIME REVENUE, which is a
    # snapshot and is taken from the LATEST day only.
    #
    # This is the same trap §8 documents for distinct counts and it is worth
    # restating, because the code that gets it wrong looks completely reasonable.
    # `lifetime_revenue_cents` is "everything this channel has ever produced, as
    # of the night this row was written" — so it appears, in full, on every single
    # day's row. Summing it over 30 days multiplies a channel's lifetime value by
    # thirty. The report would show a business thirty times larger than it is, and
    # the number would look plausible.
    def build_rows
      grouped = scope.group_by { |rollup| [rollup.source, rollup.medium, rollup.campaign] }
      latest = latest_lifetime_by_channel

      rows = grouped.map do |key, rollups|
        ChannelRow.new(
          source: key[0], medium: key[1], campaign: key[2],
          visitors: rollups.sum(&:visitors),
          signups: rollups.sum(&:signups),
          trials: rollups.sum(&:trials),
          conversions: rollups.sum(&:conversions),
          new_mrr_cents: rollups.sum(&:new_mrr_cents),
          expansion_mrr_cents: rollups.sum(&:expansion_mrr_cents),
          contraction_mrr_cents: rollups.sum(&:contraction_mrr_cents),
          churned_mrr_cents: rollups.sum(&:churned_mrr_cents),
          net_mrr_cents: rollups.sum(&:net_mrr_cents),
          lifetime_revenue_cents: latest[key] || 0,
          unconverted_events: rollups.sum(&:unconverted_events)
        )
      end

      sort(rows)
    end

    # The most recent snapshot per channel within the period.
    #
    # `DISTINCT ON` rather than a `MAX` subquery: it is one index scan on
    # (site_id, date) and it returns the whole row, so adding another snapshot
    # column later needs no second query.
    def latest_lifetime_by_channel
      sql = <<~SQL.squish
        SELECT DISTINCT ON (source, medium, campaign)
               source, medium, campaign, lifetime_revenue_cents
        FROM attribution_rollups
        WHERE site_id = $1 AND date >= $2 AND date < $3
        ORDER BY source, medium, campaign, date DESC
      SQL

      binds = [@site.id, @period.from.to_date, @period.to.to_date]

      ActiveRecord::Base.connection
                        .exec_query(sql, "AttributionReport lifetime", binds)
                        .to_h { |r| [[r["source"], r["medium"], r["campaign"]], r["lifetime_revenue_cents"].to_i] }
    end

    # Descending, with a stable tiebreak on the channel name.
    #
    # Without the tiebreak, two channels with identical revenue — which is
    # overwhelmingly common, because the commonest revenue figure is zero — swap
    # places between page loads as PostgreSQL's row order changes. That reads as
    # data changing under the reader.
    def sort(rows)
      column = SORTS[@sort]
      rows.sort_by { |row| [-row.public_send(column), row.channel_label] }
    end

    def totals(rows)
      {
        visitors: rows.sum(&:visitors),
        signups: rows.sum(&:signups),
        trials: rows.sum(&:trials),
        conversions: rows.sum(&:conversions),
        net_mrr_cents: rows.sum(&:net_mrr_cents),
        new_mrr_cents: rows.sum(&:new_mrr_cents),
        churned_mrr_cents: rows.sum(&:churned_mrr_cents),
        lifetime_revenue_cents: rows.sum(&:lifetime_revenue_cents),
        unconverted_events: rows.sum(&:unconverted_events)
      }
    end

    # WHEN THIS REPORT WAS LAST COMPUTED, so the screen can say so.
    #
    # A precomputed table that silently stops updating looks exactly like a
    # business that stopped growing, and that is the failure mode a nightly job
    # has. Surfacing the age of the newest row means a stalled rollup shows up as
    # "last updated 3 days ago" on the screen rather than as a flat line somebody
    # tries to explain.
    def stale_since
      @site.attribution_rollups.maximum(:updated_at)
    end
  end
end
