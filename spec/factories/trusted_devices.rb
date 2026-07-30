FactoryBot.define do
  factory :trusted_device do
    user

    # The raw token is generated here and exposed as a transient so an example
    # can put it in a cookie. Nothing in the application can recover it from the
    # row, which is the point of the row storing a digest — so a factory that
    # only produced a digest would be untestable from the browser's side.
    transient { token { TrustedDevice.new_token } }

    token_digest { TrustedDevice.digest_for(token) }
    expires_at { TrustedDevice::TRUST_DURATION.from_now }
    last_used_at { Time.current }

    trait :expired do
      expires_at { 1.day.ago }
    end
  end
end
