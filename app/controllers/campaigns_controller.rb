# Build a tagged link, and see what the ones you already built did.
#
# A CAMPAIGN IS A NAME AND A TAG; the links under it are how it was distributed
# — the Discord post, the Facebook ad, the newsletter. That grouping is the
# point of the screen: the numbers people actually want are "what did the launch
# do" and "which channel carried it", and before this existed the product could
# answer only the second, one flat row per link.
#
# TOP LEVEL rather than under /sites/:token, for the reason routes.rb gives: this
# is a job somebody arrives wanting to do. The site is a parameter, switched on
# the screen, and never a roll-up across sites — a preset period resolves against
# one site's timezone, so adding three sites' "last 30 days" together is three
# different windows in a trench coat.
class CampaignsController < ApplicationController
  include CampaignScreen

  before_action :set_campaign, only: %i[edit update destroy]

  def index
    # `sites` is the policy_scope call verify_policy_scoped checks for, and it
    # is also the switcher's options — one query doing both, so a site that
    # cannot be read cannot be switched to either.
    return render :no_sites, status: :ok if sites.empty?

    load_screen
  end

  def create
    @campaign = current_site.campaigns.new(campaign_params)
    authorize @campaign

    if @campaign.save
      redirect_to campaigns_path(site: current_site.public_token, created: @campaign.public_id),
                  notice: "Campaign created."
    else
      # The invalid campaign goes back into the screen as the open form, so the
      # links somebody typed alongside it are still there. Rebuilding a blank
      # one would throw away four filled-in rows to report one bad tag.
      load_screen(form: @campaign)
      render :index, status: :unprocessable_entity
    end
  end

  def edit
    authorize @campaign
  end

  def update
    authorize @campaign

    # Renaming the tag re-points every link under it: CampaignLink copies the
    # value on every save, so the links follow in one place rather than each
    # holding an opinion. What it does NOT do is move history — the events keep
    # the values they arrived with, which is what the form says out loud.
    if @campaign.update(campaign_params)
      redirect_to campaigns_path(site: @campaign.site.public_token),
                  notice: "Campaign updated."
    else
      render :edit, status: :unprocessable_entity
    end
  end

  # The campaign and its links stop being listed; nothing they measured is
  # affected. The events keep their UTM values, so the traffic simply moves into
  # "Campaigns not built here" — which the confirmation says, because "delete"
  # next to a table of numbers reads like deleting the numbers.
  def destroy
    authorize @campaign
    site = @campaign.site
    @campaign.destroy!

    redirect_to campaigns_path(site: site.public_token),
                notice: "Campaign deleted. Its traffic is still counted."
  end

  private

  def set_campaign
    @campaign = policy_scope(Campaign).find_by_public_id!(params[:public_id])
  end

  def campaign_params
    params.expect(campaign: [
      :name, :utm_campaign,
      { campaign_links_attributes: [%i[id name destination_url utm_source utm_medium
                                       utm_term utm_content _destroy]] }
    ])
  end
end
