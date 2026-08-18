module Analytics
  # What every tagged link that reached this site did, keyed by the five UTM
  # values together.
  #
  # NOT Analytics::Breakdown with `utm_campaign` as its dimension, and the
  # difference is the whole reason this exists. That panel answers "which
  # campaign", one column at a time; a campaign LINK is a five-value tuple, and
  # the question the Campaigns screen asks is "what did the thing I built do".
  # Grouping by utm_campaign alone would add the email, the tweet and the banner
  # into one row and give all three the same figure — which is the number you
  # already have on the dashboard, and not the one you came here for.
  #
  # Reads the raw hypertable, like every other dimensional report here and for
  # the same reason: the continuous aggregates carry no dimension columns.
  class CampaignReport < ApplicationService
    Row = Struct.new(:utm_source, :utm_medium, :utm_campaign, :utm_term, :utm_content,
                     :visitors, :visits, :pageviews, keyword_init: true) do
      # The join key, in the order CampaignLink#utm_key builds it. Both sides
      # normalise blank to nil, because a link with no term has to match rows
      # whose utm_term column is NULL and "" is not NULL.
      def key = [utm_source, utm_medium, utm_campaign, utm_term, utm_content].map(&:presence)

      def campaign = utm_campaign.presence || "(none)"
    end

    Result = Struct.new(:rows, :suppressed_rows, :suppressed_visitors, :threshold, :truncated,
                        keyword_init: true) do
      def any? = rows.any?
      def suppressed? = suppressed_rows.positive?
      def truncated? = truncated

      # Rows by tuple, for matching saved links against what actually arrived.
      def by_key = @by_key ||= rows.index_by(&:key)

      def for_link(link) = by_key[link.utm_key]
    end

    # High enough that no real site's saved links fall off the end, bounded
    # because utm_term carries paid-search keywords and a large advertiser's
    # tuple space is genuinely unbounded. #truncated? says when it bit rather
    # than letting the screen imply this is all of them.
    LIMIT = 500

    def initialize(site:, period:, limit: LIMIT)
      @site = site
      @period = period
      @limit = limit
      @scope = Scope.new(site: site, period: period)
    end

    def call
      rows = fetch
      kept, withheld = Suppression.partition(rows.first(@limit), threshold: @scope.k_threshold)

      Success(
        Result.new(
          rows: kept.map { |row| to_row(row) },
          suppressed_rows: withheld.size,
          suppressed_visitors: withheld.sum { |row| row["visitors"].to_i },
          threshold: @scope.k_threshold,
          truncated: rows.size > @limit
        )
      )
    end

    private

    def fetch
      where, binds = @scope.raw_conditions

      # Only events that carry a tag at all. Without this the largest row by a
      # wide margin is (NULL, NULL, NULL, NULL, NULL) — all the site's untagged
      # traffic, which is every other report on the product and nothing to do
      # with a campaign.
      where += " AND (#{CampaignLink::PARAMS.map { |p| "#{p} IS NOT NULL" }.join(' OR ')})"

      # COUNT(DISTINCT) on both grains, exact per the notes in
      # create_analytics_aggregates. Neither figure may be added across rows —
      # one visitor can arrive on two links — which is why nothing on this
      # screen totals a column.
      @scope.select_all(<<~SQL, binds)
        SELECT utm_source, utm_medium, utm_campaign, utm_term, utm_content,
               COUNT(DISTINCT visitor_hash) AS visitors,
               COUNT(DISTINCT session_hash) AS visits,
               #{@scope.volume_expression} AS pageviews
        FROM events
        WHERE #{where}
        GROUP BY 1, 2, 3, 4, 5
        ORDER BY visitors DESC, pageviews DESC, utm_campaign ASC
      SQL
    end

    def to_row(row)
      Row.new(
        utm_source: row["utm_source"], utm_medium: row["utm_medium"],
        utm_campaign: row["utm_campaign"], utm_term: row["utm_term"],
        utm_content: row["utm_content"],
        visitors: row["visitors"].to_i, visits: row["visits"].to_i,
        pageviews: row["pageviews"].to_i
      )
    end
  end
end
