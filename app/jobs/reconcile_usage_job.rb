class ReconcileUsageJob < ApplicationJob
  # Not the nightly tier, even though this is a sweep over every active account.
  #
  # What backs up here is the number that decides whether a customer's events are
  # recorded. The Redis counter enforcement reads can only drift downward — lost
  # increments mean quota given away — and the drift is invisible from the outside,
  # so a plan limit we publish quietly stops being the limit we apply. That is the
  # same class of problem as salt rotation stalling, which is what this tier is for.
  queue_as :within_5_minutes

  def perform
    Billing::ReconcileUsage.call
  end
end
