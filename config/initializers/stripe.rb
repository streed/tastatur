# Stripe configuration.
#
# To wire up payments:
#   1. Create ONE product in the Stripe dashboard with a recurring monthly price
#      matching Billing::Plan::PRO (currently $30/month).
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
  webhook_secret:  ENV["STRIPE_WEBHOOK_SECRET"],

  # --- Stripe Connect: reading the CUSTOMER'S revenue ----------------------
  #
  # A SEPARATE INTEGRATION FROM EVERYTHING ABOVE, and it is worth being blunt
  # about the difference because both halves are "Stripe" and they point in
  # opposite directions. The three keys above take money FROM our customers. The
  # two below read revenue data belonging TO our customers, read-only, from their
  # own Stripe accounts.
  #
  # THE INTEGRATION IS A STRIPE APP (stripe-app/stripe-app.json), NOT A CONNECT
  # "PLATFORM". The legacy Connect Extension this was designed for — the only
  # registration kind that could request `read_only` and connect accounts already
  # attached to another platform — stopped being registrable when Stripe Apps
  # replaced it, and the Platform/Marketplace choices on the Connect settings
  # page are for routing payments, not reading them. What the app may read is its
  # manifest's permission list (all `_read`), fixed by Stripe's app review and
  # shown to the customer at install.
  #
  # Set up by uploading the app (see docs/architecture/revenue.md, "Operating
  # the Stripe App"); the client id is on the app's details page:
  #   STRIPE_CONNECT_CLIENT_ID=...           the app's OAuth client id
  #   STRIPE_CONNECT_WEBHOOK_SECRET=whsec_...
  #
  # THE CONNECT WEBHOOK NEEDS ITS OWN ENDPOINT AND ITS OWN SECRET. In the Stripe
  # dashboard a webhook endpoint is either "account" or "connect"; one endpoint
  # cannot be both, and each has a distinct signing secret. Pointing Connect
  # deliveries at /billing/stripe/webhook would fail every signature check, and —
  # because that controller answers 400 on a bad signature — Stripe would disable
  # the endpoint after three days, taking OUR OWN subscription webhooks down with
  # it. Hence two routes, two secrets, two controllers.
  #
  # NO ACCESS TOKEN IS EVER STORED. The OAuth exchange is how the customer grants
  # access and how we learn the account id; the token it returns is discarded, and
  # every later call uses `secret_key` plus a `Stripe-Account` header. See
  # StripeConnection and Revenue::StripeAccount.
  connect_client_id:      ENV["STRIPE_CONNECT_CLIENT_ID"],
  connect_webhook_secret: ENV["STRIPE_CONNECT_WEBHOOK_SECRET"]
}
