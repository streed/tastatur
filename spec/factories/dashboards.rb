FactoryBot.define do
  factory :dashboard do
    site
    sequence(:name) { |n| "Dashboard #{n}" }

    transient do
      widgets { [{ kind: "stat", metric: "visitors" }] }
    end

    after(:build) do |dashboard, ev|
      ev.widgets.each_with_index do |attrs, i|
        dashboard.dashboard_widgets.build(position: i + 1, **attrs)
      end
    end
  end
end
