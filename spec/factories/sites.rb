FactoryBot.define do
  factory :site do
    account
    sequence(:domain) { |n| "site-#{n}.example.com" }
    timezone { "Etc/UTC" }
    k_anonymity_threshold { 25 }

    trait :no_suppression do
      k_anonymity_threshold { 0 }
    end

    trait :receiving do
      first_event_at { 1.day.ago }
    end
  end
end
