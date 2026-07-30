module Billing
  # Assembles one account's usage picture for the billing screen and the warning
  # emails.
  #
  # Reads the METER, not the database, for the event count — deliberately. The
  # meter is what enforcement consults on the ingest path, so showing anything
  # else would mean the number a customer is shown and the number that decides
  # whether their events are recorded could differ. Billing::ReconcileUsage keeps
  # the meter honest against the aggregate every hour; this service's job is to
  # report the figure that is actually in force.
  class MeasureUsage < ApplicationService
    def initialize(account:, at: Time.current)
      @account = account
      @at = at
    end

    def call
      period_start, period_end = UsageMeter.period_bounds(@at)

      Success(
        UsageSnapshot.new(
          plan: @account.billing_plan,
          events_used: UsageMeter.used(@account.id, at: @at),
          event_limit: @account.event_limit,
          events_used_last_month: UsageMeter.used(@account.id, at: @at - 1.month),
          # `size` rather than `count`, so the preloaded association that
          # Billing::ReconcileUsage sets up is used instead of one COUNT query per
          # account on an hourly sweep. Identical for a single page load.
          sites_used: @account.sites.size,
          site_limit: @account.site_limit,
          period_start: period_start,
          period_end: period_end
        )
      )
    end
  end
end
