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
  # A signing secret that specs can build real signature headers against, so
  # webhook specs exercise Stripe::Webhook.construct_event for real rather than
  # stubbing the one function whose correctness matters most.
  config.before do
    Rails.configuration.stripe = Rails.configuration.stripe.merge(webhook_secret: StripeWebhookHelpers::SECRET)
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
