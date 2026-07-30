# Stripe configuration.
#
# To wire up payments:
#   1. Create ONE product in the Stripe dashboard with a recurring monthly price
#      matching Billing::Plan::PRO (currently $40/month).
#   2. Grab your API keys from https://dashboard.stripe.com/apikeys
#   3. Add a webhook endpoint pointing at https://YOUR_HOST/billing/stripe/webhook
#      subscribed to the events listed in Billing::ApplyStripeEvent::HANDLED.
#   4. Fill in the env vars below in .env.development (and your prod secrets):
#        STRIPE_PUBLISHABLE_KEY=pk_test_...
#        STRIPE_SECRET_KEY=sk_test_...
#        STRIPE_WEBHOOK_SECRET=whsec_...      # from that webhook endpoint
#        STRIPE_PRICE_PRO=price_...           # the recurring price id
#   5. Restart the server, then run `bin/rails tastatur:billing:verify` to check
#      that the price really costs what /pricing says it does.
#
# Until those are set, Stripe API calls will raise — that's intentional; it
# surfaces missing config loudly instead of silently no-op'ing.
#
# NOTHING HERE MAKES A NETWORK CALL. `assets:precompile` boots this file inside
# the Docker build, where there is no Stripe key and no network, so a verification
# that ran at boot would fail the image build — the same mistake that an
# `ENV.fetch("APP_HOST")` in production.rb once made (see
# config/initializers/required_env.rb). `tastatur:billing:verify` is the explicit
# version of that check, run when you want it.
#
# A SELF-HOSTED INSTALL NEVER READS ANY OF THIS. Everything billing-related asks
# Tastatur.self_hosted? first; see config/initializers/tastatur.rb.

Stripe.api_key = ENV["STRIPE_SECRET_KEY"] if ENV["STRIPE_SECRET_KEY"].present?

# The API version is deliberately NOT set here.
#
# The stripe gem sends its own pinned `Stripe-Version` on every request, so the
# shape of every object this app receives is already fixed — by the gem version in
# Gemfile.lock, which gets reviewed when it changes. Pinning a second version
# string in this file would create two sources of truth that can silently
# disagree: the gem parsing fields it expects while the API sends a different
# vintage.
#
# The one shape this matters for is read defensively regardless. Stripe moved
# `current_period_start`/`current_period_end` off the Subscription object onto its
# items in the 2025-03-31 ("basil") release, so Billing::SyncSubscription reads the
# item first and falls back to the subscription, using `[]` rather than a reader
# method so an absent field is nil instead of a NoMethodError.

# Retries on connection failures and 5xx, with exponential backoff. The client
# generates an idempotency key per request, so a retried POST cannot create two
# subscriptions. Two is enough to ride out a blip without holding a web request
# open for long.
Stripe.max_network_retries = 2

# Everything a request path needs, read once. The webhook secret is taken from
# here rather than from ENV at the point of use, so a spec has one place to stub —
# see spec/support/stripe.rb.
Rails.configuration.stripe = {
  publishable_key: ENV["STRIPE_PUBLISHABLE_KEY"],
  secret_key:      ENV["STRIPE_SECRET_KEY"],
  webhook_secret:  ENV["STRIPE_WEBHOOK_SECRET"]
}
