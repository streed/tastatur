class ReconcileSubscriptionsJob < ApplicationJob
  # Nightly bulk work, and nothing is waiting on it. Webhooks are what keep
  # subscription state current; this is the backstop for the events they miss —
  # a delivery that failed for three days, an endpoint that was disabled, a secret
  # rotated at the wrong moment. If it runs an hour late, an account is on the
  # wrong plan for an hour longer, which is the cost of a backstop rather than a
  # failure of one.
  queue_as :within_1_hour

  def perform
    Billing::ReconcileSubscriptions.call
  end
end
