FactoryBot.define do
  factory :account do
    sequence(:name) { |n| "Account #{n}" }

    trait :self_hosted do
      plan { "self_hosted" }
    end

    trait :with_owner do
      transient { owner { create(:user) } }
      after(:create) { |account, ev| create(:membership, account: account, user: ev.owner, role: "owner") }
    end
  end
end
