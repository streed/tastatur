# The only thing standing between this suite and api.stripe.com.
#
# There is no webmock and no VCR in this project, and .env.test sets
# STRIPE_SECRET_KEY=sk_test_dummy — which config/initializers/stripe.rb duly
# assigns — so a single forgotten stub would send a real HTTPS request to Stripe
# from a test run. Not a hypothetical: `Stripe.max_network_retries` defaults to 2
# and the read timeout to 80 seconds, so the failure mode is a spec that hangs for
# minutes and then fails for a reason that has nothing to do with what it tests.
#
# Pointing api_base at a closed local port turns any unstubbed call into a
# Stripe::APIConnectionError in microseconds, naming the call that was not stubbed.
# The retries and timeouts are flattened for the same reason: a guard that takes
# thirty seconds to fire is a guard people work around.
Stripe.api_key = "sk_test_suite"
Stripe.api_base = "http://127.0.0.1:1"
Stripe.max_network_retries = 0
Stripe.open_timeout = 1
Stripe.read_timeout = 1

RSpec.configure do |config|
  # THE SUITE RUNS WITH BILLING CONFIGURED, and that is deliberate.
  #
  # `Tastatur.billing_enabled?` is false until Stripe is set up, and when it is false
  # plan limits are not enforced at all. If the default here were the unconfigured
  # state, every limit spec in the suite would pass by measuring nothing — the same
  # silent-divergence trap as a factory whose default plan differs from production's.
  #
  # Established here rather than in .env.test because that file is gitignored: a
  # suite whose correctness depended on it would be correct on this machine and
  # vacuous in CI. spec/requests/billing_unconfigured_spec.rb covers the other state
  # explicitly.
  #
  # The signing secret is real, so webhook specs exercise
  # Stripe::Webhook.construct_event rather than stubbing the one function whose
  # correctness matters most.
  config.before do
    Rails.configuration.stripe = Rails.configuration.stripe.merge(
      secret_key: "sk_test_suite",
      webhook_secret: StripeWebhookHelpers::SECRET
    )
    # `blank?`, not `||=`. An empty string is truthy in Ruby, so `||=` would leave
    # `STRIPE_PRICE_PRO=` in place — and `Plan#stripe_price_id` calls `.presence`, so
    # that reads as unset and quietly disables billing for the whole run. Every
    # limit spec would then pass by measuring nothing.
    ENV["STRIPE_PRICE_PRO"] = "price_suite_default" if ENV["STRIPE_PRICE_PRO"].blank?
  end
end

module StripeWebhookHelpers
  SECRET = "whsec_test_secret".freeze

  # A correctly signed webhook request body and header pair.
  #
  # The timestamp is generated at call time rather than frozen into a fixture.
  # Stripe::Webhook::DEFAULT_TOLERANCE is 300 seconds, and the alternative — a
  # fixed fixture header plus `tolerance: nil` — would disable replay protection
  # everywhere the helper is used, including in the code path being tested.
  def stripe_signature_header(payload, secret: SECRET, timestamp: Time.current)
    signature = Stripe::Webhook::Signature.compute_signature(timestamp, payload, secret)

    Stripe::Webhook::Signature.generate_header(timestamp, signature, scheme: "v1")
  end

  # A minimal event envelope. `data.object` is whatever the handler will look at;
  # the handler re-fetches from the API rather than trusting the payload, so these
  # only need the identifiers.
  def stripe_event_payload(type:, object:, id: "evt_test_#{SecureRandom.hex(6)}")
    {
      id: id,
      object: "event",
      type: type,
      created: Time.current.to_i,
      data: { object: object }
    }.to_json
  end
end

RSpec.configure do |config|
  config.include StripeWebhookHelpers
end
