module Analytics
  # Every funnel on a site next to the one number an index is read for: the
  # share of the visitors who entered that came out the far end.
  #
  # THIS IS N QUERIES, NOT ONE, and that is not an oversight to batch away
  # later. A funnel's query is a chain of CTEs built out of its own steps and
  # its own completion window (see FunnelReport), so two funnels share no shape
  # to batch the way Breakdown.batch's dimensions do. What keeps it affordable
  # is that funnels are configuration rather than data: a site has a handful,
  # each capped at Funnel::MAX_STEPS, and each query rides the same
  # (site_id, visitor_hash, occurred_at) index the funnel's own page uses.
  #
  # A funnel that cannot be reported on is a row with NO report — never a raised
  # error, and never a row quietly left out of the list. Both failure modes are
  # forbidden by the model, so a funnel in either state was written around it,
  # and the honest thing on an index is to list it, say nothing about a rate we
  # cannot compute, and let the reader open it: the funnel's own page redirects
  # to the form and names what is missing. Same decision Dashboards::Render
  # makes for a widget it cannot fill.
  class FunnelSummaries < ApplicationService
    Row = Struct.new(:funnel, :report, keyword_init: true) do
      def reportable?
        !report.nil?
      end
    end

    def initialize(funnels:, period:, filters: Filters.new)
      @funnels = funnels
      @period = period
      @filters = filters
    end

    def call
      Success(@funnels.map { |funnel| Row.new(funnel: funnel, report: report_for(funnel)) })
    end

    private

    def report_for(funnel)
      case FunnelReport.call(funnel: funnel, period: @period, filters: @filters)
      in Success(report) then report
      in Failure(:not_enough_steps) | Failure(:step_without_a_match) then nil
      end
    end
  end
end
