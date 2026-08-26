# Every campaign on every site you can read, with what it has done lately.
#
# A LIST, NOT A BUILDER. This screen used to be the builder as well, with the
# site as a `?site=` parameter and a switcher on it; the builder moved under the
# site it builds for (Sites::CampaignsController) and what stayed behind is the
# thing the application header is actually useful for — the answer to "what is
# running, and is any of it working", across an account whose campaigns are
# otherwise one site's dashboard at a time.
#
# WHAT IT MAY NOT DO. Nothing here is rolled up across sites, and there is no
# grand total on the page. Analytics::Period resolves a preset against ONE
# site's timezone, so "last 30 days" across sites in Berlin, Kolkata and UTC is
# three different windows, and adding them would be the sites index's period
# switcher — the one this codebase refuses to build — wearing a different hat.
# A preset is resolved once per site and each row is measured in its own site's
# window, which is the identical figure that site's own screen shows. That is
# also why the rows are grouped BY SITE rather than mixed into one table: the
# window is a property of the group, so it is stated on the group.
class CampaignsController < ApplicationController
  # A period is a preset here and never a custom range. A custom range is two
  # absolute dates, which is a coherent thing to ask ONE site for and an
  # ambiguous thing to ask several — `Period#custom_range` resolves those dates
  # in the site's own zone, so the boundaries would silently differ per row with
  # nothing on screen admitting it. The presets say "last 30 days" and mean it
  # per site, which is a claim the page can make honestly.
  #
  # There is no "all time" either, which the sites index does offer: that one
  # reads events_by_hour, and the aggregates carry no UTM columns (§8), so an
  # unbounded campaign total would be a scan of every chunk on the instance.
  PERIODS = %w[7d 30d 90d 12mo].freeze

  def index
    # `policy_scope` twice, on two models, because the page needs both and each
    # answers a different question: which sites this viewer may see at all, and
    # which campaigns. The two agree — both resolve through the account — and
    # the sites list is what turns an empty account into an explanation rather
    # than a blank page.
    @sites = policy_scope(Site).ordered.to_a
    @campaigns = policy_scope(Campaign).includes(:site, :campaign_links).to_a

    @period_key = requested_period_key
    @periods = @sites.index_with { |site| Analytics::Period.parse(@period_key, site: site) }
    @performance = Analytics::CampaignPerformance.call(periods: periods_worth_querying).value!

    @sections = sections
  end

  private

  def requested_period_key
    PERIODS.include?(params[:period]) ? params[:period] : Analytics::Period::DEFAULT
  end

  # Only sites that actually have a campaign. Every site in the hash is another
  # window OR'd into the WHERE clause and another slice of the events
  # hypertable, and a site with nothing built for it has no row to hang the
  # answer off anyway.
  def periods_worth_querying
    with_campaigns = @campaigns.map(&:site_id).to_set

    @periods.select { |site, _| with_campaigns.include?(site.id) }
  end

  # One group per site that has campaigns, each already carrying its own window
  # and its own rows, so the view never pairs a campaign with a figure itself
  # and cannot pair it two ways in two places.
  Section = Struct.new(:site, :period, :rows, keyword_init: true)

  # A campaign and its figure. `total` is nil both when nothing arrived and when
  # what arrived fell under the site's k-anonymity threshold — see
  # Analytics::CampaignPerformance for why the two are deliberately
  # indistinguishable here.
  Row = Struct.new(:campaign, :total, keyword_init: true)

  def sections
    @campaigns.group_by(&:site).sort_by { |site, _| site.domain }.map do |site, campaigns|
      Section.new(site: site, period: @periods.fetch(site), rows: rows_for(campaigns))
    end
  end

  # BUSIEST FIRST, WITHIN A SITE AND NEVER ACROSS ONE. Ordering by visitors is
  # not the same sin as adding them up — a comparison inside one site's window
  # is exactly the comparison that site's own screen makes — but it stops at the
  # group boundary, which is the other reason the sections are per site.
  # Campaigns with no figure sort last and then by recency: a campaign built
  # this morning has no traffic yet and belongs above one from March that never
  # got any.
  def rows_for(campaigns)
    campaigns.map { |campaign| Row.new(campaign: campaign, total: @performance.for_campaign(campaign)) }
             .sort_by { |row| [row.total ? 0 : 1, -row.total&.visitors.to_i, -row.campaign.created_at.to_i] }
  end
end
