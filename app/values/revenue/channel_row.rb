module Revenue
  # One line of the attribution table: a channel, its traffic, and what it was
  # worth.
  #
  # A Dry::Struct rather than the AttributionRollup record it is built from,
  # because a row of this report is a SUM ACROSS DAYS and no single database row
  # holds it — and because the two derived figures below are arithmetic that has a
  # right answer and belongs next to the numbers rather than in a view.
  class ChannelRow < Dry::Struct
    attribute :source, Types::Strict::String
    attribute :medium, Types::Strict::String
    attribute :campaign, Types::Strict::String

    attribute :visitors, Types::Strict::Integer
    attribute :signups, Types::Strict::Integer
    attribute :trials, Types::Strict::Integer
    attribute :conversions, Types::Strict::Integer

    attribute :new_mrr_cents, Types::Strict::Integer
    attribute :expansion_mrr_cents, Types::Strict::Integer
    attribute :contraction_mrr_cents, Types::Strict::Integer
    attribute :churned_mrr_cents, Types::Strict::Integer
    attribute :net_mrr_cents, Types::Strict::Integer

    attribute :lifetime_revenue_cents, Types::Strict::Integer
    attribute :unconverted_events, Types::Strict::Integer

    def channel_label
      parts = [source]
      parts << medium unless medium == Channel::NONE
      parts << campaign unless campaign == Channel::NONE
      parts.join(" / ")
    end

    # Visitors who became paying customers, as a fraction.
    #
    # RETURNS nil RATHER THAN 0.0 WHEN THERE ARE NO VISITORS, and the distinction
    # is the honest one. A channel with 4 conversions and 0 recorded visitors is
    # not a 0% conversion rate — it is a channel whose traffic we did not see,
    # which happens constantly and legitimately: customers imported by the Stripe
    # backfill, anyone who signed up before the tracker was installed, and anyone
    # behind an ad blocker. Rendering that as 0% puts the worst possible number
    # against the channel with the money.
    def conversion_rate
      return nil if visitors.zero?

      conversions / visitors.to_f
    end

    # Revenue per visitor — the number that actually ranks channels against each
    # other, because it is the only one that accounts for both halves.
    def value_per_visitor_cents
      return nil if visitors.zero?

      lifetime_revenue_cents / visitors
    end

    def any_revenue? = !net_mrr_cents.zero? || !lifetime_revenue_cents.zero?
  end
end
