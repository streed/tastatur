class Account < ApplicationRecord
  include PubliclyIdentified
  public_identifier

  # The catalogue is Billing::Plan; this constant exists so the model validation
  # and the accounts_plan_check CHECK constraint cannot drift apart from it.
  # spec/models/account_spec.rb compares all three.
  PLANS = Billing::Plan::KEYS

  has_many :memberships, dependent: :destroy
  has_many :users, through: :memberships
  has_many :sites, dependent: :destroy

  validates :name, presence: true, length: { maximum: 120 }
  validates :slug, presence: true, uniqueness: true,
                   format: { with: /\A[a-z0-9][a-z0-9-]{1,48}[a-z0-9]\z/,
                             message: "must be lowercase letters, numbers and hyphens" }
  validates :plan, inclusion: { in: PLANS }
  # Both overrides are normally NULL, meaning "use the plan's allowance". They
  # exist so support can lift one customer over a cap without inventing a plan
  # for them. See the migration, and Account#event_limit below.
  validates :event_limit_override, numericality: { greater_than_or_equal_to: 0 }, allow_nil: true
  validates :site_limit_override, numericality: { greater_than_or_equal_to: 1 }, allow_nil: true

  # Retention is a compliance control, so the range is bounded by what can be
  # defended rather than by what the column can hold.
  #
  # 25 months is CNIL's stated ceiling for audience-measurement data, and the
  # TimescaleDB backstop policy is set above it so a per-account choice is always
  # honoured. It previously allowed five years while the backstop dropped chunks
  # at 400 days, which meant any setting above 400 silently did not work.
  MAX_RETENTION_DAYS = 760
  DEFAULT_RETENTION_DAYS = 365

  # Offered in the UI. Discrete options rather than a free number field, because
  # this is a decision to be made deliberately, not a dial to nudge.
  RETENTION_OPTIONS = [
    ["3 months", 90],
    ["6 months", 180],
    ["12 months (recommended)", 365],
    ["24 months", 730],
    ["25 months (maximum)", MAX_RETENTION_DAYS]
  ].freeze

  validates :data_retention_days, numericality: { in: 1..MAX_RETENTION_DAYS }

  before_validation :generate_slug, on: :create

  # Stripe's subscription statuses that mean the customer is paid up. Its
  # vocabulary is wider (incomplete, incomplete_expired, paused, and whatever it
  # adds next), which is why this lists what counts as good rather than what
  # counts as bad — an unrecognised future status then reads as "not confirmed
  # good" instead of silently passing.
  GOOD_STANDING_STATUSES = %w[active trialing].freeze

  # Statuses that mean "your card needs attention", which is what the banner on
  # the billing screen is for.
  #
  # These do NOT decide access, and the two sets differ on purpose. `past_due`
  # still entitles the account: Stripe's retries run for up to about two weeks,
  # and stopping a paying customer's measurement on the first failed charge
  # destroys data they can never recover, usually over a card that has merely
  # expired. `unpaid` means those retries are finished and failed, so it does not
  # entitle. Entitlement is decided in exactly one place —
  # Billing::SyncSubscription::ENTITLING_STATUSES — and written to `plan`.
  PAYMENT_PROBLEM_STATUSES = %w[past_due unpaid].freeze

  def owner
    memberships.find_by(role: "owner")&.user
  end

  # --- Plan and limits -------------------------------------------------------

  # Does billing apply to this account at all?
  #
  # Two reasons it might not: a self-hosted install has switched it off, and a
  # hosted deployment with no Stripe keys cannot take money. Both are handled by
  # Tastatur.billing_enabled? — see the reasoning there. The important half is the
  # second: enforcing a plan limit on an instance that cannot sell an upgrade is a
  # paywall with no cashier, so limits are off until Stripe is wired up.
  #
  # Every limit question routes through here rather than through `plan`, which is
  # also why an account row left on "free" from before SELF_HOSTED was set is not
  # suddenly capped.
  def billable?
    Tastatur.billing_enabled?
  end

  # Can this account's existing subscription still be managed — cancelled, card
  # updated, invoices read?
  #
  # Deliberately NOT `billable?`. Stripe keeps charging whatever our configuration
  # holds, so an instance that has lost its price id can no longer SELL but must
  # still let people leave. See Tastatur.billing_manageable?.
  def billing_manageable?
    Tastatur.billing_manageable? && stripe_customer?
  end

  # The catalogue entry this account is DESCRIBED by. Keyed on deployment mode, not
  # on the billing gate.
  #
  # It used to return SELF_HOSTED whenever `!billable?`, which meant a hosted
  # customer paying $40 a month was told their plan was "Self-hosted" the moment an
  # env var went missing — on the account screen, the plan screen and in the usage
  # email. The limits are what the gate governs, and `event_limit`, `site_limit` and
  # `can_upgrade?` all short-circuit on `billable?` before they reach here, so
  # describing the account honestly costs nothing.
  def billing_plan
    return Billing::Plan.self_hosted if Tastatur.self_hosted?

    Billing::Plan.find!(plan)
  end

  # Events we will record in a calendar month, or Billing::Plan::UNLIMITED
  # (Float::INFINITY) when there is no cap — so callers can always just compare.
  #
  # An override of 0 is meaningful and is honoured: 0 is truthy in Ruby, so this
  # reads correctly, and a spec pins it so it keeps reading correctly if anyone
  # "tidies" it into `event_limit_override.presence`.
  #
  # THE OVERRIDES ARE IGNORED WHEN THERE IS NO BILLING. They exist so support can
  # lift a hosted customer over a cap; where there is no billing there is no support
  # and no cap, so a value left in the column by an import or an earlier deployment
  # must not be able to throttle an instance nobody is charging. Billing::EventQuota
  # short-circuits on the same condition, and these two disagreeing is precisely the
  # bug this guard removes: the model would report a limit enforcement did not apply.
  def event_limit
    return Billing::Plan::UNLIMITED unless billable?

    effective_event_limit_override || billing_plan.monthly_event_limit
  end

  # An override with `event_limit_override_until` in the past is over.
  #
  # The expiry exists because a mid-month downgrade would otherwise be retroactive:
  # the meter counts every event received in the calendar month, so an account that
  # recorded three million events on Pro and then cancelled would be measured
  # against Free's 100,000 and refused everything for the rest of the month.
  # Billing::GrandfatherAllowance handles that by writing an override of
  # "already used + the new allowance", expiring at the end of the month.
  #
  # A support-granted override has no expiry and is therefore permanent until
  # somebody removes it.
  def effective_event_limit_override
    return nil if event_limit_override.nil?
    return nil if event_limit_override_until.present? && event_limit_override_until.past?

    event_limit_override
  end

  def site_limit
    return Billing::Plan::UNLIMITED unless billable?

    site_limit_override || billing_plan.site_limit
  end

  # Unlimited on every plan. A method rather than nothing at all, so the account
  # screen can state it instead of leaving "how many teammates may I add?" to be
  # inferred from the absence of a check.
  def member_limit = Billing::Plan::MEMBER_LIMIT

  def at_site_limit?
    sites.count >= site_limit
  end

  # Negative when an account is over its limit, which happens legitimately: a
  # cancelled Pro account keeps all twenty of its sites, because a billing event
  # must not delete customer data. Views clamp at zero; the arithmetic is kept
  # honest so nothing reports "1 site remaining" to somebody nineteen over.
  def sites_remaining
    return Billing::Plan::UNLIMITED if site_limit == Billing::Plan::UNLIMITED

    site_limit - sites.count
  end

  # --- Subscription state ----------------------------------------------------

  # Has a Stripe subscription record, which is not the same as being entitled to
  # anything — a cancelled subscription keeps its id so the customer portal can
  # still show its invoices. What the account may do is decided by `plan`.
  def subscribed?
    stripe_subscription_id.present?
  end

  # Has ever paid, and therefore has invoices and possibly a payment method worth
  # showing in the portal.
  def stripe_customer?
    stripe_customer_id.present?
  end

  def subscription_in_good_standing?
    GOOD_STANDING_STATUSES.include?(subscription_status)
  end

  def payment_problem?
    PAYMENT_PROBLEM_STATUSES.include?(subscription_status)
  end

  # Cancelled, but still inside the period already paid for. The plan does not
  # change until Stripe ends the subscription and sends
  # customer.subscription.deleted, so this is what the billing screen shows rather
  # than pretending nothing happened.
  def cancelling?
    subscribed? && cancel_at_period_end?
  end

  def can_upgrade?
    billable? && !billing_plan.paid?
  end

  private

  def generate_slug
    return if slug.present? || name.blank?

    base = name.parameterize.presence || "account"
    base = base.first(48)
    candidate = base
    suffix = 1
    candidate = "#{base}-#{suffix += 1}" while Account.exists?(slug: candidate)
    self.slug = candidate
  end
end
