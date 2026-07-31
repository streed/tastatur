module Revenue
  # Converts an amount into the site's base currency, or admits that it cannot.
  #
  # WHAT THIS DOES TODAY, STATED PLAINLY: it converts same-currency amounts, and
  # returns nil for everything else. There is no foreign-exchange rate table in
  # this application yet.
  #
  # WHY nil RATHER THAN A GUESS. The two tempting shortcuts are both worse than
  # doing nothing. Treating an unconvertible €40 as $40 reports a number that is
  # wrong by however far the pair has moved and looks completely normal. Treating
  # it as $0 silently deletes real revenue from the report — and the customers it
  # deletes are exactly the international ones somebody is trying to decide
  # whether to keep selling to.
  #
  # So the amount is left unconverted, `revenue_events.normalized_cents` stays
  # NULL, `attribution_rollups.unconverted_events` counts it, and the screen says
  # so in words. A report that admits its own gap is worth more than one that
  # rounds the gap into the total.
  #
  # ADDING FX LATER IS A ONE-METHOD CHANGE. `rate_for` is the seam: give it a
  # rates table and everything above it — the ledger column, the rollup counter,
  # the wording on the screen — starts working with no other edit. That is why
  # the plumbing exists now rather than being deferred with it.
  module Normalize
    module_function

    # Returns the amount in `base_currency`, or nil when no rate is available.
    def call(amount_cents:, from:, to:)
      return nil if amount_cents.nil?

      rate = rate_for(from: from.to_s.upcase, to: to.to_s.upcase)
      return nil if rate.nil?

      (amount_cents * rate).round
    end

    # 1.0 for a currency against itself, nil otherwise.
    #
    # The identity case is not a degenerate placeholder — it is the overwhelmingly
    # common one. A business whose Stripe account charges in one currency and
    # whose base currency is that currency has every row converted correctly, and
    # never sees the unconverted notice at all.
    def rate_for(from:, to:)
      return 1.0 if from == to

      nil
    end
  end
end
