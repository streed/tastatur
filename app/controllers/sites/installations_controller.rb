module Sites
  # The "paste this one line into your site" screen. This is the whole product
  # promise in a single view, so it also polls for the first event and tells
  # the user the moment data arrives.
  class InstallationsController < ApplicationController
    def show
      @site = policy_scope(Site).find_by!(public_token: params[:site_public_token])
      authorize @site, :show?

      # Turbo polls this frame; once the site is receiving data the frame
      # renders the success state and stops refreshing itself.
      return unless turbo_frame_request?

      render partial: "sites/installations/status", locals: { site: @site }
    end
  end
end
