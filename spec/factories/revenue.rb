FactoryBot.define do
  factory :api_key do
    site
    sequence(:name) { |n| "key-#{n}" }

    # `generate!` rather than assigning attributes, so every factory-built key is
    # a real one that `ApiKey.authenticate` can resolve. A factory that set
    # `token_digest` directly would produce rows that look right and cannot
    # authenticate, which is exactly the kind of divergence that makes a green
    # suite meaningless for the endpoint this protects.
    initialize_with { ApiKey.generate!(site: site, name: name) }

    trait :revoked do
      revoked_at { 1.hour.ago }
    end
  end

  factory :customer do
    site
    sequence(:external_id) { |n| "user_#{n}" }
    first_seen_at { 3.days.ago }
    identified_at { 3.days.ago }
    attribution_source { "Google" }
    attribution_medium { "organic" }
    # Left NULL rather than set to the "(none)" sentinel, because that is what a
    # real row looks like: sentinels are applied when a row is read or grouped,
    # never when it is written. A factory storing one would hide the bug that
    # rule exists to prevent.
    attribution_campaign { nil }

    trait :paying do
      converted_at { 2.days.ago }
      current_mrr_cents { 4_000 }
      lifetime_revenue_cents { 4_000 }
    end

    trait :churned do
      converted_at { 30.days.ago }
      churned_at { 1.day.ago }
    end

    trait :direct do
      attribution_source { Revenue::Channel::DIRECT }
      attribution_medium { Revenue::Channel::NONE }
    end

    trait :with_stripe do
      sequence(:stripe_customer_id) { |n| "cus_test#{n}" }
    end
  end

  factory :stripe_connection do
    site
    sequence(:stripe_account_id) { |n| "acct_test#{n}" }
    livemode { true }
    scope { StripeConnection::SCOPE }
    connected_at { 1.day.ago }

    trait :test_mode do
      livemode { false }
    end

    trait :backfilled do
      backfilled_at { 1.hour.ago }
    end

    trait :revoked do
      revoked_at { 1.hour.ago }
    end
  end

  factory :customer_subscription do
    site
    customer { association :customer, site: site }
    sequence(:stripe_subscription_id) { |n| "sub_test#{n}" }
    status { "active" }
    mrr_cents { 4_000 }
    currency { "USD" }
    started_at { 10.days.ago }
    last_event_at { 1.day.ago }

    trait :trialing do
      status { "trialing" }
    end

    trait :canceled do
      status { "canceled" }
      canceled_at { 1.day.ago }
    end
  end

  factory :revenue_event do
    site
    customer { association :customer, site: site }
    kind { RevenueEvent::NEW }
    amount_cents { 4_000 }
    currency { "USD" }
    normalized_cents { 4_000 }
    mrr_delta_cents { 4_000 }
    occurred_at { 1.day.ago }
    sequence(:stripe_object_id) { |n| "sub_test#{n}:#{n}" }
  end

  factory :connect_event do
    site
    sequence(:stripe_event_id) { |n| "evt_test#{n}" }
    event_type { "customer.subscription.updated" }
    occurred_at { 1.hour.ago }
    payload do
      { "id" => stripe_event_id, "type" => event_type, "data" => { "object" => { "id" => "sub_1" } } }
    end
  end

  factory :attribution_rollup do
    site
    date { Date.current }
    source { "Google" }
    medium { "organic" }
    campaign { Revenue::Channel::NONE }
    visitors { 100 }
    signups { 10 }
    conversions { 2 }
    new_mrr_cents { 8_000 }
    net_mrr_cents { 8_000 }
    lifetime_revenue_cents { 8_000 }
  end
end
