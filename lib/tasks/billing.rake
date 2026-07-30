# Checks that what Stripe will charge matches what /pricing says.
#
# THE FAILURE THIS EXISTS TO CATCH: the price is edited in the Stripe dashboard —
# a currency switch, a promotional amount, a new price id pasted into the wrong
# environment — and nothing in this application notices. The pricing page keeps
# publishing $40, customers keep being charged something else, and the first report
# comes from a customer reading their card statement.
#
# It is a task rather than a boot check on purpose. `assets:precompile` boots the
# app in production mode inside the Docker build, with no Stripe key and no
# network, so a verification at boot would fail the image build — the same mistake
# an `ENV.fetch("APP_HOST")` in production.rb once made. Run this from a deploy
# hook or by hand; it is fast and it exits non-zero when something is wrong.

# In a module rather than as bare methods in the rake file. A `def` at the top level
# of a .rake file — including inside a `namespace` block, which does not change the
# default definee — defines a private method on Object, so `verify_plan` would exist
# on every object in the application for the life of the process.
module TastaturBillingVerification
  module_function

  def problems_for(plan)
    if plan.stripe_price_id.blank?
      return ["#{plan.stripe_price_env_var} is not set, so the #{plan.name} plan cannot be bought"]
    end

    price = Stripe::Price.retrieve(plan.stripe_price_id)
    problems = []

    unless price[:unit_amount] == plan.price_cents
      problems << "#{plan.name}: Stripe charges #{price[:unit_amount]} #{price[:currency]&.upcase} but " \
                  "/pricing publishes #{plan.price_cents} #{plan.currency.upcase}"
    end

    unless price[:currency].to_s == plan.currency
      problems << "#{plan.name}: Stripe price is in #{price[:currency]} but the plan says #{plan.currency}"
    end

    interval = price[:recurring] && price[:recurring][:interval]
    unless interval.to_s == "month"
      problems << "#{plan.name}: Stripe price recurs #{interval.inspect}, not monthly — the plan's " \
                  "allowance is per calendar month, so any other interval means the two disagree"
    end

    problems << "#{plan.name}: the Stripe price is not active" unless price[:active]

    problems
  rescue Stripe::InvalidRequestError => e
    ["#{plan.name}: Stripe does not recognise price #{plan.stripe_price_id.inspect} (#{e.message}). " \
     "Wrong environment, or the id was mistyped?"]
  rescue Stripe::StripeError => e
    ["#{plan.name}: could not reach Stripe (#{e.class}: #{e.message})"]
  end

  def configuration_problems
    problems = []
    problems << "STRIPE_SECRET_KEY is not set" if ENV["STRIPE_SECRET_KEY"].blank?

    if Rails.configuration.stripe[:webhook_secret].blank?
      problems << "STRIPE_WEBHOOK_SECRET is not set — subscription changes will not be applied"
    end

    problems
  end
end

namespace :tastatur do
  namespace :billing do
    desc "Verify Stripe is configured and its prices match the published plans"
    task verify: :environment do
      if Tastatur.self_hosted?
        puts "SELF_HOSTED=1 — there is no billing on this instance and nothing to verify."
        next
      end

      problems = TastaturBillingVerification.configuration_problems
      Billing::Plan.purchasable_plans.each do |plan|
        problems.concat(TastaturBillingVerification.problems_for(plan))
      end

      if problems.empty?
        puts "Stripe looks right. Webhook endpoint should point at #{Tastatur.base_url}/billing/stripe/webhook"
        puts "Subscribed events: #{Billing::ApplyStripeEvent::HANDLED.join(', ')}"
      else
        warn "\nStripe configuration problems:\n"
        problems.each { |problem| warn "  - #{problem}" }
        warn "\nSee docs/architecture/billing.md"
        exit 1
      end
    end
  end
end
