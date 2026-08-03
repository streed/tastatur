module Analytics
  # Where visitors went next — one level of the navigation tree.
  #
  # Given a path already walked ("/", then "/pricing"), this answers "and then
  # what", as a table of next pages with the visitors who took each. Walk it
  # repeatedly and you get the flow tree on the Journeys page; ask it once, in
  # either direction, and you get the Came from / Went to panels that appear on
  # the dashboard when it is filtered to a single page.
  #
  # NEXT, NOT EVENTUALLY — the one thing that separates this from FunnelReport.
  #
  # A funnel step is satisfied by a match anywhere later in the visit, which is
  # right for "did they eventually convert" and wrong here. If "/" -> "/pricing"
  # meant "reached /pricing at some point after /", then a visitor who went
  # / -> /docs -> /pricing would be counted under BOTH branches of the tree, the
  # percentages would sum well past 100%, and the thing on screen would not be a
  # flow. So each level joins on n + 1: the immediately following page, and
  # nothing else.
  #
  # SESSIONS, NOT VISITORS, are what get walked. A journey is one sitting, and
  # session_hash is the only identifier that survives the midnight salt rotation
  # intact (Ingest::Identifier carries a visit in flight across it, which is why
  # FunnelReport's honest-limitation note does not apply to this report).
  # visitor_hash is still what gets COUNTed, so the numbers here mean the same
  # thing as the numbers in every other panel.
  #
  # CONSECUTIVE REPEATS OF ONE PATH COLLAPSE. A reload, or a bfcache restore, is
  # not navigation. Left in, the commonest "next page" for every page on the site
  # is itself, which is both true and useless.
  #
  # PERFORMANCE. The steps CTE sorts the period's pageviews by
  # (session_hash, occurred_at), which no current index provides. Measured on the
  # development set (17,971 events, 8,438 sessions, 30 days): 21-24 ms. Adding
  # (site_id, session_hash, occurred_at) was tried and the planner did not choose
  # it — it preferred the existing idx_events_site_time plus a 711 kB quicksort,
  # and the timing was unchanged at 26 ms. So the index is deliberately NOT there:
  # it would be permanent write cost on the ingest hot path for a plan PostgreSQL
  # declined. If this report ever does get slow, re-measure before assuming that
  # index is the answer. Note also that CREATE INDEX CONCURRENTLY is rejected
  # outright on a hypertable ("hypertables do not support concurrent index
  # creation", verified on TimescaleDB 2.29); the per-chunk form
  # `WITH (timescaledb.transaction_per_chunk)` is what works.
  class PageFlow < ApplicationService
    # A branch is one next (or previous) page. `path` is nil for the branch that
    # leaves the tree: the visit ended, or — walking backwards — began here.
    Branch = Struct.new(:path, :visitors, :sessions, :percentage, keyword_init: true) do
      def terminal? = path.nil?
    end

    Result = Struct.new(:prefix, :direction, :visitors, :branches,
                        :suppressed_rows, :suppressed_visitors, :threshold, keyword_init: true) do
      def any? = branches.any?
      def suppressed? = suppressed_rows.positive?

      # The page this level hangs off: the last one walked going forward, the
      # first one going backward.
      def anchor = direction == :backward ? prefix.first : prefix.last
    end

    DEFAULT_LIMIT = 8

    # Each level is another self-join, and a tree this deep is already past the
    # point where anyone can read it. The cap is applied by truncation rather
    # than by refusing, because an over-long path can only arrive from a
    # hand-edited URL.
    MAX_DEPTH = 6

    DIRECTIONS = %i[forward backward].freeze

    def initialize(site:, period:, prefix:, direction: :forward, filters: Filters.new, limit: DEFAULT_LIMIT)
      @scope = Scope.new(site: site, period: period, filters: filters)
      @prefix = Array(prefix).map(&:to_s).reject(&:empty?).first(MAX_DEPTH)
      @direction = DIRECTIONS.include?(direction.to_sym) ? direction.to_sym : :forward
      @limit = limit.clamp(1, 100)
    end

    def call
      return Failure(:no_start_page) if @prefix.empty?

      rows = execute
      Success(result_from(rows))
    end

    private

    # The filters select which SESSIONS count, not which of their events are
    # visible — Scope#session_qualified_conditions, for exactly the reason it
    # documents. Applying them per-event instead would be fatal rather than
    # merely wrong here: under `page=/pricing` every session would be left
    # holding nothing but its /pricing hits, so every visit would look like it
    # started and ended on that one page and the report would be structurally
    # empty. Unfiltered, the qualifying subquery admits every session in scope,
    # so it is skipped rather than paid for.
    def conditions
      @scope.filters.any? ? @scope.session_qualified_conditions : @scope.unfiltered_conditions
    end

    def execute
      where, binds = conditions
      ctes = [ordered_cte(where), steps_cte]
      cte_binds = binds.dup

      @prefix.each_with_index do |path, index|
        ctes << (index.zero? ? anchor_cte : chain_cte(index))
        cte_binds << path
      end

      last = "r#{@prefix.size - 1}"

      # LEFT JOIN, so the sessions with nothing on the far side survive as a NULL
      # row. That row is the whole point of the panel — "left the site" is the
      # most common thing that happens after any page, and an INNER JOIN would
      # silently drop it and inflate every percentage beside it.
      #
      # The total rides along as a scalar subquery over the same CTE: it is
      # COUNT(DISTINCT visitor_hash) at this node, which cannot be recovered by
      # summing the branches (one visitor can hold several sessions that diverge).
      @scope.select_all(<<~SQL, cte_binds)
        WITH #{ctes.join(", ")}
        SELECT
          s.path                       AS value,
          COUNT(DISTINCT r.visitor_hash) AS visitors,
          COUNT(*)                     AS sessions,
          (SELECT COUNT(DISTINCT visitor_hash) FROM #{last}) AS total
        FROM #{last} r
        LEFT JOIN steps s
          ON s.session_hash = r.session_hash
         AND s.n = #{step_offset}
        GROUP BY 1
        ORDER BY visitors DESC, sessions DESC, 1 ASC
      SQL
    end

    # Forward extends from the end of the walked path; backward from its start,
    # which is what `anchor` is carried through the chain for.
    def step_offset
      @direction == :backward ? "r.anchor - 1" : "r.n + 1"
    end

    def ordered_cte(where)
      <<~SQL
        ordered AS (
          SELECT session_hash, visitor_hash, path, occurred_at,
                 LAG(path) OVER (PARTITION BY session_hash ORDER BY occurred_at) AS prev_path
          FROM events
          WHERE #{where} AND event_name = 'pageview'
        )
      SQL
    end

    # WHERE is evaluated before the window function, so the repeats are gone
    # before ROW_NUMBER counts — the positions are 1..n over the collapsed
    # sequence, which is what the n + 1 joins above rely on.
    def steps_cte
      <<~SQL
        steps AS (
          SELECT session_hash, visitor_hash, path,
                 ROW_NUMBER() OVER (PARTITION BY session_hash ORDER BY occurred_at) AS n
          FROM ordered
          WHERE prev_path IS DISTINCT FROM path
        )
      SQL
    end

    # DISTINCT ON, not GROUP BY, and the difference is load-bearing. A session
    # that spans the site's local midnight holds TWO visitor_hashes for one
    # visitor, so grouping by (session_hash, visitor_hash) would emit that
    # session twice and count its journey twice. One row per session, carrying
    # the visitor_hash observed at the anchor step.
    def anchor_cte
      <<~SQL
        r0 AS (
          SELECT DISTINCT ON (session_hash)
                 session_hash, visitor_hash, n AS anchor, n
          FROM steps
          WHERE path = ?
          ORDER BY session_hash, n
        )
      SQL
    end

    def chain_cte(index)
      <<~SQL
        r#{index} AS (
          SELECT p.session_hash, p.visitor_hash, p.anchor, s.n
          FROM r#{index - 1} p
          JOIN steps s
            ON s.session_hash = p.session_hash
           AND s.n = p.n + 1
          WHERE s.path = ?
        )
      SQL
    end

    # k-anonymity, through the same Analytics::Suppression every other panel
    # uses, and it matters more here than anywhere else in the application.
    #
    # A branch is a CONJUNCTION — "these N people went /, then /pricing, then
    # /checkout" — and each level narrows the crowd it describes. That is exactly
    # the disclosure risk suppression exists for, and it is why the tree is only
    # walkable through branches that survived: a node you cannot see is a node
    # you cannot expand, so every sequence reachable in the UI describes at least
    # k visitors at every step along it.
    #
    # The terminal row is partitioned with the rest rather than exempted. It has
    # to be: the node's total is on screen, so "left the site" is recoverable as
    # total - the visible branches, and leaving it out would hand back precisely
    # the number complementary suppression is there to protect.
    def result_from(rows)
      total = rows.first&.fetch("total").to_i
      kept, withheld = Suppression.partition(rows, threshold: @scope.k_threshold)

      Result.new(
        prefix: @prefix,
        direction: @direction,
        visitors: total,
        branches: kept.first(@limit).map { |row| to_branch(row, total) },
        suppressed_rows: withheld.size,
        suppressed_visitors: withheld.sum { |row| row["visitors"].to_i },
        threshold: @scope.k_threshold
      )
    end

    def to_branch(row, total)
      visitors = row["visitors"].to_i

      Branch.new(
        path: row["value"],
        visitors: visitors,
        sessions: row["sessions"].to_i,
        percentage: total.zero? ? 0.0 : ((visitors.to_f / total) * 100).round(1)
      )
    end
  end
end
