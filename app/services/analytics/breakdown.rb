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
      rows = grouped_rows(scope, known)

      known.index_with do |dimension|
        new(site: site, period: period, dimension: dimension, filters: filters, limit: limit)
          .result_from(rows.fetch(dimension, []))
      end
    end

    # `entry_page` is the one dimension that is not simply a column: it means "path,
    # for the first event of a visit". Expressed as a conditional column so it can
    # take part in the same GROUPING SETS pass; rows where the event is not an entry
    # collapse into a NULL group, which is dropped below.
    def self.select_expression(dimension)
      return "CASE WHEN is_entry THEN path END" if dimension == "entry_page"

      Filters::DIMENSIONS.fetch(dimension)
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
      sql = <<~SQL
        SELECT
          CASE #{selects.map { |s| "WHEN #{s}" }.join(' ')} END AS dimension,
          CASE #{values.map { |v| "WHEN #{v}" }.join(' ')} END AS value,
          COUNT(DISTINCT visitor_hash)                    AS visitors,
          COUNT(*) FILTER (WHERE event_name = 'pageview') AS pageviews
        FROM (
          SELECT visitor_hash, event_name,
                 #{columns.each_with_index.map { |c, i| "#{c} AS #{aliases[i]}" }.join(', ')}
          FROM events
          WHERE #{where}
        ) e
        GROUP BY GROUPING SETS (#{aliases.map { |a| "(#{a})" }.join(', ')})
        ORDER BY 1, visitors DESC, pageviews DESC, 2 ASC
      SQL

      scope.select_all(sql, binds).group_by { |row| row["dimension"] }
    end

    def initialize(site:, period:, dimension:, filters: Filters.new, limit: DEFAULT_LIMIT)
      @scope = Scope.new(site: site, period: period, filters: filters)
      @dimension = dimension.to_s
      @limit = limit.clamp(1, 500)
    end

    def call
      column = Filters::DIMENSIONS[@dimension]
      return Failure(:unknown_dimension) if column.nil?

      Success(result_from(fetch(column)))
    end

    # Shared by the single-dimension and batch paths, so both apply exactly the same
    # suppression to exactly the same row shape.
    def result_from(rows)
      # The batch query groups entry_page over `CASE WHEN is_entry THEN path END`,
      # which collects every non-entry event into one NULL bucket. That bucket is not
      # an entry page; it is the absence of one.
      rows = rows.reject { |row| row["value"].nil? } if @dimension == "entry_page"

      total = rows.sum { |row| row["visitors"].to_i }
      kept, withheld = partition(rows)

      Result.new(
        rows: kept.first(@limit).map { |row| to_row(row, total) },
        suppressed_rows: withheld.size,
        suppressed_visitors: withheld.sum { |row| row["visitors"].to_i },
        threshold: @scope.k_threshold
      )
    end

    private

    def fetch(column)
      where, binds = @scope.raw_conditions

      # entry_page asks about the first page of a session, which is a filter on
      # the row rather than a different column.
      where += " AND is_entry" if @dimension == "entry_page"

      # Ordering by visitors then pageviews keeps the ranking stable when two
      # rows tie on visitors, so a table does not reshuffle between refreshes.
      #
      # No LIMIT in SQL: we need the full result set to compute an honest
      # "n others withheld" count and the percentage denominator. The GROUP BY
      # has already collapsed it to one row per distinct value.
      @scope.select_all(<<~SQL, binds)
        SELECT
          #{column}                                       AS value,
          COUNT(DISTINCT visitor_hash)                    AS visitors,
          COUNT(*) FILTER (WHERE event_name = 'pageview') AS pageviews
        FROM events
        WHERE #{where}
        GROUP BY 1
        ORDER BY visitors DESC, pageviews DESC, 1 ASC
      SQL
    end

    # Rows seen by fewer than k distinct visitors are withheld.
    #
    # The argument: a breakdown row is a statement that "someone who did X also
    # did Y". When only two people in Liechtenstein visited a niche page, that
    # row plus a rough visit time is enough for someone with outside knowledge
    # to work out who. At k=25 the row describes a crowd rather than a person.
    #
    # COMPLEMENTARY SUPPRESSION. Hiding the small rows is not sufficient on its
    # own. If exactly one row falls below the threshold, then
    #
    #     that row's value = reported total − sum of the visible rows
    #
    # and the suppression has protected nothing. The standard fix from
    # statistical disclosure control is to suppress a second row as well — the
    # smallest surviving one — so the withheld total covers at least two rows
    # and cannot be attributed to either. It costs one row of usefulness and is
    # the difference between suppression that works and suppression that only
    # looks like it does.
    def partition(rows)
      threshold = @scope.k_threshold
      return [rows, []] if threshold.zero?

      kept, withheld = rows.partition { |row| row["visitors"].to_i >= threshold }

      if withheld.one? && kept.any?
        smallest = kept.min_by { |row| row["visitors"].to_i }
        kept -= [smallest]
        withheld += [smallest]
      end

      [kept, withheld]
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
