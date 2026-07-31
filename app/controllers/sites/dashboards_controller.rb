module Sites
  class DashboardsController < ApplicationController
    include SiteScoped
    # Feeds the filter-value comboboxes on the editor form. Lazy (a helper
    # method, not a callback), so a successful save that redirects never pays
    # for the thirty-day scan.
    include OffersKnownValues

    before_action :set_dashboard, only: %i[show edit update destroy]

    def index
      @dashboards = policy_scope(Dashboard).where(site: @site).includes(:dashboard_widgets).ordered
    end

    def show
      authorize @dashboard

      @period = Analytics::Period.parse(params[:period], site: @site, from: params[:from], to: params[:to])
      @report = Dashboards::Render.call(dashboard: @dashboard, period: @period).value!

      # Same frame contract as sites#show: the widgets partial emits the
      # <turbo-frame id="dashboard"> itself, so a period click swaps the frame
      # and the response actually contains one.
      return unless turbo_frame_request?

      render partial: "sites/dashboards/widgets",
             locals: { site: @site, report: @report, editable: policy(@dashboard).update? }
    end

    def new
      @dashboard = @site.dashboards.new
      # Open with one concrete widget rather than an empty list: the form's
      # minimum is MIN_WIDGETS, and a stat tile is the cheapest thing to
      # understand and delete.
      @dashboard.dashboard_widgets.build(kind: "stat", metric: "visitors")
      authorize @dashboard
    end

    def create
      @dashboard = @site.dashboards.new(dashboard_params)
      authorize @dashboard

      if @dashboard.save
        redirect_to site_dashboard_path(@site, @dashboard), notice: "Dashboard created."
      else
        ensure_minimum_rows
        render :new, status: :unprocessable_entity
      end
    end

    def edit
      authorize @dashboard
    end

    def update
      authorize @dashboard

      if @dashboard.update(dashboard_params)
        redirect_to site_dashboard_path(@site, @dashboard), notice: "Dashboard updated."
      else
        ensure_minimum_rows
        render :edit, status: :unprocessable_entity
      end
    end

    def destroy
      authorize @dashboard
      @dashboard.destroy!
      redirect_to site_dashboards_path(@site), notice: "Dashboard deleted."
    end

    private

    def set_dashboard
      @dashboard = @site.dashboards.find_by_public_id!(params[:id])
    end

    # After a failed save the submitted rows are re-rendered as-is. If the user
    # had removed rows down below the minimum, top the form back up so they are
    # not left with a form they cannot submit. Same as Sites::FunnelsController.
    def ensure_minimum_rows
      missing = Dashboard::MIN_WIDGETS -
                @dashboard.dashboard_widgets.reject(&:marked_for_destruction?).size
      missing.clamp(0, Dashboard::MAX_WIDGETS).times do
        @dashboard.dashboard_widgets.build(kind: "stat", metric: "visitors")
      end
    end

    # `funnel_public_id`, never `funnel_id`: a posted primary key must have no
    # path into the model. See DashboardWidget#funnel_public_id=.
    def dashboard_params
      params.expect(
        dashboard: [:name,
                    { dashboard_widgets_attributes: [
                      [:id, :position, :kind, :title, :metric, :dimension, :row_limit,
                       :funnel_public_id, :_destroy,
                       { filter_pairs_attributes: [%i[dimension value]] }]
                    ] }]
      )
    end
  end
end
