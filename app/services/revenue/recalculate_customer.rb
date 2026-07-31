module Revenue
  # Recomputes the denormalised columns on one customer from the rows below them.
  #
  # THE ONLY WRITER OF `current_mrr_cents`, `lifetime_revenue_cents`,
  # `converted_at` and `churned_at`. Those four are derived, and the reason they
  # are stored at all is that the customers screen sorts and pages on two of them
  # — which a subquery per row cannot do at any reasonable cost.
  #
  # Anything derived and stored will eventually disagree with its source. This
  # service is the answer to that: it is cheap, it is idempotent, and it recomputes
  # from scratch rather than adjusting, so running it again always converges. Every
  # path that touches a subscription or a ledger row calls it, and the nightly
  # rollup calls it for anything that changed.
  class RecalculateCustomer < ApplicationService
    def initialize(customer:)
      @customer = customer
    end

    def call
      @customer.current_mrr_cents = current_mrr
      @customer.lifetime_revenue_cents = lifetime_revenue
      @customer.converted_at ||= first_payment_at
      @customer.churned_at = churn_at

      @customer.save!
      Success(@customer)
    end

    private

    # Only PAYING subscriptions. A trial is a commitment, not revenue, and
    # counting it here is how a dashboard reports money that has not arrived and
    # in a third of cases never will.
    def current_mrr
      @customer.customer_subscriptions.paying.sum(:mrr_cents)
    end

    # Cash, not MRR. `CASH_KINDS` excludes churn and contraction — those describe
    # a change in what will be collected in future, and subtracting them from
    # money already banked would make a long-standing customer who downgraded
    # appear to have paid us less than they did.
    def lifetime_revenue
      @customer.revenue_events.where(kind: RevenueEvent::CASH_KINDS).sum(:amount_cents)
    end

    def first_payment_at
      @customer.revenue_events
               .where(kind: [RevenueEvent::NEW, RevenueEvent::REACTIVATION])
               .minimum(:occurred_at)
    end

    # CHURN IS CURRENT STATE, NOT HISTORY, which is why this is assigned
    # unconditionally while `converted_at` uses `||=`.
    #
    # A customer who cancelled in March and resubscribed in April is not churned,
    # and a `||=` here would leave the March timestamp in place forever — so they
    # would count in every churn figure from then on while actively paying. The
    # conversion date genuinely is history and never moves; the churn date is a
    # description of right now and has to be able to become nil again.
    def churn_at
      return nil if @customer.customer_subscriptions.live.exists?

      # The most recent ending, so a customer with several cancelled subscriptions
      # churns on the day the last one stopped rather than the first.
      @customer.customer_subscriptions.maximum(:canceled_at) ||
        @customer.revenue_events.where(kind: RevenueEvent::CHURN).maximum(:occurred_at)
    end
  end
end
