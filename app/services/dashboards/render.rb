module Dashboards
  # Assembles everything a custom dashboard renders, the way
  # Analytics::Dashboard does for the default one.
  #
  # The viewer supplies only the period. Every filter applied here was saved
  # onto a widget by the dashboard's author, which is what lets the public
  # share path use this service unchanged — the rule that a public dashboard
  # honours no viewer filters (see SharedDashboardsController) is kept by
  # construction, because there is no viewer-filter input to honour.
  #
  # Query economy, since a dashboard is one page view:
  #
  #   - Stat tiles sharing a filter set share ONE Analytics::Summary call;
  #     five tiles over the same filters are one query yielding all five
  #     metrics.
  #   - Breakdown widgets sharing a filter set share ONE Breakdown.batch scan
  #     (its whole point), issued at the largest row_limit in the group; each
  #     widget then truncates its own rows. Truncation is safe because the
  #     limit applies to rows AFTER suppression — suppressed_rows and
  #     suppressed_visitors are computed over the full result set and are
  #     identical either way.
  class Render < ApplicationService
    def initialize(dashboard:, period:)
      @dashboard = dashboard
      @site = dashboard.site
      @period = period
    end

    def call
      @widgets = @dashboard.dashboard_widgets.includes(funnel: { funnel_steps: :conditions }).to_a

      Success(
        Report.new(
          dashboard: @dashboard,
          period: @period,
          widgets: @widgets.map { |widget| result_for(widget) },
          realtime: Analytics::Realtime.call(site: @site).value!
        )
      )
    end

    private

    def result_for(widget)
      case widget.kind
      when "stat"
        ok(widget, summary_for(widget.saved_filters))
      when "timeseries"
        ok(widget, Analytics::Timeseries.call(site: @site, period: @period,
                                              filters: widget.saved_filters).value!)
      when "breakdown"
        breakdown_result(widget)
      when "goals"
        ok(widget, Analytics::GoalReport.call(site: @site, period: @period,
                                              filters: widget.saved_filters).value!)
      when "funnel"
        funnel_result(widget)
      end
    end

    def summary_for(filters)
      @summaries ||= {}
      @summaries[filters.applied] ||=
        Analytics::Summary.call(site: @site, period: @period, filters: filters, compare: true).value!
    end

    def breakdown_result(widget)
      return property_result(widget) if widget.property_dimension?

      result = batched_breakdowns(widget.saved_filters)[widget.dimension]
      # A dimension that has left Analytics::Filters::DIMENSIONS since this
      # widget was saved. Breakdown.batch drops unknown dimensions rather than
      # raising, so the absence IS the diagnosis.
      return WidgetResult.new(widget: widget, status: :invalid) if result.nil?

      ok(widget, truncate(result, widget.row_limit))
    end

    # One property of one event. PropertyBreakdown returns every property the
    # event carries from a single scan; the widget keeps its own. A property the
    # event never carried in this window is an empty panel, which is the true
    # answer, not an error.
    def property_result(widget)
      filters = widget.saved_filters
      return WidgetResult.new(widget: widget, status: :invalid) unless filters.event_scoped?

      panels = Analytics::PropertyBreakdown.call(site: @site, period: @period, filters: filters,
                                                 limit: widget.row_limit).value!
      result = panels.to_h[widget.property_name] ||
               Analytics::Breakdown::Result.new(rows: [], suppressed_rows: 0, suppressed_visitors: 0,
                                                threshold: Analytics::Scope.new(site: @site, period: @period, filters: filters).k_threshold)
      ok(widget, result)
    end

    def batched_breakdowns(filters)
      @batches ||= {}
      @batches[filters.applied] ||= begin
        group = @widgets.select { |w| w.breakdown? && w.saved_filters.applied == filters.applied }

        Analytics::Breakdown.batch(
          site: @site, period: @period,
          dimensions: group.map(&:dimension).uniq,
          filters: filters,
          limit: group.map(&:row_limit).max
        )
      end
    end

    def truncate(result, row_limit)
      return result if result.rows.length <= row_limit

      Analytics::Breakdown::Result.new(**result.to_h.merge(rows: result.rows.first(row_limit)))
    end

    # A widget whose funnel was deleted is a fact to state, not an error to
    # raise: the FK nullified funnel_id, the dashboard's shape is preserved,
    # and the view explains and offers the edit page.
    def funnel_result(widget)
      return WidgetResult.new(widget: widget, status: :missing_funnel) if widget.funnel.nil?

      case Analytics::FunnelReport.call(funnel: widget.funnel, period: @period,
                                        filters: widget.saved_filters)
      in Success(report) then ok(widget, report)
      in Failure(:not_enough_steps) | Failure(:step_without_a_match)
        WidgetResult.new(widget: widget, status: :invalid)
      end
    end

    def ok(widget, data)
      WidgetResult.new(widget: widget, status: :ok, data: data)
    end
  end
end
