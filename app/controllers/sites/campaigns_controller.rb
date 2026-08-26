module Sites
  # Build a tagged link for this site, and see what the ones you already built
  # did.
  #
  # A CAMPAIGN IS A NAME AND A TAG; the links under it are how it was distributed
  # — the Discord post, the Facebook ad, the newsletter. That grouping is the
  # point of the screen: the numbers people actually want are "what did the launch
  # do" and "which channel carried it", and before this existed the product could
  # answer only the second, one flat row per link.
  #
  # NESTED UNDER THE SITE, beside goals and funnels. It spent a while at the top
  # level with a `?site=` parameter and a switcher of its own, which put the
  # builder one click from anywhere and everything else about the campaign two —
  # reading what a campaign did meant choosing the site a second time on the way
  # back to its dashboard. A campaign is a property of a site (its tag is unique
  # per site; its links are validated against that site's hostnames), so it is
  # addressed like one. The top-level CampaignsController is now a list across
  # every site, and each of its rows arrives here.
  class CampaignsController < ApplicationController
    include CampaignScreen

    before_action :set_campaign, only: %i[edit update destroy]

    def index
      load_screen
    end

    def create
      @campaign = @site.campaigns.new(campaign_params)
      authorize @campaign

      if @campaign.save
        redirect_to site_campaigns_path(@site, created: @campaign.public_id),
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
        redirect_to site_campaigns_path(@site), notice: "Campaign updated."
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
      @campaign.destroy!

      redirect_to site_campaigns_path(@site),
                  notice: "Campaign deleted. Its traffic is still counted."
    end

    private

    # Through the site, which SiteScoped already resolved through policy_scope —
    # so a campaign belonging to another account raises RecordNotFound before any
    # authorization question is asked.
    def set_campaign
      @campaign = @site.campaigns.find_by_public_id!(params[:public_id])
    end

    def campaign_params
      params.expect(campaign: [
        :name, :utm_campaign,
        { campaign_links_attributes: [%i[id name destination_url utm_source utm_medium
                                         utm_term utm_content _destroy]] }
      ])
    end
  end
end
