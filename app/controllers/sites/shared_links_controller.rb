module Sites
  class SharedLinksController < ApplicationController
    before_action :set_site

    def index
      @shared_links = policy_scope(SharedLink).where(site: @site).order(:name)
      @shared_link = SharedLink.new
    end

    def create
      @shared_link = @site.shared_links.new(shared_link_params)
      authorize @shared_link

      if @shared_link.save
        redirect_to site_shared_links_path(@site), notice: "Share link created."
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

    def set_site
      @site = policy_scope(Site).find_by!(public_token: params[:site_public_token])
    end

    def shared_link_params
      params.expect(shared_link: %i[name password expires_at])
    end
  end
end
