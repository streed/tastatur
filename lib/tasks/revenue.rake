# Builds a realistic revenue-attribution scenario against a connected Stripe
# sandbox, so the whole two-pipeline join (docs/architecture/revenue.md) can be
# exercised on a laptop instead of waited for in production.
#
# WHY IT NEEDS THE CONNECTED ACCOUNT'S OWN KEY, and why that is not a hole in the
# no-token invariant. Everything the application does with a connected account is
# a READ, made with the platform key plus `Stripe-Account`, and every permission
# in stripe-app/stripe-app.json ends in `_read`. Creating the subscriptions and
# invoices this task creates is a WRITE, which that access model cannot make and
# must never be able to make. So the writes are made as the customer's own
# application would make them — with the customer's own test key, supplied here
# and used nowhere else in the codebase. If this task could run on the platform
# key, that would be the bug.
#
# The scenarios are chosen to cover the traps §18 documents rather than to look
# like a business:
#
#   * both `revenue_events.kind` families, so a consumer that sums across them
#     produces a visibly impossible number
#   * an expansion and a churn, so the sign convention is exercised in both
#     directions
#   * a non-USD subscription, so `normalized_cents` stays NULL and the
#     unconverted-events counter on the rollup has something to count
#   * a customer with no attribution at all, which the backfill must label
#     `(pre-install)` rather than folding into Direct
#   * a referrer-only customer (no utm tags), which is the case `tst_referrer_host`
#     was added for and which silently collapsed to Direct without it
#
# The identify half goes over HTTP to this instance's own /api/v1/identify rather
# than calling Revenue::IdentifyCustomer in process, because the contract and the
# API-key authentication are part of what is being tested. The task mints a key
# if the site has none.
module TastaturRevenueSeed
  module_function

  # One scenario is a customer plus what happens to them. `attribution` is what
  # the customer's application would have stored from `tastatur.attribution()`
  # and is posted to identify AND written onto the Stripe customer's metadata —
  # both halves, because a real integration does both and they are applied by
  # different code paths (IdentifyCustomer vs Checkout.extract_attribution).
  SCENARIOS = [
    {
      key: "paid-search",
      email: "ada@example.com",
      attribution: { source: "google", medium: "cpc", campaign: "brand-2026",
                     term: "privacy analytics", landing_path: "/pricing" },
      amount_cents: 3_000, currency: "usd", interval: "month",
      then: :nothing
    },
    {
      key: "referral",
      email: "grace@example.com",
      # NO SOURCE AND NO MEDIUM, deliberately. This is what an untagged link from
      # a forum produces, it is the majority of organic traffic, and it is the
      # exact shape that was silently relabelled Direct before `referrer_host`
      # joined Checkout::FIELDS.
      attribution: { referrer_host: "news.ycombinator.com", landing_path: "/" },
      amount_cents: 1_000, currency: "usd", interval: "month",
      then: :upgrade
    },
    {
      key: "churned",
      email: "alan@example.com",
      attribution: { source: "reddit", medium: "social", campaign: "launch" },
      amount_cents: 2_000, currency: "usd", interval: "month",
      then: :cancel
    },
    {
      key: "refunded",
      email: "katherine@example.com",
      attribution: { source: "twitter", medium: "social" },
      amount_cents: 1_500, currency: "usd", interval: "month",
      then: :refund
    },
    {
      # A EUR subscription against a USD site. Normalize returns nil for anything
      # cross-currency, so this row is what makes the "we could not convert N
      # events" wording on the screen appear rather than staying theoretical.
      key: "unconverted",
      email: "edsger@example.com",
      attribution: { source: "google", medium: "organic" },
      amount_cents: 4_000, currency: "eur", interval: "month",
      then: :nothing
    },
    {
      # No attribution at all and no identify call — a customer who existed
      # before the connection. The backfill must label this `(pre-install)`.
      key: "pre-install",
      email: "barbara@example.com",
      attribution: nil,
      amount_cents: 2_500, currency: "usd", interval: "month",
      then: :nothing
    }
  ].freeze

  # A stable prefix on every object this task creates, so a sandbox can be swept
  # clean and so a human reading the Stripe dashboard knows what they are looking
  # at. Stripe has no "delete customer" that cascades, hence `revenue:sweep`.
  TAG = "tastatur-seed".freeze

  def client
    key = ENV["STRIPE_SANDBOX_SECRET_KEY"].to_s
    abort(<<~MESSAGE) if key.blank?
      STRIPE_SANDBOX_SECRET_KEY is not set.

      This is the TEST secret key of the sandbox account that installed the
      Tastatur app — the account playing the customer, not this instance's own
      Stripe account. Find it under Developers → API keys in that sandbox.

      It is deliberately a different variable from STRIPE_SECRET_KEY: this task
      writes, and nothing else in this application may write to a connected
      account.
    MESSAGE

    unless key.start_with?("sk_test_", "rk_test_")
      abort("STRIPE_SANDBOX_SECRET_KEY is not a test key. Refusing to create " \
            "subscriptions and refunds against a live account.")
    end

    Stripe::StripeClient.new(key)
  end

  def site
    token = ENV["SITE"].to_s
    scope = Site.all

    if token.present?
      scope.find_by(public_token: token) || abort("No site with public_token #{token.inspect}")
    elsif scope.count == 1
      scope.first
    else
      abort("Several sites exist. Pass SITE=<public_token>: " \
            "#{scope.pluck(:domain, :public_token).map { |d, t| "#{d} (#{t})" }.join(', ')}")
    end
  end

  # The price a scenario subscribes to. Reused across runs by looking it up with a
  # deterministic lookup_key, so re-running does not litter the account with a new
  # product each time.
  def price_for(client, scenario)
    lookup_key = "#{TAG}-#{scenario[:currency]}-#{scenario[:amount_cents]}"
    existing = client.v1.prices.list({ lookup_keys: [lookup_key], limit: 1 }).data.first
    return existing if existing

    client.v1.prices.create(
      lookup_key: lookup_key,
      currency: scenario[:currency],
      unit_amount: scenario[:amount_cents],
      recurring: { interval: scenario[:interval] },
      product_data: { name: "Tastatur seed #{scenario[:amount_cents] / 100} #{scenario[:currency].upcase}" }
    )
  end

  def create_customer(client, scenario, first_seen_at)
    metadata = { "seed" => TAG }
    if scenario[:attribution]
      metadata.merge!(
        Revenue::Checkout.metadata(scenario[:attribution].merge(first_seen_at: first_seen_at))
      )
    end

    customer = client.v1.customers.create(
      email: scenario[:email],
      description: "#{TAG} #{scenario[:key]}",
      metadata: metadata
    )

    # `pm_card_visa` is Stripe's always-succeeds test card. Attached and made the
    # default so the subscription's first invoice is PAID rather than sitting
    # open — an unpaid invoice produces no `invoice.paid`, so without this the
    # cash-family half of the ledger stays empty and the task appears to work.
    # THE ATTACHED PAYMENT METHOD'S OWN ID IS WHAT THE DEFAULT MUST BE SET TO.
    # `pm_card_visa` is a shared test *token*, not a payment method id: each
    # mention of it mints a fresh `pm_...`. So naming it twice attaches one
    # payment method and then points the customer's default at a second one that
    # was never attached, which Stripe refuses with "The payment method must be
    # attached to the customer" — naming, confusingly, the id of the one it just
    # created for the update.
    payment_method = client.v1.payment_methods.attach("pm_card_visa", { customer: customer.id })
    client.v1.customers.update(customer.id,
                               { invoice_settings: { default_payment_method: payment_method.id } })

    customer
  end

  def identify(scenario, stripe_customer_id, first_seen_at, api_key, base_url)
    return :skipped if scenario[:attribution].nil?

    body = {
      stripe_customer_id: stripe_customer_id,
      email: scenario[:email],
      attribution: scenario[:attribution].merge(first_seen_at: first_seen_at.iso8601)
    }

    uri = URI.join(base_url, "/api/v1/identify")
    request = Net::HTTP::Post.new(uri)
    request["Content-Type"] = "application/json"
    request["Authorization"] = "Bearer #{api_key}"
    request.body = body.to_json

    response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: uri.scheme == "https") do |http|
      http.request(request)
    end

    "#{response.code} #{response.body}"
  rescue Errno::ECONNREFUSED
    abort("Nothing is listening on #{base_url}. Start the server first (SSL_PORT=3443 bin/dev), " \
          "or set TASTATUR_URL.")
  end

  # An API key for the identify calls. A fresh one every run: the plaintext exists
  # once (see ApiKey), so a key an earlier run created cannot be recovered.
  #
  # THE NAME CARRIES A TIMESTAMP BECAUSE REVOKING DOES NOT FREE IT. `validates
  # :name, uniqueness: { scope: :site_id }` counts revoked keys too, so revoking
  # the previous run's key and minting another under the same name raises "Name
  # has already been taken" — on the SECOND run of this task and every one after,
  # while the first run passes and looks fine.
  def api_key_for(site)
    site.api_keys.live.where("name LIKE ?", "#{TAG}%").find_each(&:revoke!)

    key = ApiKey.generate!(site: site, name: "#{TAG} #{Time.current.strftime('%Y-%m-%d %H:%M:%S')}")
    key.save!
    key.plaintext
  end

  def apply_outcome(client, scenario, subscription, customer)
    case scenario[:then]
    when :upgrade
      # An expansion: same subscription, a dearer price. Produces an
      # `expansion` MRR delta rather than a second `new`.
      dearer = price_for(client, scenario.merge(amount_cents: scenario[:amount_cents] * 5))
      item = subscription.items.data.first
      client.v1.subscriptions.update(
        subscription.id,
        { items: [{ id: item.id, price: dearer.id }], proration_behavior: "none" }
      )
      "upgraded to #{dearer.unit_amount}"
    when :cancel
      client.v1.subscriptions.cancel(subscription.id)
      "cancelled"
    when :refund
      # Refund the invoice's charge, which is what produces `charge.refunded` and
      # a NEGATIVE cash row. Note the dispute path is deliberately not seeded:
      # `charge.dispute.created` is triggerable with `stripe trigger` and forcing
      # a real dispute needs the dispute test card and a settled charge.
      charge_id = charge_to_refund(client, customer)
      return "no charge to refund" if charge_id.blank?

      client.v1.refunds.create({ charge: charge_id })
      "refunded #{charge_id}"
    else
      "left running"
    end
  end

  # The charge to refund, found through the CUSTOMER rather than the invoice.
  #
  # THE INVOICE IS A DEAD END NOW AND CANNOT BE PROBED DEFENSIVELY. Reaching a
  # charge used to be `invoice.charge`, then `invoice.payment_intent`, and on
  # 2026-07-29.dahlia an invoice carries neither — nor `payments`, nor even
  # `subscription`, which moved under `parent`. Two traps in one, measured here:
  #
  #   * `invoice.charge` raises NoMethodError, so an `a || b` fallback never
  #     reaches `b` — the same shape CLAUDE.md §14 records for
  #     `subscription.current_period_end`;
  #   * and `invoice["payment_intent"]` does NOT return nil either. The SDK
  #     raises KeyError for a *removed* attribute, deliberately, to stop exactly
  #     the silent-nil upgrade this task was trying to write.
  #
  # So there is no version-tolerant way to ask an invoice for its charge. The
  # customer is created for one scenario and has one subscription, so their most
  # recent charge is the one to refund, and `charges.list` has been stable across
  # every version this has run against.
  def charge_to_refund(client, customer)
    client.v1.charges.list({ customer: customer.id, limit: 1 }).data.first&.id
  rescue Stripe::StripeError
    nil
  end
