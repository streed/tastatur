module Analytics
  # Top-N tables: pages, sources, countries, browsers, devices, campaigns.
  #
  # Always reads the raw hypertable. The continuous aggregates deliberately
  # carry no dimension columns (see the migration for why), and a breakdown is
  # by definition a question about dimensions.
  #
  # This is also where k-anonymity is enforced, which is the reason breakdowns
  # get their own service rather than being a scope on Event: the suppression
  # rule must be impossible to forget.
  class Breakdown < ApplicationService
    Row = Struct.new(:value, :visitors, :pageviews, :percentage, keyword_init: true) do
      def label = value.presence || "(none)"
    end

    Result = Struct.new(:rows, :suppressed_rows, :suppressed_visitors, :threshold, keyword_init: true) do
      def any? = rows.any?
      def suppressed? = suppressed_rows.positive?
    end

    DEFAULT_LIMIT = 10

    # Every panel on the dashboard, from ONE pass over the events.
    #
    # Called once per dimension, this class issues one scan each. The dashboard
    # renders eight panels over identical rows with identical conditions, so it was
    # scanning the same data eight times. Measured on 600,000 events over 90 days:
    # 152 ms for a single panel and 1,211 ms for the eight together, which was the
    # entire cost of the page — summary and timeseries come from the continuous
    # aggregates and are 2–12 ms.
    #
    # GROUPING SETS asks PostgreSQL for all eight groupings from a single scan.
    # `GROUPING(col)` returns 0 when that column is part of the grouping set that
    # produced the row, which is how each row is attributed back to its dimension —
    # checking for a non-null value would not work, because NULL is a legitimate
    # value for country, campaign and referrer.
    #
    # The suppression logic is deliberately untouched. This changes only how rows
    # are fetched; `partition` and `to_row` receive exactly the same shape they
    # always did, so k-anonymity and complementary suppression cannot have been
    # altered by this optimisation. spec/services/analytics/breakdown_batch_spec.rb
    # asserts the batch result is identical to the per-dimension result, dimension
    # by dimension.
    #
    # Returns { dimension => Result }.
    def self.batch(site:, period:, dimensions:, filters: Filters.new, limit: DEFAULT_LIMIT)
      known = dimensions.map(&:to_s).select { |d| Filters::DIMENSIONS.key?(d) }
      return {} if known.empty?

      scope = Scope.new(site: site, period: period, filters: filters)

      # entry_page is session-grain under a filter (see #fetch) and needs a
      # WHERE clause of its own there, so it cannot ride in the shared scan.
      # One extra query, only on filtered dashboards, which are the rare case
      # the batch optimisation was not built for.
      inline = scope.filters.any? ? known - ["entry_page"] : known
      rows = inline.any? ? grouped_rows(scope, inline) : {}
      total = total_from(rows)

      known.index_with do |dimension|
        service = new(site: site, period: period, dimension: dimension, filters: filters, limit: limit)

        if inline.include?(dimension)
          service.result_from(rows.fetch(dimension, []), total_visitors: total)
        else
          service.call.value!
        end
      end
    end

    # Two dimensions are not simply a column, and both are expressed the same way:
    # as a CASE that yields NULL for the rows they do not describe, so they can ride
    # along in the same GROUPING SETS pass. The NULL bucket each one collects is
    # dropped in `result_from`.
    #
    #   entry_page  "path, for the first event of a visit"
    #   event       "the name, for events that are not pageviews" — without the
    #               exclusion the panel is one enormous `pageview` row and nothing
    #               else, which is every row on the site and tells you nothing.
    CONDITIONAL = {
      "entry_page" => "CASE WHEN is_entry THEN path END",
      "event" => "CASE WHEN event_name <> 'pageview' THEN event_name END"
    }.freeze

    def self.select_expression(dimension)
      CONDITIONAL[dimension] || Filters::DIMENSIONS.fetch(dimension)
    end

    def self.grouped_rows(scope, dimensions)
      where, binds = scope.raw_conditions
      columns = dimensions.map { |d| select_expression(d) }
      aliases = dimensions.each_index.map { |i| "d#{i}" }

      selects = dimensions.each_with_index.map { |dimension, i| "GROUPING(#{aliases[i]}) = 0 THEN '#{dimension}'" }
      values = aliases.each_with_index.map { |name, i| "GROUPING(#{name}) = 0 THEN #{name}" }

      # COUNT(DISTINCT), and NOT the two-phase group-by-(value, visitor) form that
      # the single-dimension query uses.
      #
      # That is the opposite of what you would expect, and it was measured rather
      # than assumed. Two-phase wins for ONE dimension because it turns a
      # distinct-aggregate into a plain one. Across eight grouping sets it loses
      # badly, because each set's intermediate is one row per (value, visitor) pair
      # and eight of those have to be materialised before the outer aggregate runs.
      #
      # On 600,000 events over 90 days, eight panels:
      #
      #   eight separate scans, two-phase   1,214 ms
      #   one scan, COUNT(DISTINCT)           866 ms   <- this
      #   one scan, two-phase               1,356 ms   <- slower than doing nothing
      # The trailing () grouping set adds one grand-total row — distinct
      # visitors over the whole scope, no dimension — which is the percentage
      # denominator for every panel. Riding in the same scan, it costs nothing;
      # its dimension CASE yields NULL, so group_by files it under nil.
      sql = <<~SQL
        SELECT
          CASE #{selects.map { |s| "WHEN #{s}" }.join(' ')} END AS dimension,
          CASE #{values.map { |v| "WHEN #{v}" }.join(' ')} END AS value,
          COUNT(DISTINCT visitor_hash) AS visitors,
          #{scope.volume_expression}   AS pageviews
        FROM (
          SELECT visitor_hash, event_name,
                 #{columns.each_with_index.map { |c, i| "#{c} AS #{aliases[i]}" }.join(', ')}
          FROM events
          WHERE #{where}
        ) e
        GROUP BY GROUPING SETS (#{aliases.map { |a| "(#{a})" }.join(', ')}, ())
        ORDER BY 1, visitors DESC, pageviews DESC, 2 ASC
      SQL

      scope.select_all(sql, binds).group_by { |row| row["dimension"] }
    end

    def self.total_from(rows)
      rows.fetch(nil, []).first&.fetch("visitors").to_i
    end
    private_class_method :total_from

    def initialize(site:, period:, dimension:, filters: Filters.new, limit: DEFAULT_LIMIT)
      @scope = Scope.new(site: site, period: period, filters: filters)
      @dimension = dimension.to_s
      @limit = limit.clamp(1, 500)
    end

    def call
      column = Filters::DIMENSIONS[@dimension]
      return Failure(:unknown_dimension) if column.nil?

      Success(result_from(fetch(column), total_visitors: total_visitors))
    end

    # Shared by the single-dimension and batch paths, so both apply exactly the same
    # suppression to exactly the same row shape.
    #
    # `total_visitors` is the distinct-visitor count for the whole scope, not the
    # sum of the rows. Summing per-row visitor counts — which is what this used to
    # do — counts a visitor once for every value they appear under, so a visitor
    # who read three pages inflated the pages denominator threefold and every
    # percentage understated its row. Against the true audience, "42%" means 42%
    # of the filtered visitors are in this row, and rows legitimately sum past
    # 100% because one visitor can be in several.
    def result_from(rows, total_visitors:)
      # A conditional dimension collects everything it does not describe into a
      # single NULL bucket — every non-entry event for entry_page, every pageview
      # for event. That bucket is not a value, it is the absence of one, and left in
      # it would be both the largest row in the panel and meaningless.
      rows = rows.reject { |row| row["value"].nil? } if CONDITIONAL.key?(@dimension)

      kept, withheld = partition(rows)

      Result.new(
        rows: kept.first(@limit).map { |row| to_row(row, total_visitors) },
        suppressed_rows: withheld.size,
        suppressed_visitors: withheld.sum { |row| row["visitors"].to_i },
        threshold: @scope.k_threshold
      )
    end

    private

    def fetch(column)
      return entry_pages_of_qualifying_sessions if @dimension == "entry_page" && @scope.filters.any?

      where, binds = @scope.raw_conditions

      # The single-dimension path expresses the conditional dimensions as a WHERE
      # rather than the CASE the batch path needs, because with one grouping there
      # is no NULL bucket to keep the row count aligned. Same rows either way, and
      # breakdown_batch_spec asserts exactly that, dimension by dimension.
      where += " AND is_entry" if @dimension == "entry_page"
      where += " AND event_name <> 'pageview'" if @dimension == "event"

      # Ordering by visitors then pageviews keeps the ranking stable when two
      # rows tie on visitors, so a table does not reshuffle between refreshes.
      #
      # No LIMIT in SQL: we need the full result set to compute an honest
      # "n others withheld" count. The GROUP BY has already collapsed it to one
      # row per distinct value.
      @scope.select_all(<<~SQL, binds)
        SELECT
          #{column}                    AS value,
          COUNT(DISTINCT visitor_hash) AS visitors,
          #{@scope.volume_expression}  AS pageviews
        FROM events
        WHERE #{where}
        GROUP BY 1
        ORDER BY visitors DESC, pageviews DESC, 1 ASC
      SQL
    end

    # Entry pages are session-grain: the panel's question is "where did the
    # selected sessions begin", not "which entry events match the filter".
    # ANDing the filter onto is_entry — the plain path above — answers the
    # second question, which is almost always degenerate: under event=Signup no
    # entry event matches unless the session's very first hit was the custom
    # event, so the panel sat empty below a summary full of converting
    # visitors; under page=/pricing the panel could only ever contain /pricing
    # itself. So the filter qualifies sessions — the same rule
    # Analytics::Summary applies to bounce rate and duration — and the rows are
    # the entry events of every session that qualified.
    #
    # The volume column stays "entry pageviews", NOT volume_expression: session
    # qualification re-admits every event those sessions produced, so this
    # WHERE is not pinned to the filtered event and COUNT(*) would mean
    # nothing panel-appropriate here.
    def entry_pages_of_qualifying_sessions
      where, binds = @scope.session_qualified_conditions

      @scope.select_all(<<~SQL, binds)
        SELECT
          path                                            AS value,
          COUNT(DISTINCT visitor_hash)                    AS visitors,
          COUNT(*) FILTER (WHERE event_name = 'pageview') AS pageviews
        FROM events
        WHERE #{where} AND is_entry
        GROUP BY 1
        ORDER BY visitors DESC, pageviews DESC, 1 ASC
      SQL
    end

    # The percentage denominator: distinct visitors under the scope's filters,
    # without any dimension condition. The batch path reads the same number out
    # of its grand-total grouping set; this is the single-query equivalent.
    def total_visitors
      where, binds = @scope.raw_conditions

      @scope.select_one(<<~SQL, binds)["visitors"].to_i
        SELECT COUNT(DISTINCT visitor_hash) AS visitors FROM events WHERE #{where}
      SQL
    end

    # k-anonymity, including complementary suppression, lives in
    # Analytics::Suppression so that this panel and the custom-event property
    # panels cannot drift apart. See that file for the reasoning; it is the
    # whole argument for why breakdowns are a service rather than a scope.
    def partition(rows)
      Suppression.partition(rows, threshold: @scope.k_threshold)
    end

    def to_row(row, total)
      visitors = row["visitors"].to_i

      Row.new(
        value: row["value"],
        visitors: visitors,
        pageviews: row["pageviews"].to_i,
        percentage: total.zero? ? 0.0 : ((visitors.to_f / total) * 100).round(1)
      )
    end
  end
end
