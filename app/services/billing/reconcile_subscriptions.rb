module Billing
  # Re-reads every known subscription from Stripe and applies what it finds.
  #
  # WHY THIS EXISTS WHEN THERE ARE WEBHOOKS. A webhook is a delivery attempt, not a
  # database. Stripe gives up retrying after three days; an endpoint that returns
  # non-2xx often enough gets disabled; a rotated signing secret rejects everything
  # until someone notices; a deploy can be mid-restart when an event lands. Each of
  # those loses a subscription change silently, and the symptom — an account on the
  # wrong plan — is invisible from the inside because nothing raised.
  #
  # So once a day the answer is asked for rather than waited for. It is the same
  # code path a webhook takes (Billing::SyncSubscription re-fetches either way), so
  # there is no second implementation to drift.
  class ReconcileSubscriptions < ApplicationService
    Report = Struct.new(:checked, :changed, :failed, :receipts_pruned, keyword_init: true)

    # Fields whose change is worth logging. A period end moving forward every month
    # is not news; a plan or status change is.
    WATCHED = %w[plan subscription_status cancel_at_period_end].freeze

    def call
      return Success(empty_report) unless Tastatur.billing_enabled?

      checked = 0
      changed = 0
      failed = 0

      # KEYED ON THE CUSTOMER, NOT THE SUBSCRIPTION.
      #
      # It used to sweep `where.not(stripe_subscription_id: nil)`, and that column is
      # written in exactly one place — by a successful sync. So the only accounts the
      # backstop could see were the accounts whose webhooks had already arrived: it
      # skipped precisely the failure it exists for. An account whose every delivery
      # was refused (a rotated signing secret, an endpoint Stripe disabled) has a
      # customer id from checkout and no subscription id, and stayed on the free plan
      # while being billed monthly, with nothing raising anywhere.
      #
      # Sweeping by customer means SyncSubscription's discovery runs for those rows
      # and finds the subscription at Stripe.
      Account.where.not(stripe_customer_id: nil).find_each do |account|
        checked += 1
        before = account.attributes.slice(*WATCHED)

        case SyncSubscription.call(account: account)
        in Success(_)
          after = account.attributes.slice(*WATCHED)
          next if before == after

          changed += 1
          Rails.logger.warn(
            "[tastatur] reconciliation corrected account #{account.id}: #{before.inspect} -> #{after.inspect}. " \
            "A webhook was missed."
          )
        in Failure(:no_subscription)
          # A customer with no subscription at all: somebody who started checkout and
          # abandoned it, or cancelled long ago. Expected, and not a failure — it is
          # the normal state for a good number of rows now that the sweep is keyed on
          # the customer.
          next
        in Failure(_)
          # SyncSubscription has already logged and reported the reason. Counting it
          # here keeps one failing account from being read as the whole sweep having
          # worked.
          failed += 1
        end
      end

      # Webhook receipts exist only to turn Stripe's retries into no-ops, and Stripe
      # stops retrying after three days. Pruned here rather than by a job of its own
      # because this is the job that owns webhook reliability, and a second cron
      # entry for one DELETE is a second thing that can silently stop running.
      pruned = ProcessedWebhookEvent.prune!

      Rails.logger.info(
        "[tastatur] subscriptions: checked #{checked}, corrected #{changed}, failed #{failed}, " \
        "pruned #{pruned} webhook receipts"
      )

      Success(Report.new(checked: checked, changed: changed, failed: failed, receipts_pruned: pruned))
    end

    private

    def empty_report
      Report.new(checked: 0, changed: 0, failed: 0, receipts_pruned: 0)
    end
  end
end
