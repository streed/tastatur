# A subscription in the CUSTOMER'S Stripe account — their revenue, not ours.
#
# The name is deliberate; see the migration. `Billing::` handles subscriptions to
# Tastatur, and a bare `Subscription` sitting next to it would be a coin flip
# every time somebody read a call site.
class CustomerSubscription < ApplicationRecord
  include PubliclyIdentified
  public_identifier

  # Statuses that are producing, or are about to produce, recurring revenue.
  #
  # `past_due` counts. Stripe retries a failed charge for about two weeks and the
  # subscription sits here throughout; treating that as churn on day one produces
  # a churn spike every month that reverses itself, which trains people to ignore
  # the churn number. `unpaid` is where the retries have finished and failed, and
  # that is churn.
  LIVE_STATUSES = %w[trialing active past_due].freeze

  # Producing revenue right now. `trialing` is not — a trial is a commitment, not
  # a payment, and counting it as MRR is how a dashboard reports revenue that
  # never arrives.
  PAYING_STATUSES = %w[active past_due].freeze

  belongs_to :site
  belongs_to :customer

  validates :stripe_subscription_id, presence: true, uniqueness: { scope: :site_id }
  validates :status, :currency, :last_event_at, presence: true

  scope :live, -> { where(status: LIVE_STATUSES) }
  scope :paying, -> { where(status: PAYING_STATUSES) }

  def live? = LIVE_STATUSES.include?(status)
  def paying? = PAYING_STATUSES.include?(status)
  def trialing? = status == "trialing"

  # MRR as this subscription contributes it. A trial contributes nothing, which is
  # why `mrr_cents` (what it WILL be worth) and this (what it IS worth) are
  # separate — the trials column on the attribution screen needs the first and the
  # MRR column needs the second.
  def contributed_mrr_cents
    paying? ? mrr_cents : 0
  end

  # THE ORDERING GUARD, and the only place it lives.
  #
  # Stripe does not guarantee delivery order. Applying an older event after a
  # newer one leaves the row permanently wrong with nothing to correct it, and
  # unlike Billing::SyncSubscription this pipeline cannot re-fetch its way out —
  # re-fetching per delivery spends a customer's API rate limit, not ours.
  #
  # `>=` rather than `>`: two events can share a timestamp to the second (a plan
  # change emits `updated` alongside the invoice that pays for it), and dropping
  # the second of those loses a real change. Ties are applied in arrival order,
  # which for same-second events is as good an answer as exists.
  def stale?(event_at)
    event_at < last_event_at
  end
end
