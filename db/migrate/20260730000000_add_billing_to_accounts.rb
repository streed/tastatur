# Two plans, and the subscription state needed to keep them honest.
#
# WHAT CHANGES AND WHY.
#
# 1. THE PLAN SET COLLAPSES. `starter`, `growth` and `business` were placeholders
#    from the starter template that nothing ever sold, priced or enforced. The
#    hosted service offers exactly two plans — free and pro — plus `self_hosted`,
#    which is not an offer but a deployment mode. Any row on a placeholder plan
#    moves to `pro`, because those keys were only ever reachable by hand and
#    taking a plan away from somebody is the worse mistake.
#
#    A CHECK constraint pins the set, exactly as memberships_role_check pins the
#    role set. Plans are a closed enumeration whose members decide what a customer
#    is allowed, so a typo in a webhook handler should fail at write time rather
#    than leave an account on a plan no code recognises — where Billing::Plan.find!
#    then raises on every page that mentions billing.
#
# 2. `monthly_event_limit` BECOMES `event_limit_override`. It was `NOT NULL DEFAULT
#    10000`, so the real quota lived in a column default that no plan referred to
#    and no screen displayed. The plan now decides the quota (Billing::Plan), and
#    this column means only "this one account was granted something different" — a
#    support lever that can lift a customer over a cap immediately, without a
#    deploy and without inventing a plan for them.
#
#    The RENAME is the point. A nullable column called `monthly_event_limit` that
#    is usually NULL and is not the account's monthly event limit is a trap for
#    the next reader; `event_limit_override` cannot be misread, and it leaves
#    `Account#event_limit` free to be the resolved answer.
#
#    Rows still holding the old default are nulled, so they inherit their plan's
#    quota (100,000 on free) instead of staying frozen at 10,000 forever. A row
#    holding anything else was set deliberately and is left as the override it
#    already was.
#
# 3. `site_limit_override` JOINS IT, for the same reason. Having an override for
#    one limit and not the other is how you end up editing plan constants to
#    accommodate a single customer.
#
# 4. SUBSCRIPTION STATE GETS COLUMNS. `plan` alone cannot answer "is this
#    subscription in good standing", which is a different question: a past_due
#    account is still on `pro` while its card fails, and an account that has
#    cancelled stays on `pro` until the period it already paid for runs out.
#    Without somewhere to put Stripe's own status, the only way to answer either
#    is to call the Stripe API from a page render.
class AddBillingToAccounts < ActiveRecord::Migration[8.1]
  # The keys that were never sold. A constant so `down` can say what it cannot
  # restore.
  RETIRED_PLANS = %w[starter growth business].freeze
  PLANS = %w[free pro self_hosted].freeze

  # The old column default, which is the value meaning "nobody ever chose this"
  # and therefore the only one safe to convert into an inherited quota.
  OLD_DEFAULT_EVENT_LIMIT = 10_000

  def up
    execute <<~SQL.squish
      UPDATE accounts SET plan = 'pro'
      WHERE plan IN (#{RETIRED_PLANS.map { |p| "'#{p}'" }.join(', ')})
    SQL

    rename_column :accounts, :monthly_event_limit, :event_limit_override
    change_column_null :accounts, :event_limit_override, true
    change_column_default :accounts, :event_limit_override, from: OLD_DEFAULT_EVENT_LIMIT, to: nil
    execute "UPDATE accounts SET event_limit_override = NULL WHERE event_limit_override = #{OLD_DEFAULT_EVENT_LIMIT}"

    add_column :accounts, :site_limit_override, :integer

    # Stripe's own subscription status, stored verbatim rather than mapped into
    # something of ours. The vocabulary (active, trialing, past_due, canceled,
    # unpaid, incomplete, incomplete_expired, paused) is Stripe's and will grow;
    # translating it here would mean an unknown future status arriving as `nil`
    # and reading as "no subscription at all".
    add_column :accounts, :subscription_status, :string

    # When the period the customer has already paid for runs out. This is what
    # makes "cancel at period end" work without a scheduled job: access is decided
    # by comparing now against this, not by waiting for a webhook to arrive on
    # time.
    add_column :accounts, :current_period_ends_at, :datetime

    add_column :accounts, :cancel_at_period_end, :boolean, null: false, default: false

    # A Stripe subscription belongs to exactly one account. Partial, because most
    # rows never have one — every free account and every self-hosted install.
    add_index :accounts, :stripe_subscription_id, unique: true,
              where: "stripe_subscription_id IS NOT NULL"

    add_check_constraint :accounts,
                         "plan IN (#{PLANS.map { |p| "'#{p}'" }.join(', ')})",
                         name: "accounts_plan_check"

    # NULL is the normal case and means "use the plan's quota". A negative
    # override would silently refuse every event.
    add_check_constraint :accounts,
                         "event_limit_override IS NULL OR event_limit_override >= 0",
                         name: "accounts_event_limit_override_check"

    # At least one site: an account that cannot hold a site cannot do anything at
    # all, and there is no reason to be able to express that.
    add_check_constraint :accounts,
                         "site_limit_override IS NULL OR site_limit_override >= 1",
                         name: "accounts_site_limit_override_check"
  end

  def down
    remove_check_constraint :accounts, name: "accounts_site_limit_override_check"
    remove_check_constraint :accounts, name: "accounts_event_limit_override_check"
    remove_check_constraint :accounts, name: "accounts_plan_check"

    remove_index :accounts, :stripe_subscription_id

    remove_column :accounts, :cancel_at_period_end
    remove_column :accounts, :current_period_ends_at
    remove_column :accounts, :subscription_status
    remove_column :accounts, :site_limit_override

    # `pro` is not a key the pre-migration model accepts, so leaving it behind would
    # make every paying account fail its own `plan` validation the moment the old
    # code loaded — every save on those rows refused, for a reason nothing explains.
    # Mapped to `growth`, the nearest of the three retired keys. This does not
    # restore which accounts were originally on which: that information is gone the
    # moment `up` runs, and a rollback is an abandonment of the feature rather than a
    # round trip.
    execute "UPDATE accounts SET plan = 'growth' WHERE plan = 'pro'"

    # Rolling back also cannot tell an inherited quota from one deliberately set to
    # 10,000. The old default is restored so the column is valid again.
    execute "UPDATE accounts SET event_limit_override = #{OLD_DEFAULT_EVENT_LIMIT} WHERE event_limit_override IS NULL"
    change_column_default :accounts, :event_limit_override, from: nil, to: OLD_DEFAULT_EVENT_LIMIT
    change_column_null :accounts, :event_limit_override, false
    rename_column :accounts, :event_limit_override, :monthly_event_limit
  end
end
