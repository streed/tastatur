module Sites
  # Build a tagged link, and see what the ones you already built did.
  #
  # Both halves on one screen. A builder on its own is a string concatenator
  # somebody could do in a text editor; what makes it worth being in the product
  # is that the value it writes is the value the report matches on, and that the
  # two can therefore be kept spelling-identical by construction rather than by
  # care. See CampaignLink.
  class CampaignsController < ApplicationController
    include SiteScoped

    before_action :set_campaign_link, only: %i[edit update destroy]

    # The pickers read whatever the report and the saved links already hold, so
    # every template that renders the form gets them without a query of its own
    # — and, like OffersKnownValues, only when a template actually asks. A
    # create that redirects pays for nothing.
    helper_method :campaign_values

    def index
      load_index
    end

    def create
      @campaign_link = @site.campaign_links.new(campaign_link_params)
      authorize @campaign_link

      if @campaign_link.save
        redirect_to site_campaigns_path(@site, created: @campaign_link.public_id),
                    notice: "Campaign link created."
      else
        load_index(form: @campaign_link)
        render :index, status: :unprocessable_entity
      end
    end

    def edit
      authorize @campaign_link
    end

    def update
      authorize @campaign_link

      if @campaign_link.update(campaign_link_params)
        redirect_to site_campaigns_path(@site), notice: "Campaign link updated."
      else
        render :edit, status: :unprocessable_entity
      end
    end

    # The link stops being listed; nothing it measured is affected. The events
    # keep their UTM values, so its row simply moves into "not built here" —
    # which the empty state says, because "delete" next to a table of numbers
    # reads like deleting the numbers.
    def destroy
      authorize @campaign_link
      @campaign_link.destroy!
      redirect_to site_campaigns_path(@site), notice: "Campaign link deleted. Its traffic is still counted."
    end

    private

    def load_index(form: nil)
      @campaign_link = form || @site.campaign_links.new(destination_url: default_destination)

      # No `authorize` here: index proves tenant isolation by scoping instead
      # (see ApplicationController), and `links` below is the policy_scope call
      # that verify_policy_scoped checks for. Whether the form is rendered at all
      # is a `create?` question the view asks, the way the share screen does.
      period_for_report

      # `measured` pairs each saved link with the row it matched, so the view
      # never does the lookup itself and cannot pair them two different ways in
      # two places.
      @measured = links.map { |link| [link, report.for_link(link)] }

      # Rows that arrived from links built somewhere else — an ad platform, a
      # mail tool, a colleague typing one by hand. This is the half of the
      # screen that finds the typo: `newsletter` sitting beside `Newsletter`,
      # one of them yours.
      saved = links.map(&:utm_key).to_set
      @unsaved = report.rows.reject { |row| saved.include?(row.key) }
    end

    def links
      @links ||= policy_scope(CampaignLink).where(site: @site).ordered.to_a
    end

    def report
      @report ||= Analytics::CampaignReport.call(site: @site, period: period_for_report).value!
    end

    def period_for_report
      @period ||= Analytics::Period.parse(params[:period], site: @site)
    end

    def campaign_values
      @campaign_values ||= Analytics::CampaignValues.new(links: links, report: report)
    end

    def default_destination
      "https://#{@site.domain}/"
    end

    def set_campaign_link
      @campaign_link = @site.campaign_links.find_by_public_id!(params[:public_id])
    end

    def campaign_link_params
      params.expect(campaign_link: %i[name destination_url utm_source utm_medium utm_campaign
                                      utm_term utm_content])
    end
  end
end
