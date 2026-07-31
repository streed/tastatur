module Dashboards
  # Everything a custom dashboard's page renders, assembled by
  # Dashboards::Render — the analogue of Analytics::Dashboard::Report for the
  # default dashboard.
  class Report < Dry::Struct
    attribute :dashboard, Types.Instance(Dashboard)
    attribute :period, Types::Nominal::Any
    attribute :widgets, Types::Array.of(Types.Instance(WidgetResult))
    attribute :realtime, Types::Strict::Integer
  end
end
