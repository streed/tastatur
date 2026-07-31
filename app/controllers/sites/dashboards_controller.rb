module Sites
  class DashboardsController < ApplicationController
    include SiteScoped
    # Feeds the filter-value comboboxes on the widget configuration panels.
    # Lazy (a helper method, not a callback), so a period click or a successful
    # save never pays for the thirty-day scan.
    include OffersKnownValues

    before_action :set_dashboard, only: %i[show update destroy]

    def index
      @dashboards = policy_scope(Dashboard).where(site: @site).includes(:dashboard_widgets).ordered
    end

    # The dashboard IS the editor. Everything that used to live on a separate
    # page — the name, each widget's configuration, adding and removing widgets
    # — happens here, against the real numbers rather than against a list of
    # select boxes. `editable` is what the widgets partial gates all of that on,
    # and it is false on the public shared copy, which renders the same partial.
    def show
      authorize @dashboard

      @period = Analytics::Period.parse(params[:period], site: @site, from: params[:from], to: params[:to])
      @report = Dashboards::Render.call(dashboard: @dashboard, period: @period).value!

      # Same frame contract as sites#show: the widgets partial emits the
      # <turbo-frame id="dashboard"> itself, so a period click swaps the frame
      # and the response actually contains one.
      return unless turbo_frame_request?

      render partial: "sites/dashboards/widgets",
             locals: { site: @site, report: @report, editable: policy(@dashboard).update?,
                       configuring: params[:configure] }
    end

    def new
      @dashboard = @site.dashboards.new
      authorize @dashboard
    end

    # The form asks for a name and nothing else — widgets are chosen on the
    # dashboard itself. A dashboard cannot be saved without one
    # (Dashboard::MIN_WIDGETS), so it opens with the same tile the Add button
    # creates, and the author configures it in place.
    def create
      @dashboard = @site.dashboards.new(dashboard_params)
      @dashboard.dashboard_widgets.build(Dashboards::AddWidget::DEFAULTS)
      authorize @dashboard

      if @dashboard.save
        redirect_to site_dashboard_path(@site, @dashboard, configure: @dashboard.dashboard_widgets.first.public_id),
                    notice: "Dashboard created."
      else
        render :new, status: :unprocessable_entity
      end
    end

    # The inline rename in the dashboard header. Nothing else posts here — a
    # widget's configuration is its own resource now.
    def update
      authorize @dashboard

      if @dashboard.update(dashboard_params)
        redirect_to site_dashboard_path(@site, @dashboard), notice: "Dashboard renamed."
      else
        @period = Analytics::Period.parse(params[:period], site: @site)
        @report = Dashboards::Render.call(dashboard: @dashboard, period: @period).value!
        render :show, status: :unprocessable_entity
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

    def dashboard_params
      params.expect(dashboard: [:name])
    end
  end
end
