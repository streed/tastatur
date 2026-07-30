module Analytics
  # Assembles everything the dashboard renders in one place.
  #
  # The individual reports are separate services because they are separately
  # useful (the shared dashboard, the API, and the funnel view each want a
  # different subset). This composes them so the controller stays a controller.
  class Dashboard < ApplicationService
    # The breakdown cards, in the order they appear. Each is one GROUP BY over
    # the same time window.
    PANELS = [
      { dimension: "page",         title: "Top pages" },
      { dimension: "entry_page",   title: "Entry pages" },
      { dimension: "source",       title: "Sources" },
      { dimension: "country",      title: "Countries" },
      { dimension: "device",       title: "Devices" },
      { dimension: "browser",      title: "Browsers" },
      { dimension: "os",           title: "Operating systems" },
      { dimension: "utm_campaign", title: "Campaigns" }
    ].freeze

    Report = Struct.new(:site, :period, :filters, :summary, :timeseries,
                        :breakdowns, :goals, :realtime, keyword_init: true)

    def initialize(site:, period:, filters: Filters.new)
      @site = site
      @period = period
      @filters = filters
    end

    def call
      Success(
        Report.new(
          site: @site,
          period: @period,
          filters: @filters,
          summary: Summary.call(site: @site, period: @period, filters: @filters).value!,
          timeseries: Timeseries.call(site: @site, period: @period, filters: @filters).value!,
          breakdowns: breakdowns,
          goals: GoalReport.call(site: @site, period: @period, filters: @filters).value!,
          realtime: Realtime.call(site: @site).value!
        )
      )
    end

    private

    # One scan for all eight panels rather than one each. See Breakdown.batch —
    # measured at 1,211 ms for eight separate scans over 600,000 events, which was
    # the whole cost of rendering this page.
    def breakdowns
      results = Breakdown.batch(
        site: @site, period: @period, dimensions: PANELS.map { |panel| panel[:dimension] },
        filters: @filters
      )

      PANELS.filter_map do |panel|
        result = results[panel[:dimension]]
        next if result.nil?

        panel.merge(result: result)
      end
    end
  end
end
