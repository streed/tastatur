# Interprets one stored Stripe Connect delivery.
#
# `within_30_seconds`, the measurement-pipeline tier, and the choice is
# deliberate. This is not transactional mail and nobody is watching a spinner, so
# it does not belong in `within_5_seconds`. But it is the revenue equivalent of
# FlushEventBufferJob: if it backs up, the attribution screen silently stops
# advancing while webhooks keep answering 200 — the exact failure mode
# config/sidekiq.yml describes for that tier, in the exact words.
class ApplyConnectEventJob < ApplicationJob
  queue_as :within_30_seconds

  # An event whose row has been deleted — the site was deleted between the
  # webhook and this job. Discard rather than retry forever.
  discard_on ActiveRecord::RecordNotFound

  def perform(connect_event_id)
    event = ConnectEvent.find(connect_event_id)

    # ApplyConnectEvent records its own failure on the row and returns a Failure
    # rather than raising, so a stuck event is diagnosable from the database
    # instead of only from Sentry. Retrying is Revenue::RetryConnectEvents' job,
    # which runs on a schedule and can see the whole backlog — Sidekiq's own retry
    # would hammer one row in isolation and could not tell a transient Stripe
    # outage from a permanently malformed payload.
    Revenue::ApplyConnectEvent.call(connect_event: event)
  end
end
