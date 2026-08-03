module Sites
  # The navigation flow tree: pick a page visitors arrive on, then walk forward
  # one hop at a time.
  #
  # The walked path is carried in the URL as `?path[]=/&path[]=/pricing`, for the
  # same reason the dashboard's filters are (see DashboardHelper): an expanded
  # tree is then shareable, bookmarkable and survives the back button, and the
  # whole screen needs no client-side state and no JavaScript.
  #
  # NOT REACHABLE FROM A PUBLIC SHARED DASHBOARD, and deliberately so. Those are
  # rendered with no filters at all because filtering a stranger's audience is a
  # re-identification tool, and a journey is a stronger one than any single
  # filter — it is a conjunction that narrows the crowd at every hop. Keeping
  # this on an authenticated /sites route means the question cannot be asked
  # there at all, rather than being asked and then suppressed.
  class JourneysController < ApplicationController
    include SiteScoped

    # Enough starting points to cover where visits actually begin without
    # turning the picker into the Top pages panel again.
    START_PAGE_LIMIT = 12

    def show
      authorize @site, :stats?

      @period = Analytics::Period.parse(params[:period], site: @site)

      # Entry pages, through Analytics::Breakdown — so the list of places a
      # journey can start is k-anonymous before the tree is ever walked. A
      # cheaper SELECT DISTINCT path here would publish, as a set of links, the
      # rows the dashboard withholds; the same argument as Analytics::KnownValues.
      @start_pages = Analytics::Breakdown.call(
        site: @site, period: @period, dimension: "entry_page", limit: START_PAGE_LIMIT
      ).value!

      @path = requested_path
      @levels = build_levels
    end

    private

    # The walked path, or the busiest entry page when nothing has been picked
    # yet — so the screen opens showing something rather than an instruction.
    #
    # `permit(path: [])` is the same boundary Analytics::Filters draws: the
    # values reach SQL only as bind parameters, and the depth is clamped by
    # PageFlow itself.
    def requested_path
      given = Array(params.permit(path: [])[:path]).map(&:to_s).reject(&:empty?)
      return given.first(Analytics::PageFlow::MAX_DEPTH) if given.any?

      Array(@start_pages.rows.first&.value)
    end

    # One level per hop, so the alternatives at each step stay on screen beside
    # the branch that was taken — the point of the report is what people did
    # instead, not only what they did next. Bounded by PageFlow::MAX_DEPTH, so
    # this is at most six queries and usually one or two.
    def build_levels
      (1..@path.size).map do |depth|
        Analytics::PageFlow.call(
          site: @site, period: @period, prefix: @path.first(depth)
        ).value!
      end
    end
  end
end
