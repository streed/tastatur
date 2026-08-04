module Analytics
  # Where visitors went next — one level of the navigation tree.
  #
  # Given a path already walked ("/", then "/pricing"), this answers "and then
  # what", as a table of next steps with the visitors who took each. Walk it
  # repeatedly and you get the flow tree on the Journeys page; ask it once, in
  # either direction, and you get the Came from / Went to panels that appear on
  # the dashboard when it is filtered to a single page.
  #
  # A STEP IS A PAGE OR A CUSTOM EVENT, and which one is `include_events`.
  #
  # A journey through a page-only report is a journey with the interesting part
  # removed: the thing between /pricing and /checkout is usually the click, and
  # a report that can only say "and then they were on the next page" cannot say
  # where the ones who did not click went instead. So the Journeys screen walks
  # both, and each step carries its kind — an Analytics::FlowStep — rather than a
  # bare string, for the reason that class documents.
  #
  # It is OFF by default, and the dashboard's two flow panels are why. Those are
  # titled "The page before this one" and "The page after this one", they answer
  # a question about pages, and a site that fires a scroll-depth event on every
  # page would have both of them report that event and nothing else. The screen
  # that wants events asks for them.
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
  # CONSECUTIVE REPEATS OF ONE STEP COLLAPSE. A reload, or a bfcache restore, is
  # not navigation. Left in, the commonest "next page" for every page on the site
  # is itself, which is both true and useless. The rule extends to events on the
  # composite key rather than being confined to pages: a double-clicked button
  # sends the same event twice and that is the same non-navigation, while a
  # pageview and an event fired on it are different steps and never collapse
  # into each other.
  #
  # THE PREFIX IS MATCHED WITH LEAD, NOT WITH A CHAIN OF SELF-JOINS, and that is
  # a performance fix rather than a tidy-up. Do not put the joins back.
  #
  # This walked the prefix by joining `steps` to itself once per hop — r0 for the
  # anchor, then r1 JOIN steps ON s.n = r0.n + 1, and so on. It was correct and
  # it was catastrophic past depth one. `steps` is a CTE referenced several
  # times, so PostgreSQL materialises it, and **a materialised CTE carries no
  # statistics**: every scan of it is estimated at rows=1 regardless of what is
  # really in there. On that estimate the planner picks a nested loop, and the
  # nested loop rescans the whole materialised CTE once per outer row. Measured
  # on the development set (32,440 events, 18,354 sessions, 30 days):
  #
  #     depth 1     33 ms          depth 2   2,338 ms          depth 3   3,124 ms
  #
  # with the depth-2 plan discarding 5,118,092 rows in the join filter — 2,855
  # loops over a 12,241-row CTE scan to produce 923 rows. The whole Journeys page
  # was 5.7 s of database time. Nothing was wrong with the data or the index; the
  # shape of the query was unplannable.
  #
  # LEAD and LAG answer the same question over the window the steps CTE is
  # already sorting for, so the joins are gone entirely: a session's row for its
  # anchor step carries the following steps in its own columns, the prefix test
  # is an ordinary WHERE over those columns, and the branch is one more of them.
  # One sort, no joins, nothing for the planner to get wrong. Same set of
  # measurements: 35 ms / 36 ms / 37 ms — depth no longer costs anything, because
  # a deeper path only adds a column.
  #
  # LEAD ALSO REPLACES THE LEFT JOIN that produced the terminal row. Past the end
  # of a session LEAD returns NULL, which is exactly the "left the site" branch,
  # arrived at for free rather than through an outer join that an INNER JOIN
  # refactor could quietly drop.
  #
  # THE SORT ITSELF. The steps CTE sorts the period's events by
  # (session_hash, occurred_at), which no current index provides. Adding
  # (site_id, session_hash, occurred_at) was tried and the planner did not choose
  # it — it preferred the existing idx_events_site_time plus a quicksort, and the
  # timing was unchanged. So the index is deliberately NOT there: it would be
  # permanent write cost on the ingest hot path for a plan PostgreSQL declined.
  # If this report ever does get slow again, re-measure before assuming that index
  # is the answer — it was not the answer last time, and it was not the answer
  # this time either. Note also that CREATE INDEX CONCURRENTLY is rejected
  # outright on a hypertable ("hypertables do not support concurrent index
  # creation", verified on TimescaleDB 2.29); the per-chunk form
  # `WITH (timescaledb.transaction_per_chunk)` is what works.
  class PageFlow < ApplicationService
    # A branch is one next (or previous) step. `step` is nil for the branch that
    # leaves the tree: the visit ended, or — walking backwards — began here.
    Branch = Struct.new(:step, :visitors, :sessions, :percentage, keyword_init: true) do
      def terminal? = step.nil?
    end

    Result = Struct.new(:prefix, :direction, :visitors, :branches,
                        :suppressed_rows, :suppressed_visitors, :threshold, keyword_init: true) do
      def any? = branches.any?
      def suppressed? = suppressed_rows.positive?

      # The step this level hangs off: the last one walked going forward, the
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

    # Ties are ordinary here in a way they were not when only pageviews were
    # walked: a click event and the pageview it fired on arrive in separate
    # beacons and land on the same `occurred_at` often enough to matter. Two
    # window functions over an unstable order would then number the steps one
    # way and collapse the repeats another, so the order is pinned — and pinned
    # so that a page sorts before anything that happened on it, which is the only
    # causal reading of a tie.
    STEP_ORDER = "occurred_at, CASE WHEN kind = 'pageview' THEN 0 ELSE 1 END, value".freeze

    def initialize(site:, period:, prefix:, direction: :forward, filters: Filters.new,
                   include_events: false, limit: DEFAULT_LIMIT)
      @scope = Scope.new(site: site, period: period, filters: filters)
      @prefix = Array(prefix).filter_map { |step| FlowStep.coerce(step) }.first(MAX_DEPTH)
      @direction = DIRECTIONS.include?(direction.to_sym) ? direction.to_sym : :forward
      @include_events = include_events
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
      ctes = [labelled_cte(where), ordered_cte, steps_cte, anchored_cte, matched_cte]

      # In the order the `?`s appear in the assembled string: the period and site
      # first, then the anchor step, then one pair per remaining prefix step.
      cte_binds = binds.dup
      @prefix.each { |step| cte_binds.push(step.kind, step.value) }

      # The total rides along as a scalar subquery over the same CTE: it is
      # COUNT(DISTINCT visitor_hash) at this node, which cannot be recovered by
      # summing the branches (one visitor can hold several sessions that diverge).
      # It is also the only second reference to `matched`, which is what keeps
      # that one CTE materialised — deliberately, since it is one row per session
      # and recomputing it would mean redoing the sort.
      @scope.select_all(<<~SQL, cte_binds)
        WITH #{ctes.join(", ")}
        SELECT
          #{branch_kind}  AS kind,
          #{branch_value} AS value,
          COUNT(DISTINCT visitor_hash) AS visitors,
          COUNT(*)                     AS sessions,
          (SELECT COUNT(DISTINCT visitor_hash) FROM matched) AS total
        FROM matched
        GROUP BY 1, 2
        ORDER BY visitors DESC, sessions DESC, 2 ASC, 1 ASC
      SQL
    end

    # Which shifted copies of the step sequence this query needs.
    #
    # Offsets 1..n-1 test the rest of the walked prefix. Walking forward, one
    # more — offset n — IS the branch being reported. Walking backward the branch
    # is behind the anchor instead, so LAG(1) supplies it and no extra LEAD is
    # needed. Bounded by MAX_DEPTH, so this is at most six pairs of columns over
    # one window that was being computed anyway.
    def lead_offsets
      offsets = (1...@prefix.size).to_a
      offsets << @prefix.size if @direction == :forward
      offsets
    end

    # Forward reports the step at the end of the walked path; backward the one
    # immediately before its start.
    def branch_kind = @direction == :backward ? "prev_step_kind" : "kind_#{@prefix.size}"
    def branch_value = @direction == :backward ? "prev_step_value" : "value_#{@prefix.size}"

    # Every row becomes a (kind, value) pair before anything else looks at it,
    # and the two CASEs are the only place in this query that knows how the
    # events table spells the distinction. They are real columns rather than
    # expressions repeated downstream because a window ORDER BY cannot reference
    # an output alias of its own SELECT — hence the extra CTE.
    #
    # With events excluded this is byte-for-byte the predicate the report has
    # always used, so the pages-only plan (and the measurement in the note above)
    # is unchanged.
    def labelled_cte(where)
      <<~SQL
        labelled AS (
          SELECT session_hash, visitor_hash, occurred_at,
                 CASE WHEN event_name = 'pageview' THEN 'pageview' ELSE 'event' END AS kind,
                 CASE WHEN event_name = 'pageview' THEN path ELSE event_name END AS value
          FROM events
          WHERE #{where}#{" AND event_name = 'pageview'" unless @include_events}
        )
      SQL
    end

    def ordered_cte
      <<~SQL
        ordered AS (
          SELECT session_hash, visitor_hash, kind, value, occurred_at,
                 LAG(kind)  OVER w AS prev_kind,
                 LAG(value) OVER w AS prev_value
          FROM labelled
          WINDOW w AS (PARTITION BY session_hash ORDER BY #{STEP_ORDER})
        )
      SQL
    end

    # WHERE is evaluated before the window functions, so the repeats are gone
    # before any of them run — LEAD lands on the next DISTINCT step rather than
    # on a reload of the current one, which is the whole reason the collapse and
    # the shift have to happen in this order and in this one SELECT.
    #
    # Both halves of the key are tested. `IS DISTINCT FROM` on the value alone
    # would collapse the `Signup` event that fired on `/signup` into the
    # pageview before it whenever a customer names the two the same way, which
    # is neither rare nor something they did wrong.
    #
    # Every window function names the same `w`, so this is one sort and one pass
    # however many offsets the walked path asks for.
    def steps_cte
      <<~SQL
        steps AS (
          SELECT session_hash, visitor_hash, kind, value,
                 ROW_NUMBER() OVER w AS n#{shifted_columns}
          FROM ordered
          WHERE prev_value IS DISTINCT FROM value OR prev_kind IS DISTINCT FROM kind
          WINDOW w AS (PARTITION BY session_hash ORDER BY #{STEP_ORDER})
        )
      SQL
    end

    # The step sequence, shifted. Reading a session's row for its anchor step,
    # `kind_1`/`value_1` are the step it took next, `kind_2`/`value_2` the one
    # after that, and NULL means the visit ended there.
    def shifted_columns
      columns = lead_offsets.map do |offset|
        ",\n LEAD(kind, #{offset})  OVER w AS kind_#{offset}" \
        ",\n LEAD(value, #{offset}) OVER w AS value_#{offset}"
      end

      if @direction == :backward
        columns << ",\n LAG(kind)  OVER w AS prev_step_kind" \
                   ",\n LAG(value) OVER w AS prev_step_value"
      end

      columns.join
    end

    # DISTINCT ON, not GROUP BY, and the difference is load-bearing. A session
    # that spans the site's local midnight holds TWO visitor_hashes for one
    # visitor, so grouping by (session_hash, visitor_hash) would emit that
    # session twice and count its journey twice. One row per session, carrying
    # the visitor_hash observed at the anchor step.
    #
    # The FIRST arrival at the start step is the anchor, which is why the rest of
    # the prefix is tested in a separate CTE below rather than in this WHERE. A
    # session that reached the start step twice and only took the walked route
    # the second time did not take it from where this report is standing; folding
    # the two tests together would silently re-anchor onto the later arrival.
    def anchored_cte
      <<~SQL
        anchored AS (
          SELECT DISTINCT ON (session_hash) *
          FROM steps
          WHERE kind = ? AND value = ?
          ORDER BY session_hash, n
        )
      SQL
    end

    # The rest of the walked path, as a test on the shifted columns.
    #
    # The kind test stays beside the value it qualifies — the rule CLAUDE.md §12
    # states for a funnel step's conditions, and it is load-bearing for the same
    # reason: `value_1 = ?` alone would let a custom event named `/welcome`
    # satisfy a step that asked for the page.
    def matched_cte
      tests = (1...@prefix.size).map { |offset| "kind_#{offset} = ? AND value_#{offset} = ?" }

      "matched AS (SELECT * FROM anchored#{" WHERE #{tests.join(' AND ')}" if tests.any?})"
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

    # `kind`, not `value`, is what says a row is the terminal branch. Both
    # columns are NULL when the LEFT JOIN found nothing, but `path` is NOT NULL
    # on the events table while a kind is only ever absent for that one row.
    def to_branch(row, total)
      visitors = row["visitors"].to_i
      kind = row["kind"]

      Branch.new(
        step: kind && FlowStep.new(kind: kind, value: row["value"]),
        visitors: visitors,
        sessions: row["sessions"].to_i,
        percentage: total.zero? ? 0.0 : ((visitors.to_f / total) * 100).round(1)
      )
    end
  end
end
