module Revenue
  # Normalises any Stripe billing interval to monthly recurring revenue, in cents.
  #
  # WHY THIS IS ARITHMETIC AND NOT A ONE-LINER. An annual plan at $480 is $40 of
  # MRR, not $480 — and a dashboard that shows the second one turns every January
  # into a growth chart shaped like a cliff, followed by eleven months of apparent
  # collapse. Getting this wrong is the single most common error in
  # revenue reporting and it is invisible until somebody's board asks about the
  # cliff.
  #
  # EVERY RESULT IS INTEGER CENTS AND THERE IS NO FLOAT ANYWHERE. Ruby's `/` on
  # integers truncates, which is the behaviour we want — see the rounding note
  # below — but it means the order of operations matters: `(cents * 52) / 12`
  # keeps three significant figures that `(cents / 12) * 52` throws away.
  module MonthlyValue
    # Weeks and days per month, as Stripe itself reasons about them. 52/12 and
    # 365/12 rather than 4 and 30, because a "weekly" plan bills 52 times a year
    # and not 48, and the difference is 8% of the number.
    WEEKS_PER_YEAR = 52
    DAYS_PER_YEAR = 365
    MONTHS_PER_YEAR = 12

    module_function

    # `item` is a Stripe subscription item — a hash or a Stripe object; both
    # respond to `[]`, which is what this uses throughout for the reason
    # Billing::SyncSubscription documents: bracket access is nil-safe for a field
    # the pinned API version has moved, and a reader method raises NoMethodError.
    #
    # Returns 0 for anything that is not recurring. A one-off line item on a
    # subscription invoice (a setup fee, say) is real revenue and is recorded as a
    # `one_time` RevenueEvent elsewhere — but it is not MRR, and adding it here
    # would make it recur in the report forever when it happened exactly once.
    def for_item(item)
      price = item&.[](:price)
      recurring = price&.[](:recurring)
      return 0 if recurring.nil?

      unit = price[:unit_amount].to_i
      quantity = (item[:quantity] || 1).to_i
      per_period = unit * quantity

      monthly(per_period, recurring[:interval].to_s, (recurring[:interval_count] || 1).to_i)
    end

    # The whole subscription: every recurring item, summed.
    #
    # SUMMED ACROSS ITEMS rather than reading the first one. A subscription with a
    # base plan and a metered add-on is two items, and the single-item version
    # under-reports it by the entire value of the add-on — silently, and only for
    # the customers paying the most.
    def for_subscription(subscription)
      items = subscription&.[](:items)
      data = items && items[:data]

      Array(data).sum { |item| for_item(item) }
    end

    # ROUNDING IS DOWN, BY TRUNCATION, and it is deliberate rather than inherited
    # from Ruby's `/`.
    #
    # A monthly figure derived from a yearly price does not divide evenly in the
    # general case — $100/year is 833.33 cents a month. Something has to absorb
    # the third of a cent, and rounding down means the reported MRR is never
    # higher than what is actually being collected. A revenue number that
    # overstates by a cent per customer per month is a number somebody eventually
    # has to reconcile against a bank statement and cannot.
    #
    # The residual is bounded and tiny: at most one cent per subscription per
    # month, always in the conservative direction.
    def monthly(per_period_cents, interval, interval_count)
      count = [interval_count, 1].max

      case interval
      when "month" then per_period_cents / count
      when "year"  then per_period_cents / (MONTHS_PER_YEAR * count)
      when "week"  then (per_period_cents * WEEKS_PER_YEAR) / (MONTHS_PER_YEAR * count)
      when "day"   then (per_period_cents * DAYS_PER_YEAR) / (MONTHS_PER_YEAR * count)
      else
        # An interval Stripe has added since this was written. Loud rather than
        # silent: returning 0 would quietly drop a paying customer out of every
        # revenue figure, which is indistinguishable from them not existing.
        Rails.logger.error("[tastatur] unknown Stripe billing interval #{interval.inspect} — treated as 0 MRR")
        Sentry.capture_message("Unknown Stripe billing interval: #{interval}") if defined?(Sentry)
        0
      end
    end
  end
end
