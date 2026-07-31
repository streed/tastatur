module Analytics
  # The paths and custom event names this site has actually recorded, for the
  # pickers on the goal and funnel-step forms.
  #
  # A goal or a funnel step is a string compared against a column, and typing
  # that string by hand is the easiest way in this product to build one that
  # measures nothing: `/Pricing` for `/pricing`, a trailing slash, `signup` for
  # `Signup`. Nothing raises, the form saves, and the report reads 0% forever —
  # which looks exactly like a page nobody converts on. So the forms offer what
  # is really there and keep the field free text for everything else.
  #
  # THIS IS A BREAKDOWN, not a directory listing of the customer's website. The
  # rows are values plus distinct-visitor counts, produced by the same scan the
  # Top pages panel uses, so the site's k-anonymity threshold applies here
  # exactly as it applies there — rendering rows into a form instead of a panel
  # does not make them a different kind of statement, and /privacy promises the
  # threshold without qualifying where the rows are shown. Analytics::Breakdown
  # does the suppressing, which is the reason this reuses it rather than issuing
  # a cheaper `SELECT DISTINCT path`.
  #
  # A consequence worth knowing before it looks like a bug: on a quiet site at
  # the default threshold of 25, every row is withheld and the picker is empty.
  # That is the same thing the Top pages panel does on the same site, and the
  # forms say so plainly rather than looking broken. #withheld is what they say
  # it with.
  class KnownValues < ApplicationService
    # Long enough to cover a monthly release cycle, short enough that a page
    # deleted last quarter is not still being offered as a goal target.
    LOOKBACK = "30d".freeze

    # Per kind. Deliberately generous — a picker that omits the page you are
    # looking for is worse than no picker, because it reads as "that page does
    # not exist" — but bounded, because every one of these is bytes on a form
    # page and a large site has thousands of distinct paths.
    LIMIT = 250

    Value = Struct.new(:value, :visitors, keyword_init: true) do
      # Short keys: this is repeated up to 500 times in one page's JSON.
      def payload = { "v" => value, "n" => visitors }
    end

    Result = Struct.new(:paths, :events, :withheld, :threshold, :days, keyword_init: true) do
      def any? = paths.any? || events.any?
      def withheld? = withheld.positive?

      # Keyed by the `kind` column the form is choosing between, so the view and
      # the Stimulus controller agree on the names without a translation layer.
      def payload
        { "pageview" => paths.map(&:payload), "event" => events.map(&:payload) }
      end
    end

    def initialize(site:, period: nil)
      @site = site
      @period = period || Period.parse(LOOKBACK, site: site)
    end

    def call
      # One scan for both, via GROUPING SETS. Two calls would be two scans of
      # the same 30 days of raw events — see Analytics::Breakdown.batch.
      #
      # "event" is the conditional dimension that excludes pageviews, so the
      # event list is custom events only and never one enormous `pageview` row.
      breakdowns = Breakdown.batch(site: @site, period: @period,
                                   dimensions: %w[page event], limit: LIMIT)

      pages = breakdowns.fetch("page")
      events = breakdowns.fetch("event")

      Success(
        Result.new(
          paths: values_in(pages),
          events: values_in(events),
          withheld: pages.suppressed_rows + events.suppressed_rows,
          threshold: pages.threshold,
          days: @period.days
        )
      )
    end

    private

    # A blank value is not something anyone can pick. The breakdown panels render
    # it as "(none)" because an unattributed row still carries visitors worth
    # seeing; a form field has nothing to do with it.
    def values_in(result)
      result.rows.filter_map do |row|
        Value.new(value: row.value, visitors: row.visitors) if row.value.present?
      end
    end
  end
end
