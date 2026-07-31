module Dashboards
  # Appends a widget to a dashboard from the dashboard itself.
  #
  # The new row is a stat tile on unique visitors, which is the cheapest widget
  # to recognise and the one whose default configuration is already valid — the
  # author lands back on the dashboard with a tile that shows a real number,
  # then configures it in place. A widget created in an unconfigured state
  # would have to render an "unconfigured" placeholder, which is a second empty
  # state to design and a row the dashboard's own validations would reject.
  #
  # Position is taken from the current maximum rather than from the count:
  # Dashboards::RemoveWidget closes gaps, but a caller that did not would leave
  # the count and the maximum disagreeing, and the unique index on
  # (dashboard_id, position) turns that disagreement into a 500.
  class AddWidget < ApplicationService
    # Shared with Sites::DashboardsController#create, which has to build the
    # first widget inline: a dashboard with none of them does not validate, so
    # it cannot be saved and then added to.
    DEFAULTS = { kind: "stat", metric: "visitors" }.freeze

    def initialize(dashboard:)
      @dashboard = dashboard
    end

    def call
      return Failure(:at_limit) if @dashboard.dashboard_widgets.count >= Dashboard::MAX_WIDGETS

      widget = @dashboard.dashboard_widgets.create!(
        **DEFAULTS,
        position: @dashboard.dashboard_widgets.maximum(:position).to_i + 1
      )

      Success(widget)
    end
  end
end
