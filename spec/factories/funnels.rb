FactoryBot.define do
  factory :funnel do
    site
    sequence(:name) { |n| "Funnel #{n}" }
    window_seconds { 86_400 }

    transient do
      steps { [{ name: "Landed", match_value: "/" }, { name: "Priced", match_value: "/pricing" }] }
    end

    after(:build) do |funnel, ev|
      ev.steps.each_with_index do |attrs, i|
        funnel.funnel_steps.build(
          position: i + 1, name: attrs[:name],
          kind: attrs.fetch(:kind, "pageview"),
          match_value: attrs[:match_value],
          match_type: attrs.fetch(:match_type, "exact")
        )
      end
    end
  end
end
