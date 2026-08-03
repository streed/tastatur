FactoryBot.define do
  factory :funnel do
    site
    sequence(:name) { |n| "Funnel #{n}" }
    window_seconds { 86_400 }

    # A step is `{ name:, match_value:, kind:, match_type: }` for the ordinary
    # one-condition case, or `{ name:, matches: [{...}, {...}] }` when the step
    # is satisfied by any one of several. The first form is the second with one
    # entry, which is exactly what it is in the database.
    transient do
      steps { [{ name: "Landed", match_value: "/" }, { name: "Priced", match_value: "/pricing" }] }
    end

    after(:build) do |funnel, ev|
      ev.steps.each_with_index do |attrs, i|
        step = funnel.funnel_steps.build(position: i + 1, name: attrs[:name])

        Array(attrs[:matches] || [attrs]).each_with_index do |match, j|
          step.conditions.build(
            position: j + 1,
            kind: match.fetch(:kind, "pageview"),
            match_value: match[:match_value],
            match_type: match.fetch(:match_type, "exact")
          )
        end
      end
    end
  end
end
