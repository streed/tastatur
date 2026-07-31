# Re-applies Stripe Connect deliveries that failed on their first attempt.
#
# `within_5_minutes`, the same tier as the other reconciliation sweeps, and for
# the reason that tier exists: this is not interactive, but a backlog here means a
# customer's revenue figures are silently wrong, and "silently wrong" is measured
# in minutes rather than hours before somebody makes a decision on it.
class RetryConnectEventsJob < ApplicationJob
  queue_as :within_5_minutes

  def perform
    Revenue::RetryConnectEvents.call
  end
end
