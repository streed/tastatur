FactoryBot.define do
  factory :waitlist_signup do
    sequence(:email) { |n| "waiting-#{n}@example.com" }
    feature { "revenue_attribution" }
    source { "revenue_page" }

    # A row is only usable if its digest matches a token somebody could present,
    # so the factory mints both and exposes the token as a transient. Storing a
    # digest of nothing would make every token test pass for the wrong reason.
    transient do
      token { SecureRandom.urlsafe_base64(32) }
    end

    token_digest { WaitlistSignup.digest(token) }
    confirmation_sent_at { Time.current }

    trait :confirmed do
      confirmed_at { Time.current }
    end

    trait :stale do
      confirmation_sent_at { WaitlistSignup::PENDING_LIFETIME.ago - 1.day }
      created_at { WaitlistSignup::PENDING_LIFETIME.ago - 1.day }
    end
  end
end
