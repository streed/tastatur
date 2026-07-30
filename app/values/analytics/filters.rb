module Analytics
  # The set of dimension filters applied to a report.
  #
  # Filters arrive from the URL (so a filtered dashboard is shareable and
  # bookmarkable) and are turned into a SQL fragment here. The allowlist below
  # is the security boundary: a filter key that is not in DIMENSIONS never
  # reaches SQL, and every value is bound as a parameter rather than
  # interpolated.
  class Filters
    # url key => events column
    DIMENSIONS = {
      "page" => "path",
      "entry_page" => "path",
      "source" => "referrer_source",
      "referrer" => "referrer_host",
      "country" => "country_code",
      "browser" => "browser",
      "os" => "os",
      "device" => "device_type",
      "screen" => "screen_class",
      "utm_source" => "utm_source",
      "utm_medium" => "utm_medium",
      "utm_campaign" => "utm_campaign",
      "utm_term" => "utm_term",
      "utm_content" => "utm_content",
      "event" => "event_name",
      "hostname" => "hostname"
    }.freeze

    HUMAN_LABELS = {
      "page" => "Page",
      "entry_page" => "Entry page",
      "source" => "Source",
      "referrer" => "Referrer",
      "country" => "Country",
      "browser" => "Browser",
      "os" => "Operating system",
      "device" => "Device",
      "screen" => "Screen size",
      "utm_source" => "UTM source",
      "utm_medium" => "UTM medium",
      "utm_campaign" => "UTM campaign",
      "utm_term" => "UTM term",
      "utm_content" => "UTM content",
      "event" => "Event",
      "hostname" => "Hostname"
    }.freeze

    attr_reader :applied

    # `permit`, not `to_h` — calling to_h on unpermitted ActionController
    # parameters raises UnfilteredParameters. Permitting exactly the dimension
    # keys is also the security boundary: anything not in DIMENSIONS is dropped
    # here and can never reach the SQL builder below.
    def self.from_params(params)
      permitted = params.respond_to?(:permit) ? params.permit(*DIMENSIONS.keys) : params
      new(permitted.to_h)
    end

    def initialize(applied = {})
      @applied = applied.to_h
                        .select { |key, value| DIMENSIONS.key?(key.to_s) && value.present? }
                        .transform_keys(&:to_s)
                        .transform_values { |value| value.to_s.first(500) }
                        .freeze
    end

    def any?  = @applied.any?
    def empty? = @applied.empty?
    def [](key) = @applied[key.to_s]

    # An event filter pins event_name in the WHERE clause, which flips what the
    # volume metric has to mean — see Scope#volume_expression. Everything that
    # branches on "is this dashboard scoped to one custom event" asks this,
    # rather than inspecting the applied hash directly.
    def event_scoped? = @applied.key?("event")

    def each(&) = @applied.each(&)

    def label_for(key) = HUMAN_LABELS[key.to_s] || key.to_s.humanize

    # Returns [sql, binds] to AND into a WHERE clause. Empty when no filters
    # are applied. `table` prefixes each column for self-joined queries.
    def to_sql(table: nil)
      return ["", []] if empty?

      prefix = table ? "#{table}." : ""
      clauses = []
      binds = []

      @applied.each do |key, value|
        column = "#{prefix}#{DIMENSIONS.fetch(key)}"

        # entry_page means "the path of the session's first event", which is a
        # different condition from "any pageview on this path".
        clauses << if key == "entry_page"
                     "(#{column} = ? AND #{prefix}is_entry)"
        else
                     "#{column} = ?"
        end
        binds << value
      end

      [clauses.join(" AND "), binds]
    end

    def with(key, value)
      self.class.new(@applied.merge(key.to_s => value))
    end

    def without(key)
      self.class.new(@applied.except(key.to_s))
    end

    def to_param
      @applied
    end
  end
end
