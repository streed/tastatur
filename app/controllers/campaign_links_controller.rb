# One link under a campaign: the Discord post, the Facebook ad, the newsletter.
#
# Nested under the campaign because a link with no campaign has no tag, and a
# link with no tag cannot be matched to anything — the five UTM values are the
# join key, and `utm_campaign` is not a field on this form. It is copied down
# from the campaign on every save (see CampaignLink#adopt_campaign_tag), which
# is what guarantees that every link under one heading really does group
# together in the report.
class CampaignLinksController < ApplicationController
  include CampaignScreen

  before_action :set_campaign
  before_action :set_link, only: %i[edit update destroy]

  def create
    @link = @campaign.campaign_links.new(link_params)
    authorize @link

    if @link.save
      redirect_to campaigns_path(site: @campaign.site.public_token, created: @link.public_id),
                  notice: "Link added to #{@campaign.name}."
    else
      # Back into the screen with this link open under its own campaign, so the
      # error appears where the person was typing rather than at the top of a
      # page with four other campaigns on it.
      load_screen(open_link: @link)
      render "campaigns/index", status: :unprocessable_entity
    end
  end

  def edit
    authorize @link
  end

  def update
    authorize @link

    if @link.update(link_params)
      redirect_to campaigns_path(site: @campaign.site.public_token), notice: "Link updated."
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    authorize @link
    @link.destroy!

    redirect_to campaigns_path(site: @campaign.site.public_token),
                notice: "Link deleted. Its traffic is still counted."
  end

  private

  # Through policy_scope, so a campaign belonging to another account raises
  # RecordNotFound before any authorization question is asked — the same tenant
  # boundary SiteScoped draws for everything under /sites.
  def set_campaign
    @campaign = policy_scope(Campaign).find_by_public_id!(params[:campaign_public_id])
  end

  def set_link
    @link = @campaign.campaign_links.find_by_public_id!(params[:public_id])
  end

  # No `utm_campaign`. It is not the form's to set: the campaign owns it, and a
  # permitted key here would be a second way to answer a question that must have
  # exactly one answer for the grouping to mean anything.
  def link_params
    params.expect(campaign_link: %i[name destination_url utm_source utm_medium utm_term utm_content])
  end
end
