module Sites
  # The "paste this one line into your site" screen. This is the whole product
  # promise in a single view, so it also polls for the first event and tells
  # the user the moment data arrives.
  class InstallationsController < ApplicationController
    include SiteScoped

    def show
      authorize @site, :show?

      # A site installed on an account that has already used its monthly events
      # receives nothing, and the poll below would spin on "waiting for your first
      # pageview" indefinitely — which reads as "the snippet does not work" and is
      # the single most expensive wrong conclusion a new customer can reach. So the
      # status card is given the usage figures and says what is actually happening.
      @usage = Billing::MeasureUsage.call(account: @site.account).value!

      # Turbo polls this frame; once the site is receiving data the frame
      # renders the success state and stops refreshing itself.
      return unless turbo_frame_request?

      render partial: "sites/installations/status", locals: { site: @site, usage: @usage }
    end
  end
end