end

namespace :tastatur do
  namespace :revenue do
    desc "Create a full attribution scenario in a connected Stripe sandbox (SITE=<public_token>)"
    task seed: :environment do
      client = TastaturRevenueSeed.client
      site = TastaturRevenueSeed.site
      base_url = ENV.fetch("TASTATUR_URL", "http://localhost:3000")

      connection = site.stripe_connections.live.first
      if connection.nil?
        warn "WARNING: #{site.domain} has no live Stripe connection. The objects below will " \
             "still be created, but no webhook will be attributed until you connect."
      elsif connection.livemode
        abort("#{site.domain} is connected to a LIVE Stripe account. Refusing to seed.")
      end

      api_key = TastaturRevenueSeed.api_key_for(site)
      puts "Site:        #{site.domain} (#{site.public_token}), base currency #{site.base_currency}"
      puts "Connected:   #{connection&.stripe_account_id || '(none)'}"
      puts "Identify to: #{base_url}/api/v1/identify"
      puts

      TastaturRevenueSeed::SCENARIOS.each_with_index do |scenario, index|
        # Spread first-touch dates over the last few weeks so the rollup has more
        # than one day's row and the report's date axis is not a single point.
        first_seen_at = (TastaturRevenueSeed::SCENARIOS.length - index).weeks.ago

        stripe_customer = TastaturRevenueSeed.create_customer(client, scenario, first_seen_at)
        identified = TastaturRevenueSeed.identify(scenario, stripe_customer.id, first_seen_at,
                                                  api_key, base_url)

        price = TastaturRevenueSeed.price_for(client, scenario)
        subscription = client.v1.subscriptions.create(
          customer: stripe_customer.id,
          items: [{ price: price.id }],
          metadata: { "seed" => TastaturRevenueSeed::TAG }
        )

        outcome = TastaturRevenueSeed.apply_outcome(client, scenario, subscription, stripe_customer)

        puts format("%-12s %-20s %s", scenario[:key], stripe_customer.id, outcome)
        puts format("%-12s identify: %s", "", identified)
      end

      puts
      puts "Webhooks for these are delivered to whatever Connect endpoint the sandbox's"
      puts "platform has registered. If you are forwarding with the CLI, they have already"
      puts "arrived; otherwise run the rollup by hand:"
      puts
      puts "  bin/rails runner 'RollupAttributionJob.perform_now(#{site.id})'"
      puts
      puts "Then: bin/rails tastatur:revenue:status SITE=#{site.public_token}"
    end

    desc "Show what the revenue pipeline has recorded for a site (SITE=<public_token>)"
    task status: :environment do
      site = TastaturRevenueSeed.site
      connection = site.stripe_connections.live.first

      puts "Site:       #{site.domain} (#{site.public_token})"
      puts "Connection: #{connection ? "#{connection.stripe_account_id} livemode=#{connection.livemode} " \
                                       "backfilled_at=#{connection.backfilled_at}" : '(none)'}"
      puts "Customers:  #{site.customers.count}"
      puts "Subs:       #{site.customer_subscriptions.group(:status).count.inspect}"
      puts

      puts "Connect events:"
      site.connect_events.ordered.last(20).each do |event|
        state =
          if event.processed?
            "ok"
          elsif event.failed?
            "FAILED: #{event.error}"
          else
            "pending"
          end
        puts format("  %-34s %-28s %s", event.stripe_event_id, event.event_type, state)
      end
      puts "  (none)" if site.connect_events.none?
      puts

      puts "Revenue events by kind:"
      rows = site.revenue_events.group(:kind).pluck(
        :kind, Arel.sql("COUNT(*)"), Arel.sql("SUM(amount_cents)"),
        Arel.sql("COUNT(*) FILTER (WHERE normalized_cents IS NULL)")
      )
      rows.each do |kind, count, sum, unconverted|
        family = RevenueEvent::MRR_KINDS.include?(kind) ? "MRR delta" : "cash"
        puts format("  %-14s %-10s n=%-4s sum=%-10s unconverted=%s", kind, family, count, sum, unconverted)
      end
      puts "  (none)" if rows.empty?
      puts

      puts "Attribution (source / medium / campaign) from customers:"
      site.customers.group(:attribution_source, :attribution_medium, :attribution_campaign)
          .count.each do |(source, medium, campaign), count|
        puts format("  %-18s %-12s %-14s n=%s", source.inspect, medium.inspect, campaign.inspect, count)
      end
      puts

      puts "Rollups (new/expansion/churned MRR are split, never netted; lifetime is a"
      puts "snapshot that must not be summed across days — §18):"
      site.attribution_rollups.order(:date).last(20).each do |rollup|
        puts format("  %s %-18s %-10s %-12s visitors=%-3s signups=%-3s conv=%-3s " \
                    "new=%-7s exp=%-7s churn=%-7s lifetime=%-8s unconverted=%s",
                    rollup.date, rollup.source, rollup.medium, rollup.campaign,
                    rollup.visitors, rollup.signups, rollup.conversions,
                    rollup.new_mrr_cents, rollup.expansion_mrr_cents, rollup.churned_mrr_cents,
                    rollup.lifetime_revenue_cents, rollup.unconverted_events)
      end
      puts "  (none — run the rollup)" if site.attribution_rollups.none?
    end

    desc "Delete everything tastatur:revenue:seed created in the sandbox"
    task sweep: :environment do
      client = TastaturRevenueSeed.client
      deleted = 0

      # Search rather than list-and-filter: metadata is indexed by Stripe's search
      # API, and paging every customer in a sandbox somebody else has also been
      # using is both slower and more likely to delete something it should not.
      client.v1.customers.search({ query: "metadata['seed']:'#{TastaturRevenueSeed::TAG}'", limit: 100 })
            .auto_paging_each do |customer|
        client.v1.customers.delete(customer.id)
        deleted += 1
      end

      puts "Deleted #{deleted} seeded Stripe customers (subscriptions and invoices go with them)."
      puts "Local rows are NOT touched — the Stripe side is what this sweeps."
    end
  end
end
