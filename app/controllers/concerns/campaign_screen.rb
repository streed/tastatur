# Everything the site's campaigns screen needs, shared by the two controllers
# that can render it.
#
# WHY A CONCERN. Sites::CampaignsController#create and
# Sites::CampaignLinksController#create both re-render the index on a validation
# failure, with the offending record left open as the form. Each would otherwise
# carry its own copy of the period, the report and the pairing of saved links
# against the rows that matched them — three things that must agree exactly, in
# two places, for the screen to say the same thing whichever way you arrived at
# it.
#
# THE SITE COMES FROM SiteScoped, which is the whole point of the screen living
# under /sites/:site_public_token. It used to resolve a `?site=` parameter here
# against a policy_scope of its own — a second implementation of the tenant
# boundary every other screen gets from one place, and the kind that drifts.
module CampaignScreen
  extend ActiveSupport::Concern

  included do
    include SiteScoped

    # The pickers read whatever the report and the saved links already hold, so
    # every template that renders a form gets them without a query of its own —
    # and, like OffersKnownValues, only when a template actually asks. A create
    # that redirects pays for nothing.
    helper_method :campaign_values
  end

  private

  def load_screen(form: nil, open_link: nil)
    @campaign = form || @site.campaigns.new

    # A campaign with nowhere to type a link is a name and a Save button. The
    # first row is built here rather than in the <template>, which is a
    # prototype and cannot supply it — the same reason the funnel form builds a
    # step's first condition server-side.
    @campaign.campaign_links.build(destination_url: default_destination) if @campaign.campaign_links.empty?
    @open_link = open_link

    period_for_report

    # Each campaign paired with its own figure and with its links already
    # paired against the rows that matched them, so the view never does a
    # lookup itself and cannot pair them two ways in two places.
    @sections = campaigns.map do |campaign|
      Section.new(
        campaign: campaign,
        total: report.for_campaign(campaign),
        links: campaign.campaign_links.ordered.map { |link| [link, report.for_link(link)] }
      )
    end

    # Rows that arrived from links built somewhere else — an ad platform, a mail
    # tool, a colleague typing one by hand. This is the half of the screen that
    # finds the typo: `newsletter` sitting beside `Newsletter`, one of them
    # yours.
    saved = campaigns.flat_map { |campaign| campaign.campaign_links.map(&:utm_key) }.to_set
    @unsaved = report.rows.reject { |row| saved.include?(row.key) }
  end

  # A campaign, what it did as a whole, and what each of its links did. A
  # Struct rather than a hash so the view cannot ask for a key that is not
  # there and render nothing.
  Section = Struct.new(:campaign, :total, :links, keyword_init: true) do
    def any_links? = links.any?
  end

  def campaigns
    @campaigns ||= @site.campaigns.includes(:campaign_links).ordered.to_a
  end

  def report
    @report ||= Analytics::CampaignReport.call(site: @site, period: period_for_report).value!
  end

  def period_for_report
    @period ||= Analytics::Period.parse(params[:period], site: @site)
  end

  def campaign_values
    @campaign_values ||= Analytics::CampaignValues.new(links: all_links, report: report)
  end

  def all_links
    @all_links ||= campaigns.flat_map(&:campaign_links)
  end

  def default_destination
    "https://#{@site.domain}/"
  end
end
