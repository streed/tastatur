module Billing
  # What an account has used this month, against what it is allowed.
  #
  # Everything the billing screen and the warning emails need, computed once, so
  # neither has to re-derive "is this account over its limit" and reach a different
  # answer. A Dry::Struct rather than a hash because it crosses a service boundary
  # (Billing::MeasureUsage returns it) and because `percent_used` and `refused`
  # are arithmetic that belongs next to the numbers it operates on.
  class UsageSnapshot < Dry::Struct
    Quota = Types::Strict::Integer | Types::Strict::Float

    attribute :plan, Types.Instance(Billing::Plan)

    # Events received this month, INCLUDING any refused for being over the limit.
    # See Billing::UsageMeter for why the meter counts receipts rather than writes.
    attribute :events_used, Types::Strict::Integer
    attribute :event_limit, Quota

    attribute :events_used_last_month, Types::Strict::Integer

    attribute :sites_used, Types::Strict::Integer
    attribute :site_limit, Quota

    attribute :period_start, Types::Strict::Time
    attribute :period_end, Types::Strict::Time

    # The point at which we tell somebody, rather than waiting for them to notice
    # their numbers have stopped moving. Shared by the screen and the email so the
    # banner and the message cannot disagree about what counts as close.
    WARNING_THRESHOLD = 0.8

    def unlimited_events? = event_limit == Billing::Plan::UNLIMITED
    def unlimited_sites? = site_limit == Billing::Plan::UNLIMITED

    # 0.0..1.0+, and it can exceed 1.0 on purpose — an account 40% past its cap
    # should read as 140%, not as a bar that stops looking worse once it is full.
    def fraction_used
      return 0.0 if unlimited_events? || event_limit.zero?

      events_used / event_limit.to_f
    end

    def percent_used
      (fraction_used * 100).round
    end

    # Clamped, for a progress bar's width. The unclamped figure is what gets
    # printed next to it.
    def bar_percent
      [percent_used, 100].min
    end

    def exceeded?
      return false if unlimited_events?

      events_used > event_limit
    end

    def approaching_limit?
      !unlimited_events? && !exceeded? && fraction_used >= WARNING_THRESHOLD
    end

    # How many events were NOT recorded because the account is over its plan.
    # Derived rather than counted separately: the meter counts everything received
    # and the limit is where recording stopped, so the difference is exact and
    # there is no second counter to drift.
    def events_refused
      return 0 unless exceeded?

      events_used - event_limit
    end

    def events_remaining
      return Billing::Plan::UNLIMITED if unlimited_events?

      [event_limit - events_used, 0].max
    end

    def sites_remaining
      return Billing::Plan::UNLIMITED if unlimited_sites?

      [site_limit - sites_used, 0].max
    end

    def at_site_limit?
      !unlimited_sites? && sites_used >= site_limit
    end

    # An account that kept sites through a downgrade. Not an error and never
    # resolved by deleting anything — see Site#account_within_site_limit.
    def over_site_limit?
      !unlimited_sites? && sites_used > site_limit
    end

    def days_until_reset
      ((period_end - Time.current) / 1.day).ceil
    end
  end
end
