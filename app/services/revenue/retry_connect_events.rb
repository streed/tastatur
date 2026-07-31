module Revenue
  # Re-applies Connect deliveries that were stored and never processed.
  #
  # WHY THIS EXISTS RATHER THAN SIDEKIQ RETRIES. ApplyConnectEventJob deliberately
  # does not raise: it records the failure on the row and returns, so a stuck
  # event is diagnosable from the database rather than only from a Sentry trace.
  # The cost of that choice is that nothing retries it, and this is the other half.
  #
  # It is also the better retry. Sidekiq would back off one job in isolation,
  # blind to the fact that four hundred others failed in the same minute for the
  # same reason — which is what a Stripe outage or an expired connection actually
  # looks like. Sweeping the backlog in event order means a customer's revenue is
  # rebuilt in the sequence it happened, which matters: applying a cancellation
  # before the subscription that it cancels leaves the row wrong.
  #
  # ORDERED BY `occurred_at`, NOT BY id. Stripe delivers out of order and the
  # sweep must not preserve that; the ordering guard on CustomerSubscription would
  # then discard the newer event as stale and the older one would win.
  class RetryConnectEvents < ApplicationService
    # A ceiling per run, so one site with a large backlog cannot occupy the
    # nightly window to the exclusion of everything else. The remainder is picked
    # up on the next pass.
    BATCH_SIZE = 500

    def initialize(limit: BATCH_SIZE)
      @limit = limit
    end

    def call
      events = ConnectEvent.retryable.ordered.limit(@limit).to_a
      return Success(attempted: 0, applied: 0) if events.empty?

      applied = events.count { |event| ApplyConnectEvent.call(connect_event: event).success? }

      # Logged at warn when anything is still stuck, because a persistent backlog
      # means a customer's revenue screen is quietly wrong — the single failure
      # mode of this feature that produces no error anywhere.
      if applied < events.length
        Rails.logger.warn("[tastatur] #{events.length - applied} connect events still unapplied after a retry sweep")
      end

      Success(attempted: events.length, applied: applied)
    end
  end
end
