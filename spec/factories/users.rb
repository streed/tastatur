FactoryBot.define do
  factory :user do
    sequence(:email) { |n| "user#{n}@example.test" }
    password { "password" }
    sequence(:name) { |n| "Test User #{n}" }

    # Devise's :confirmable module blocks sign-in until the address is
    # confirmed, so the default here is confirmed and :unconfirmed is the
    # exception. Otherwise every request spec would need a confirmation step
    # that has nothing to do with what it is testing.
    confirmed_at { Time.current }

    trait :unconfirmed do
      confirmed_at { nil }
    end

    # Instance-wide superuser (the Sidekiq console). NOT the same thing as being
    # an admin of an account.
    trait :admin do
      admin { true }
    end

    # Opted into the emailed second factor. Off by default, matching the product:
    # every existing request spec signs in without a challenge because that is
    # what almost every user experiences.
    trait :with_two_factor do
      two_factor_enabled { true }
    end

    # A user who already owns an account, for the common case where a spec needs
    # somewhere to hang a site.
    trait :with_account do
      transient { account_name { "Test Account" } }

      after(:create) do |user, ev|
        account = create(:account, name: ev.account_name)
        create(:membership, account: account, user: user, role: "owner")
      end
    end
  end
end
