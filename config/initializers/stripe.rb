# Stripe configuration.
#
# To wire up payments:
#   1. Create your product(s) and price(s) in the Stripe dashboard.
#   2. Grab your API keys from https://dashboard.stripe.com/apikeys
#   3. Fill in the env vars below in .env.development (and your prod secrets):
#        STRIPE_PUBLISHABLE_KEY=pk_test_...
#        STRIPE_SECRET_KEY=sk_test_...
#        STRIPE_WEBHOOK_SECRET=whsec_...      # from your webhook endpoint
#   4. Restart the server.
#
# Until those are set, Stripe API calls will raise — that's intentional;
# it surfaces missing config loudly instead of silently no-op'ing.

Stripe.api_key = ENV["STRIPE_SECRET_KEY"] if ENV["STRIPE_SECRET_KEY"].present?

Rails.configuration.stripe = {
  publishable_key: ENV["STRIPE_PUBLISHABLE_KEY"],
  secret_key:      ENV["STRIPE_SECRET_KEY"],
  webhook_secret:  ENV["STRIPE_WEBHOOK_SECRET"]
}
