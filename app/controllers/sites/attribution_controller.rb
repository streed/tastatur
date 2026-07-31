module Sites
  # The attribution screen — which channel produced paying customers.
  #
  # A read, so it is open to viewers exactly like every other report (see
  # CustomerPolicy for why revenue is not held to a tighter rung than traffic).
  class AttributionController < ApplicationController
    include SiteScoped

    def show
      authorize @site, :stats?

      @period = Analytics::Period.parse(params[:period], site: @site,
                                        from: params[:from], to: params[:to])
      @sort = params[:sort]

      @report = Revenue::AttributionReport.call(site: @site, period: @period, sort: @sort).value!
      @connection = @site.stripe_connection
    end
  end
end
