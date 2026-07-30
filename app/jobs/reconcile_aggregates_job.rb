class ReconcileAggregatesJob < ApplicationJob
  # An erasure is not finished until this has run: the raw rows are gone but the
  # aggregates still hold visitor hashes derived from them. Minutes is the right
  # promise — a refresh over a wide window is genuinely slow, and "we deleted it
  # within five minutes" is a defensible answer where "within an hour" invites the
  # question of what was still being reported in the meantime.
  queue_as :within_5_minutes

  # Enqueued whenever historical raw events are deleted, by Sites::Delete or by
  # the nightly retention sweep. Without it, deleted events keep appearing in
  # reports forever, because the scheduled refresh policies only look back a few
  # days and an older invalidation is never processed.
  #
  # Retried, because a failure here means data a user asked to have erased is
  # still being reported.
  retry_on ActiveRecord::StatementInvalid, wait: :polynomially_longer, attempts: 5

  def perform(from, to)
    Analytics::ReconcileAggregates.call(from: from, to: to)
  end
end
