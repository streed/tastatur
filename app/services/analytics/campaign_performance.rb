module Analytics
  # What a campaign TAG did, for one site or for many, in one query.
  #
  # This is the figure that may never be assembled from a campaign's link rows.
  # `visitors` and `visits` are COUNT(DISTINCT), so adding the Discord row to
  # the Facebook row counts everybody who followed both of them twice and claims
  # an audience larger than the one that existed — §8's rule against summing
  # distinct counts, one grain down. So the campaign gets its own GROUP BY over
  # the same events, counted once, and that grouping lives here.
  #
  # ONE IMPLEMENTATION, TWO SCREENS, and that is the reason it was lifted out of
  # Analytics::CampaignReport rather than copied. The site's own campaigns screen
  # reads it for one site; the top-level list reads it for every site the viewer
  # can see. A second copy would drift on the part that matters most and drift
  # silently: which rows the k-anonymity threshold withholds. Two screens
  # disagreeing about whether a campaign exists is a worse bug than either
  # screen being wrong on its own.
  #
  # ONE QUERY FOR EVERY SITE ON THE PAGE, not one per site — the same rule
  # Analytics::SiteTotals follows, and it matters more here: this reads the raw
  # hypertable (the continuous aggregates carry no dimension columns, §8), so a
  # loop would be twenty scans that each look cheap.
  #
  # EACH SITE BRINGS ITS OWN WINDOW. Periods are resolved per site by the
  # caller, because a preset resolves against ONE site's timezone; the WHERE
  # clause is those windows OR'd together, so a row is always measured in the
  # window its own site reports in. Nothing is summed across sites anywhere in
  # here, and there is deliberately no total on the Result to tempt anyone.
  class CampaignPerformance < ApplicationService
    Row = Struct.new(:site_id, :utm_campaign, :visitors, :visits, :pageviews, keyword_init: true)

    Result = Struct.new(:rows, :withheld_by_site_id, keyword_init: true) do
      def by_key = @by_key ||= rows.index_by { |row| [row.site_id, row.utm_campaign] }

      # nil when the campaign has no traffic AND when its traffic was withheld
      # for falling under the site's threshold — the two are deliberately
      # indistinguishable to the caller. Naming the second would publish
      # "somebody came, fewer than k of them" for a campaign that can be sent to
      # one person.
      def for_campaign(campaign) = by_key[[campaign.site_id, campaign.utm_campaign]]

      # For one site: the rows in the order the query returned them, busiest
      # first. The top-level list does not use this — it has campaigns to hang
      # figures off, not rows to render.
      def for_site(site) = rows.select { |row| row.site_id == site.id }

      def withheld_for(site) = withheld_by_site_id.fetch(site.id, 0)

      def withheld? = withheld_by_site_id.values.sum.positive?
    end

    # periods: { site => Analytics::Period }. A Hash rather than two arrays so a
    # site can never be paired with the wrong window by an off-by-one.
    def initialize(periods:)
      @periods = periods
    end

    def call
      return Success(Result.new(rows: [], withheld_by_site_id: {})) if @periods.empty?

      kept = []
      withheld_counts = {}

      grouped = fetch.group_by { |row| row["site_id"] }

      @periods.each_key do |site|
        # Partitioned PER SITE, on that site's own threshold — it is a per-site
        # setting, and a shared partition would apply one site's rule to
        # another's visitors. Suppression.partition is the one place the rule
        # (including complementary suppression) is written down.
        site_rows = grouped.fetch(site.id, [])
        keep, drop = Suppression.partition(site_rows, threshold: scope_for(site).k_threshold)

        kept.concat(keep.map { |row| to_row(row) })
        withheld_counts[site.id] = drop.size
      end

      Success(Result.new(rows: kept, withheld_by_site_id: withheld_counts))
    end

    private

    def fetch
      windows = @periods.keys.map { |site| scope_for(site).raw_conditions }

      # Every site's window OR'd together, each parenthesised. Left unbracketed
      # the `AND utm_campaign IS NOT NULL` below would bind to the last window
      # only, and every other site's untagged traffic would arrive as one
      # enormous NULL row.
      where = windows.map { |sql, _| "(#{sql})" }.join(" OR ")
      binds = windows.flat_map { |_, values| values }

      # Untagged events are every other report on this product and nothing to do
      # with a campaign. Without this the largest row by a wide margin is the
      # NULL one.
      sql = <<~SQL
        SELECT site_id, utm_campaign,
               COUNT(DISTINCT visitor_hash) AS visitors,
               COUNT(DISTINCT session_hash) AS visits,
               #{volume_expression} AS pageviews
        FROM events
        WHERE (#{where}) AND utm_campaign IS NOT NULL
        GROUP BY 1, 2
        ORDER BY visitors DESC, utm_campaign ASC
      SQL

      any_scope.select_all(sql, binds)
    end

    def to_row(row)
      Row.new(site_id: row["site_id"], utm_campaign: row["utm_campaign"],
              visitors: row["visitors"].to_i, visits: row["visits"].to_i,
              pageviews: row["pageviews"].to_i)
    end

    def scopes
      @scopes ||= @periods.to_h { |site, period| [site, Scope.new(site: site, period: period)] }
    end

    def scope_for(site) = scopes.fetch(site)

    def any_scope = scopes.values.first

    # Taken from one scope and applied to every site, which is safe HERE and
    # would not be in general: Scope#volume_expression varies only with the
    # filters, neither campaigns screen has any, so every site's is the same
    # string. Read through Scope rather than written out so the definition of
    # "a pageview" stays in one place.
    def volume_expression = any_scope.volume_expression
  end
end
