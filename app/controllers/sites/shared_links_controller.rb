module Sites
  class SharedLinksController < ApplicationController
    include SiteScoped

    # Newest first, because the one you just made is the one you are here to copy.
    # Alphabetical put it wherever its label happened to sort, which on an account
    # with a dozen client links meant hunting for it.
    def index
      @shared_links = policy_scope(SharedLink).where(site: @site).includes(:dashboard).order(created_at: :desc)
      # A dashboard's own Share button arrives with ?dashboard=<public_id> so
      # the form opens preselected to the thing being looked at. Resolved
      # through @site's dashboards, so a foreign identifier preselects nothing.
      @shared_link = SharedLink.new(dashboard: preselected_dashboard)
    end

    def create
      @shared_link = @site.shared_links.new(shared_link_params)
      authorize @shared_link

      if @shared_link.save
        # `created` only highlights the new row. The secret is the slug, which is
        # not this, and the row it marks is one the viewer is already authorized
        # to see.
        redirect_to site_shared_links_path(@site, created: @shared_link.public_id),
                    notice: "Share link created. Copy it below."
      else
        redirect_to site_shared_links_path(@site), alert: @shared_link.errors.full_messages.to_sentence
      end
    end

    def destroy
      link = policy_scope(SharedLink).find_by_public_id!(params[:id])
      authorize link
      link.destroy!
      redirect_to site_shared_links_path(@site), notice: "Share link revoked."
    end

    private

    # `is_a?(String)`: the same type guard as ApplicationController's
    # account_slug — a crafted ?dashboard[x]=1 must not become a TypeError.
    def preselected_dashboard
      value = params[:dashboard]
      return nil unless value.is_a?(String) && value.present?

      @site.dashboards.find_by(public_id: value)
    end

    # `dashboard_public_id`, never `dashboard_id` — a posted primary key must
    # have no path into the model. See SharedLink#dashboard_public_id=.
    def shared_link_params
      params.expect(shared_link: %i[name password expires_at dashboard_public_id])
    end
  end
end
