module Dashboards
  # What one widget renders: the widget itself, a status, and — when the status
  # is :ok — the data its partial consumes.
  #
  # `status` models the representable failure modes so one broken widget can
  # explain itself without taking the page down. That is a narrower promise
  # than "never raise": a query bug or a dead database still raises to Sentry
  # as usual. The two domain failures are:
  #
  #   :missing_funnel  the funnel this widget showed was deleted (the FK
  #                    nullified funnel_id); the widget renders an explanatory
  #                    empty state offering the edit page
  #   :invalid         the stored configuration no longer answers to a query —
  #                    a dimension that has left Analytics::Filters::DIMENSIONS,
  #                    a funnel below the minimum step count
  class WidgetResult < Dry::Struct
    STATUSES = %i[ok missing_funnel invalid].freeze

    attribute :widget, Types.Instance(DashboardWidget)
    attribute :status, Types::Strict::Symbol.enum(*STATUSES)

    # Per kind: Analytics::Summary::Metrics | Array[Analytics::Timeseries::Point] |
    # Analytics::Breakdown::Result | Array[Analytics::GoalReport::Row] |
    # Analytics::FunnelReport::Report. Nominal on purpose — each per-kind
    # partial is the sole consumer of exactly one of those shapes.
    attribute? :data, Types::Nominal::Any

    def ok? = status == :ok
  end
end
