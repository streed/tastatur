module Sites
  # The navigation flow tree: pick a page or a custom event visitors reach, then
  # walk forward one hop at a time.
  #
  # The walked path is carried in the URL as `?path[]=/&path[]=/pricing`, for the
  # same reason the dashboard's filters are (see DashboardHelper): an expanded
  # tree is then shareable, bookmarkable and survives the back button, and the
  # whole screen needs no client-side state and no JavaScript. A step that is a
  # custom event rather than a page says so in a parallel `kind[]` array — see
  # Analytics::FlowStep for why the kind is carried rather than guessed at, and
  # why the array is absent from an all-pages URL.
  #
  # NOT REACHABLE FROM A PUBLIC SHARED DASHBOARD, and deliberately so. Those are
  # rendered with no filters at all because filtering a stranger's audience is a
  # re-identification tool, and a journey is a stronger one than any single
  # filter — it is a conjunction that narrows the crowd at every hop. Keeping
  # this on an authenticated /sites route means the question cannot be asked
  # there at all, rather than being asked and then suppressed.
  class JourneysController < ApplicationController
    include SiteScoped
    # The start field is a combobox over what this site has really recorded, so
    # any page or event can be typed rather than only the entry pages offered as
    # chips. A helper_method and not a before_action for the reason the concern
    # documents — though here the template always asks, since the form is always
    # on screen.
    include OffersKnownValues

    # Enough starting points to cover where visits actually begin without
    # turning the picker into the Top pages panel again.
    START_PAGE_LIMIT = 12

    # Custom events are steps by default, because the click between two pages is
    # usually the interesting part of the journey. The escape hatch matters all
    # the same: a site that fires a scroll-depth or heartbeat event on every page
    # has one step between every pair of pages and the page-to-page shape becomes
    # unreadable. `?steps=pages` is the report as it was.
    PAGES_ONLY = "pages".freeze

    def show
      authorize @site, :stats?

      @period = Analytics::Period.parse(params[:period], site: @site)
      @include_events = params[:steps] != PAGES_ONLY

      # Entry pages, through Analytics::Breakdown — so the list of places a
      # journey can start is k-anonymous before the tree is ever walked. A
      # cheaper SELECT DISTINCT path here would publish, as a set of links, the
      # rows the dashboard withholds; the same argument as Analytics::KnownValues.
      @start_pages = Analytics::Breakdown.call(
        site: @site, period: @period, dimension: "entry_page", limit: START_PAGE_LIMIT
      ).value!

      @path = requested_path
      @start = @path.first || Analytics::FlowStep.page(nil)
      @levels = build_levels
    end

    private

    # The walked path, or the busiest entry page when nothing has been picked
    # yet — so the screen opens showing something rather than an instruction.
    #
    # `permit(path: [], kind: [])` is the same boundary Analytics::Filters draws:
    # the values reach SQL only as bind parameters, and the depth is clamped by
    # PageFlow itself.
    #
    # TRUNCATED at the first event under `?steps=pages`, rather than filtered.
    # Dropping the event from the middle of `/ → Signup → /welcome` would leave
    # `/ → /welcome`, which is a different journey that may well have nobody in
    # it — a path is a prefix, and the honest way to shorten it is from the end.
    def requested_path
      permitted = params.permit(path: [], kind: [])
      given = Analytics::FlowStep.zip(permitted[:path], permitted[:kind])
      given = given.take_while(&:page?) unless @include_events

      return given.first(Analytics::PageFlow::MAX_DEPTH) if given.any?

      Array(@start_pages.rows.first&.value).map { |value| Analytics::FlowStep.page(value) }
    end

    # One level per hop, so the alternatives at each step stay on screen beside
    # the branch that was taken — the point of the report is what people did
    # instead, not only what they did next. Bounded by PageFlow::MAX_DEPTH, so
    # this is at most six queries and usually one or two.
    def build_levels
      (1..@path.size).map do |depth|
        Analytics::PageFlow.call(
          site: @site, period: @period, prefix: @path.first(depth),
          include_events: @include_events
        ).value!
      end
    end
  end
end
