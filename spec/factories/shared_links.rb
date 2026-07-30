FactoryBot.define do
  factory :shared_link do
    site
    sequence(:name) { |n| "Share #{n}" }

    trait :with_password do
      password { "correct horse battery staple" }
    end

    trait :expired do
      expires_at { 1.day.ago }
    end
  end
end
