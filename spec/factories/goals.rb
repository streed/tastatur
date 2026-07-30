FactoryBot.define do
  factory :goal do
    site
    sequence(:name) { |n| "Goal #{n}" }
    kind { "pageview" }
    match_value { "/pricing" }
    match_type { "exact" }

    trait :event do
      kind { "event" }
      match_value { "Signup" }
    end
  end
end
