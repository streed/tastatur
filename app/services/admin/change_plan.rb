module Admin
  # Sets an account's plan by hand, for the accounts whose plan Stripe does not
  # own — comping Pro for a friend, a refunder, an open-source project, or
  # taking such a comp back.
  #
  # WHY THIS REFUSES A SUBSCRIBED ACCOUNT. Billing::SyncSubscription is the only
  # place that decides what a paying customer is entitled to, and the nightly
  # Billing::ReconcileSubscriptions re-applies whatever Stripe holds — for every
  # account with a subscription id, including a cancelled one. A plan written
  # here over a subscription would therefore hold until 3am and then silently
  # revert, which is worse than a refusal: the admin saw it work. For those
  # accounts the durable levers are Stripe itself (the plan should follow the
  # money) or the `event_limit_override` / `site_limit_override` support columns,
  # which the sync deliberately leaves alone when they carry no expiry.
  #
  # An account with only a CUSTOMER id (somebody who opened Checkout and
  # abandoned it) is fine: the reconciler asks Stripe, finds no subscription,
  # and moves on without touching the plan.
  class ChangePlan < ApplicationService
    def initialize(account:, plan_key:)
      @account = account
      @plan_key = plan_key.to_s
    end

    def call
      # OFFERED, not ALL: `self_hosted` is a deployment mode, not an offer, and
      # assigning it here would be unlimited-everything under a different name.
      # The override columns exist for that, and they say what they are.
      plan = Billing::Plan::OFFERED.find { |candidate| candidate.key == @plan_key }
      return Failure(:unknown_plan) if plan.nil?

      # On a self-hosted install the plan column is ignored — Account#billing_plan
      # answers SELF_HOSTED unconditionally — so a control here would be a
      # placebo. The route exists in all deployments (see CLAUDE.md §14 on why
      # gates refuse rather than routes vanish); the view hides the form too.
      return Failure(:self_hosted) if Tastatur.self_hosted?
      return Failure(:same_plan) if @account.plan == plan.key
      return Failure(:stripe_owns_plan) if @account.subscribed?

      # Same rule as a Stripe-driven change: a downgrade must not retroactively
      # spend the month, an upgrade clears expiring grandfathering. Assigns the
      # override fields; the update! persists them with the plan.
      Billing::GrandfatherAllowance.call(account: @account, plan: plan)
      @account.update!(plan: plan.key)

      # The ingest path caches each account's event limit for a minute; drop it so
      # this process enforces the new plan at once.
      Billing::EventQuota.forget(@account.id)

      Success(@account)
    end
  end
end
