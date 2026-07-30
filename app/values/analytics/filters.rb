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

    # Custom event properties are filterable too, and they are the one filter
    # whose KEY is chosen by the customer rather than by us. DIMENSIONS cannot
    # enumerate them, so they travel under a reserved prefix in the internal
    # hash — "props:plan" => "pro" — which keeps `applied`, `with`, `without`
    # and the filter chips working on one flat structure, and keeps every
    # existing dimension unreachable from the property path.
    #
    # In a URL they are nested (`?props[plan]=pro`) because that is the only
    # shape `params.permit` can accept for keys it cannot name in advance.
    PROPERTY_PREFIX = "props:".freeze

    MAX_VALUE = 500

    # A key longer than the ingest contract allows cannot exist in the data, so
    # a filter for one can only ever be noise or an attempt to make the query
    # expensive. Bounding the count matters for the same reason: the property
    # key is a bind parameter and cannot inject, but fifty of them would still
    # be fifty JSONB extractions per row.
    MAX_PROPERTY_KEY = IngestEventContract::MAX_PROP_KEY
    MAX_PROPERTY_FILTERS = 10

    attr_reader :applied

    def self.property?(key)
      key.to_s.start_with?(PROPERTY_PREFIX)
    end

    # `permit`, not `to_h` — calling to_h on unpermitted ActionController
    # parameters raises UnfilteredParameters. Permitting exactly the dimension
    # keys is also the security boundary: anything not in DIMENSIONS is dropped
    # here and can never reach the SQL builder below.
    #
    # `props: {}` is the one place that boundary has to be drawn differently,
    # because the permitted keys are the customer's own property names and are
    # unknowable here. It admits an arbitrarily-shaped hash, so the constraint
    # moves into #normalize_properties: a value that is not a scalar is dropped
    # rather than stringified, which is what stops `?props[plan][]=x` from
    # reaching SQL as the string representation of an Array.
    def self.from_params(params)
      permitted = params.respond_to?(:permit) ? params.permit(*DIMENSIONS.keys, props: {}) : params
      new(permitted.to_h)
    end

    def initialize(applied = {})
      raw = applied.to_h.transform_keys(&:to_s)

      # Two accepted spellings, because both are load-bearing: the nested form
      # is what arrives from a URL, and the prefixed form is what `with` and
      # `without` round-trip through when a breakdown row is clicked.
      nested = raw.delete("props")
      inline = raw.select { |key, _| self.class.property?(key) }
      raw.except!(*inline.keys)

      dimensions = raw.select { |key, value| DIMENSIONS.key?(key) && value.present? }
                      .transform_values { |value| value.to_s.first(MAX_VALUE) }

      @applied = dimensions.merge(normalize_properties(nested, inline)).freeze
    end

    def any?  = @applied.any?
    def empty? = @applied.empty?
    def [](key) = @applied[key.to_s]

    # An event filter pins event_name in the WHERE clause, which flips what the
    # volume metric has to mean — see Scope#volume_expression. Everything that
    # branches on "is this dashboard scoped to one custom event" asks this,
    # rather than inspecting the applied hash directly.
    def event_scoped? = @applied.key?("event")

    # Is the dashboard scoped to a custom event property? Kept separate from
    # event_scoped? because it does not change what the volume metric means —
    # it only decides whether the property panels have anything to stand on.
    def property_scoped? = @applied.keys.any? { |key| self.class.property?(key) }

    # The applied property filters as { "plan" => "pro" }, without the prefix.
    def properties
      @applied.filter_map do |key, value|
        [key.delete_prefix(PROPERTY_PREFIX), value] if self.class.property?(key)
      end.to_h
    end

    def each(&) = @applied.each(&)

    # A property's label is the customer's own key, verbatim. There is nothing
    # to look up in HUMAN_LABELS and nothing to humanize: `utm_source` is our
    # vocabulary and reads better title-cased, `plan` is theirs and should
    # appear exactly as they wrote it.
    def label_for(key)
      return key.to_s.delete_prefix(PROPERTY_PREFIX) if self.class.property?(key)

      HUMAN_LABELS[key.to_s] || key.to_s.humanize
    end

    # Returns [sql, binds] to AND into a WHERE clause. Empty when no filters
    # are applied. `table` prefixes each column for self-joined queries.
    def to_sql(table: nil)
      return ["", []] if empty?

      prefix = table ? "#{table}." : ""
      clauses = []
      binds = []

      @applied.each do |key, value|
        # The property NAME is a bind parameter, not an interpolation. It is the
        # only part of any filter that the customer chooses the spelling of, so
        # it is the only one that could carry SQL if it were ever concatenated —
        # `props ->> ?` keeps that impossible by construction rather than by
        # escaping.
        if self.class.property?(key)
          clauses << "#{prefix}props ->> ? = ?"
          binds << key.delete_prefix(PROPERTY_PREFIX) << value
          next
        end

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

    # Back to the URL shape: dimensions stay flat, properties go back under the
    # nested `props` key that from_params can permit.
    def to_param
      dimensions = @applied.reject { |key, _| self.class.property?(key) }
      values = properties

      values.any? ? dimensions.merge("props" => values) : dimensions
    end

    private

    # The security boundary for the one filter whose keys we do not control.
    #
    # A value that is not a scalar is DROPPED rather than coerced. `props: {}`
    # permits arbitrary nesting, so `?props[plan][]=x` arrives as an Array and
    # `?props[plan][x]=y` as a Hash; calling to_s on either would put its Ruby
    # inspect form into a bind parameter, which matches nothing and hides the
    # mistake. Dropping it means a filter that cannot be expressed is simply not
    # applied.
    def normalize_properties(nested, inline)
      pairs = {}
      pairs.merge!(nested.to_h.transform_keys(&:to_s)) if nested.respond_to?(:to_h)
      inline.each { |key, value| pairs[key.delete_prefix(PROPERTY_PREFIX)] = value }

      pairs.filter_map { |key, value|
        name = key.to_s.strip
        next if name.empty? || name.length > MAX_PROPERTY_KEY
        next unless scalar?(value)
        next if value.to_s.empty?

        ["#{PROPERTY_PREFIX}#{name}", value.to_s.first(MAX_VALUE)]
      }.first(MAX_PROPERTY_FILTERS).to_h
    end

    def scalar?(value)
      value.is_a?(String) || value.is_a?(Numeric) || value == true || value == false
    end
  end
end
