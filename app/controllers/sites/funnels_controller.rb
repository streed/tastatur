module Sites
  class FunnelsController < ApplicationController
    include SiteScoped
    include OffersKnownValues

    before_action :set_funnel, only: %i[show edit update destroy]

    def index
      # `includes`, because the view renders each funnel's step names inline and
      # was therefore issuing one query per row.
      @funnels = policy_scope(Funnel).where(site: @site).includes(:funnel_steps).ordered
    end

    def show
      authorize @funnel

      @period = Analytics::Period.parse(params[:period], site: @site)
      @filters = Analytics::Filters.from_params(params)

      result = Analytics::FunnelReport.call(funnel: @funnel, period: @period, filters: @filters)

      case result
      in Success(report) then @report = report
      in Failure(:not_enough_steps)
        redirect_to edit_site_funnel_path(@site, @funnel), alert: "Add at least two steps first."
      end
    end

    def new
      @funnel = @site.funnels.new(window_seconds: 86_400)
      # Open with the minimum viable funnel. Further steps come from the Add
      # button, which clones a template row client-side.
      Funnel::MIN_STEPS.times { @funnel.funnel_steps.build(kind: "pageview", match_type: "exact") }
      authorize @funnel
    end

    def create
      @funnel = @site.funnels.new(funnel_params)
      authorize @funnel

      if @funnel.save
        redirect_to site_funnel_path(@site, @funnel), notice: "Funnel created."
      else
        ensure_minimum_rows
        render :new, status: :unprocessable_entity
      end
    end

    def edit
      authorize @funnel
    end

    def update
      authorize @funnel

      if @funnel.update(funnel_params)
        redirect_to site_funnel_path(@site, @funnel), notice: "Funnel updated."
      else
        ensure_minimum_rows
        render :edit, status: :unprocessable_entity
      end
    end

    def destroy
      authorize @funnel
      @funnel.destroy!
      redirect_to site_funnels_path(@site), notice: "Funnel deleted."
    end

    private

    # After a failed save the submitted rows are re-rendered as-is. If the user
    # had removed rows down below the minimum, top the form back up so they are
    # not left with a form they cannot submit.
    def ensure_minimum_rows
      missing = Funnel::MIN_STEPS - @funnel.funnel_steps.reject(&:marked_for_destruction?).size
      missing.clamp(0, Funnel::MAX_STEPS).times do
        @funnel.funnel_steps.build(kind: "pageview", match_type: "exact")
      end
    end

    def set_funnel
      @funnel = @site.funnels.find_by_public_id!(params[:id])
    end

    def funnel_params
      params.expect(
        funnel: [:name, :window_seconds, :strict_order,
                 { funnel_steps_attributes: [%i[id position name kind match_value match_type _destroy]] }]
      )
    end
  end
end
