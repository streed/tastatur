module Sites
  # One widget on a custom dashboard, added, configured and removed from the
  # dashboard itself. There is no editor page: `edit` renders a configuration
  # panel into the widget's own turbo frame, in place of the widget.
  #
  # AUTHORIZATION IS ON THE DASHBOARD, not on the widget. A widget is not a
  # thing anybody has an opinion about independently of the dashboard it is on,
  # and a second policy would be a second place for the account check to be
  # forgotten — §11's cross-tenant leak, one policy out of twelve. `authorize
  # @dashboard, :update?` is the same question every one of these actions is
  # really asking.
  class DashboardWidgetsController < ApplicationController
    include SiteScoped
    # Feeds the filter-value comboboxes on the configuration panel. Lazy (a
    # helper method, not a callback), so the redirect after a successful save
    # never pays for the thirty-day scan.
    include OffersKnownValues

    before_action :set_dashboard
    before_action :set_widget, only: %i[show edit update destroy]

    # Not a page: what the frame fetches to put the widget back when a panel is
    # cancelled, and what `update` renders on success.
    def show
      load_report
    end

    def create
      case Dashboards::AddWidget.call(dashboard: @dashboard)
      in Success(widget)
        redirect_to configure_path(widget), notice: "Widget added."
      in Failure(:at_limit)
        redirect_to site_dashboard_path(@site, @dashboard),
                    alert: "This dashboard already has #{Dashboard::MAX_WIDGETS} widgets."
      end
    end

    def edit; end

    def update
      if @widget.update(widget_params)
        # The frame gets the widget back, showing real numbers under the
        # configuration that was just saved. Re-rendering the whole dashboard
        # would be correct too and would throw away the rest of the page for
        # one tile.
        load_report
        render :show
      else
        render :edit, status: :unprocessable_entity
      end
    end

    def destroy
      case Dashboards::RemoveWidget.call(widget: @widget)
      in Success(_)
        redirect_to site_dashboard_path(@site, @dashboard), notice: "Widget removed."
      in Failure(:last_widget)
        redirect_to site_dashboard_path(@site, @dashboard),
                    alert: "A dashboard needs at least one widget. Delete the dashboard instead."
      end
    end

    private

    def set_dashboard
      @dashboard = @site.dashboards.find_by_public_id!(params[:dashboard_id])
      authorize @dashboard, :update?
    end

    def set_widget
      @widget = @dashboard.dashboard_widgets.find_by_public_id!(params[:id])
    end

    # A newly added widget opens straight into its own configuration panel:
    # "Add widget" is a sentence somebody starts, and landing on a stat tile
    # they did not ask for with no indication of where to change it finishes it
    # for them. The dashboard renders it expanded from this parameter, so the
    # redirect works with or without JavaScript.
    def configure_path(widget)
      site_dashboard_path(@site, @dashboard, configure: widget.public_id, period: params[:period])
    end

    # The whole dashboard is composed to render one widget, deliberately.
    # Dashboards::Render batches breakdowns and shares summaries across widgets,
    # so a "just this one" path would be a second way to compute a widget and a
    # second place for the two to drift. This runs on a save, not on a page
    # view, and a dashboard is at most twelve widgets.
    def load_report
      @report = Dashboards::Render.call(dashboard: @dashboard, period: period).value!
      @result = @report.widgets.find { |result| result.widget.id == @widget.id }
    end

    def period
      Analytics::Period.parse(params[:period], site: @site, from: params[:from], to: params[:to])
    end

    # No `position` and no `_destroy`: order is the dashboard's business (see
    # Dashboards::RemoveWidget) and removal is its own action now, so neither
    # has any business arriving in a widget's own form.
    #
    # `funnel_public_id`, never `funnel_id` — a posted primary key must have no
    # path into the model. See DashboardWidget#funnel_public_id=.
    #
    # THE DEFAULT IS LOAD-BEARING. The panel always submits the COMPLETE filter
    # set, so an absent key means "no filters", not "leave them as they were" —
    # without this, removing a widget's last filter silently kept it. The blank
    # sentinel row the form used to carry was meant to prevent exactly that and
    # could not: Rails only treats a nested-attributes hash as one when its keys
    # are numeric, so a lone `{"sentinel" => ...}` was filtered out before the
    # model ever saw it, and the writer never ran.
    def widget_params
      params.expect(
        dashboard_widget: [:kind, :title, :metric, :dimension, :row_limit, :funnel_public_id,
                           { filter_pairs_attributes: [%i[dimension value]] }]
      ).with_defaults(filter_pairs_attributes: {})
    end
  end
end
