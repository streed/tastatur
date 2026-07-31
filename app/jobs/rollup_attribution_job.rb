# Recomputes the attribution rollups.
#
# `within_1_hour` — the nightly-bulk tier. Nothing breaks if this is late by an
# hour; the screen shows yesterday's figures and says when it last updated
# (Revenue::AttributionReport#stale_since exists for exactly that).
#
# RE-DOES YESTERDAY AS WELL AS TODAY, and the overlap is the point. A day
# computed while events were still arriving is half-counted, and a rollup that
# only ever moved forward would leave it that way permanently. Recomputing is
# cheap and converges, so the boundary is re-crossed every run rather than being
# reasoned about.
#
# The window is deliberately wider than one day: late-arriving Stripe webhooks are
# routine (Stripe retries for three days), and a payment delivered on Thursday for
# a Tuesday invoice belongs on Tuesday's row. Three days covers Stripe's own retry
# window, which is the thing that actually determines how late a fact can be.
class RollupAttributionJob < ApplicationJob
  queue_as :within_1_hour

  LOOKBACK_DAYS = 3

  # A specific site, or every site with something to roll up.
  def perform(site_id = nil)
    sites = site_id ? Site.where(id: site_id) : sites_with_revenue

    sites.find_each do |site|
      today = Time.current.in_time_zone(site.timezone).to_date

      Revenue::RollupAttribution.call(site: site, from: today - LOOKBACK_DAYS, to: today)
    end
  end

  private

  # SKIPS SITES THAT HAVE NEVER CONNECTED STRIPE, because the rollup is four
  # queries per day per site and three of them would return nothing at all. On an
  # instance with a thousand traffic-only sites that is twelve thousand pointless
  # queries a night — enough to make the nightly window a thing somebody has to
  # think about, for no rows.
  #
  # A site that connects Stripe today gets its history rolled up by
  # BackfillStripeJob, so nothing is missed by starting from the connection.
  def sites_with_revenue
    Site.where(id: StripeConnection.live.select(:site_id))
        .or(Site.where(id: Customer.select(:site_id)))
  end
end
