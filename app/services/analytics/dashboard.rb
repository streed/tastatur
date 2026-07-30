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
      { dimension: "utm_campaign", title: "Campaigns" },
      # Custom events had nowhere to appear at all. `tastatur('event', 'Signup')`
      # was accepted, stored and indexed — there is even a partial index on
      # (site_id, event_name, occurred_at) WHERE event_name <> 'pageview' — and then
      # shown on no screen unless you first went and created a Goal whose name
      # matched. Anyone following the "Track a custom event" instructions on the
      # install page saw nothing happen and had no way to tell a broken snippet from
      # a working one.
      { dimension: "event", title: "Custom events", only_when_present: true }
    ].freeze

    Report = Struct.new(:site, :period, :filters, :summary, :timeseries,
                        :breakdowns, :properties, :goals, :realtime, keyword_init: true)

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
          properties: properties,
          goals: GoalReport.call(site: @site, period: @period, filters: @filters).value!,
          realtime: Realtime.call(site: @site).value!
        )
      )
    end

    private

    # Property panels, and ONLY when the dashboard is scoped to something that
    # gives them a meaning.
    #
    # A property belongs to an event: `plan=pro` on Signup and `plan=pro` on
    # Cancelled are different facts, and pooling them across every event a site
    # sends produces a panel whose rows cannot be interpreted. So the entry
    # point is the Custom events panel — click "Signup", and its properties
    # appear beneath the breakdowns.
    #
    # It is also what keeps the ordinary dashboard's cost unchanged. The lateral
    # expansion in PropertyBreakdown is cheap against one event name in one
    # window; against every row a site has, it is a scan the unfiltered
    # dashboard has no reason to pay for. Note the second branch: once someone
    # has drilled into a property value the panels must stay, or the filter chip
    # would refer to a card that had vanished.
    #
    # Public shared dashboards therefore never reach this — they are rendered
    # with no filters at all, deliberately (see SharedDashboardsController), and
    # property values are the most re-identifying thing a customer can send us.
    def properties
      return [] unless @filters.event_scoped? || @filters.property_scoped?

      PropertyBreakdown.call(site: @site, period: @period, filters: @filters).value!
                       .map do |name, result|
        {
          dimension: "#{Filters::PROPERTY_PREFIX}#{name}",
          title: name,
          # What OUR analytics is told when someone drills into this panel. The
          # property key is the customer's own schema — `plan`, `user_id`,
          # `workspace` — and belongs in our database no more than `row.value`
          # does. See the note in sites/_breakdown.html.erb.
          analytics_dimension: "property",
          result: result
        }
      end
    end

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
        # A site that has never sent a custom event should not carry a ninth card
        # reading "No data." forever. The eight pageview panels are always shown,
        # because for those an empty panel is itself the answer.
        #
        # `suppressed?` is part of the test on purpose: a site whose only custom
        # events sit under the k-anonymity threshold HAS custom events, and hiding
        # the panel would be indistinguishable from not collecting them.
        next if panel[:only_when_present] && result.rows.empty? && !result.suppressed?

        panel.merge(result: result)
      end
    end
  end
end
