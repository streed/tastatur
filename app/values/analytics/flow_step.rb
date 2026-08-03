module Analytics
  # One step of a journey: a page that was viewed, or a custom event that fired.
  #
  # A step is a PAIR, never a bare string, and that is the whole reason this
  # class exists. `Signup` the event and `/signup` the page are two different
  # things that a customer may well have both, and the same trap CLAUDE.md §12
  # records for funnel steps applies here — infer the kind from the shape of the
  # value and a custom event named `/welcome` starts satisfying a step that asked
  # for the page. So the kind travels with the value everywhere: through the URL,
  # through Analytics::PageFlow's SQL, and onto the screen.
  #
  # PAGEVIEW IS THE DEFAULT, deliberately. The Journeys screen carries its walked
  # path in the URL as two parallel arrays — `?path[]=/&path[]=/pricing` plus an
  # optional `kind[]` — and a missing or unrecognised kind reads as a pageview.
  # That keeps every journey URL written before events were steps working exactly
  # as it did, and it is why the helper omits `kind[]` entirely from a path that
  # is all pages: the common link stays as short as it was.
  #
  # The two arrays cannot desync in any way that matters. Each is ordered
  # independently by the query string, they are zipped by index, a short `kind[]`
  # leaves the remaining steps as pages, and a long one has its extras ignored.
  # The worst a hand-edited URL produces is a step that matches nothing, which
  # the report already renders as "No data.".
  class FlowStep
    PAGEVIEW = "pageview".freeze
    EVENT = "event".freeze

    # The same two names the goal form, the funnel-condition form and
    # Analytics::KnownValues#payload use for the same distinction. One
    # vocabulary, so the value picker's JSON needs no translation layer.
    KINDS = [PAGEVIEW, EVENT].freeze

    attr_reader :kind, :value

    def self.page(value) = new(kind: PAGEVIEW, value: value)
    def self.event(value) = new(kind: EVENT, value: value)

    # A step from one element of each URL array. Nil for a blank value, so a
    # caller can `filter_map` a hand-edited path clean in one pass.
    def self.parse(value, kind = nil)
      value = value.to_s
      return if value.empty?

      new(kind: kind, value: value)
    end

    # The walked path, from `path[]` and `kind[]`.
    def self.zip(values, kinds = nil)
      kinds = Array(kinds)

      Array(values).each_with_index.filter_map { |value, index| parse(value, kinds[index]) }
    end

    # Accepts a step or a bare string, so callers that only ever deal in pages —
    # Analytics::Dashboard's two flow panels, which are filtered to one path —
    # do not have to know this class exists.
    def self.coerce(step)
      step.is_a?(self) ? step : parse(step)
    end

    def initialize(kind:, value:)
      @kind = KINDS.include?(kind.to_s) ? kind.to_s : PAGEVIEW
      @value = value.to_s
      freeze
    end

    def page? = kind == PAGEVIEW
    def event? = kind == EVENT

    # Value equality, because DashboardHelper#flow_return? asks whether a branch
    # revisits somewhere already on the walked path, and two steps are the same
    # place only when both halves agree.
    def ==(other) = other.is_a?(FlowStep) && other.kind == kind && other.value == value
    alias eql? ==

    def hash = [self.class, kind, value].hash
  end
end
