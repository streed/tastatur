# An expiry for the event-limit override, so a downgrade cannot retroactively
# spend an allowance the customer already paid for.
#
# THE BUG THIS FIXES. The monthly meter counts every event received in a UTC
# calendar month, and the plan decides the ceiling that count is measured against.
# Those two facts together mean a mid-month downgrade is retroactive: a Pro account
# that recorded 3,000,000 events and then cancels on the 20th is immediately
# measured against Free's 100,000, so every event for the remaining eleven days is
# refused. That contradicts two things we publish — "downgrading never deletes
# anything", and that the Free plan includes 100,000 events a month, of which such
# an account would get none in the month it downgraded.
#
# The fix is to grandfather the rest of the month: on a downgrade,
# Billing::SyncSubscription writes `event_limit_override = events_already_used +
# new_plan_allowance` and sets this column to the end of the month. The customer
# gets the full smaller allowance from the moment they downgrade, and next month
# the override expires and the plan's own number applies again.
#
# WHY NOT REBASE THE COUNTER INSTEAD, which is the obvious alternative: the counter
# is reconciled hourly from events_by_hour, and that reconciliation is deliberately
# one-way upward (see Billing::UsageMeter#repair). Writing the counter down would
# be undone within the hour by the repair reading the true stored total, so the
# adjustment has to live on the ceiling rather than on the count.
#
# It doubles as the honest way to grant a temporary bump in support: an override
# with an expiry cannot be forgotten about, which a permanent one can.
class AddEventLimitOverrideExpiry < ActiveRecord::Migration[8.1]
  def change
    add_column :accounts, :event_limit_override_until, :datetime

    # NULL means "no expiry", which is what a deliberate, permanent support grant
    # looks like. A date without an override would be meaningless rather than
    # harmful, but it would also be a lie about what is in force.
    add_check_constraint :accounts,
                         "event_limit_override_until IS NULL OR event_limit_override IS NOT NULL",
                         name: "accounts_event_limit_override_expiry_check"
  end
end
