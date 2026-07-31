FactoryBot.define do
  factory :dashboard_widget do
    dashboard
    kind { "stat" }
    metric { "visitors" }

    # Derived, not sequenced. Position carries a unique index per dashboard and
    # the dashboard factory already builds one widget, so a global sequence
    # would collide on the first one created against an existing dashboard.
    position { (dashboard.dashboard_widgets.maximum(:position) || 0) + 1 }
  end
end
