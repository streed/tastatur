module Mcp
  module Tools
    # One MCP tool: validates its arguments, runs one existing report service
    # against ONE site, and returns a typed Mcp::ToolResult.
    #
    # THE SITE IS NOT AN ARGUMENT. The API key names exactly one site and every
    # tool is constructed with it, so there is no `site_id` an agent could be
    # talked into changing — a prompt-injected page in a tool result cannot widen
    # the tenant boundary, because the boundary is not in the model's hands.
    #
    # EVERY TOOL WRAPS AN `Analytics::` OR `Revenue::` SERVICE and none writes SQL.
    # That is how k-anonymity, complementary suppression and the
    # distinct-counts-are-not-additive rules (§8, §13) reach the agent unchanged:
    # there is no second implementation of them to drift.
    #
    # Failure shapes, which Mcp::HandleRequest turns into tool errors the model can
    # read and act on:
    #   Failure(invalid: { field => [messages] })   bad arguments
    #   Failure(not_found: "message")               the thing named does not exist
    #   Failure(unavailable: "message")             the report cannot be produced
    class Base < ApplicationService
      PERIOD_PROPERTIES = {
        period: {
          type: "string", enum: Analytics::Period::PRESETS.keys,
          description: "Preset date range, default \"30d\". Resolved in the site's own timezone, " \
                       "so \"today\" is the site owner's today. Use \"custom\" with `from` and `to`."
        },
        from: { type: "string", format: "date", description: "First day, YYYY-MM-DD. Only with period \"custom\"." },
        to: { type: "string", format: "date", description: "Last day, inclusive, YYYY-MM-DD. Only with period \"custom\"." }
      }.freeze

      FILTERS_PROPERTY = {
        filters: {
          type: "object",
          description: "Narrow every number to visits matching ALL of these, e.g. {\"country\": \"DE\", \"device\": \"mobile\"}. " \
                       "Call describe_site for the valid keys. Values are exact matches.",
          properties: Analytics::Filters::DIMENSIONS.keys.index_with { { type: "string" } },
          additionalProperties: false
        }
      }.freeze

      class << self
        # Subclasses override these through constants, which keeps each tool's
        # public description next to the code that implements it.
        def tool_name = self::NAME

        # A tool can be absent from this instance (revenue is dark until Stripe
        # Connect is configured). Absent means not listed AND not callable: an agent
        # shown a tool that always errors will keep retrying it.
        def available? = true

        def properties = self::PROPERTIES

        def definition
          {
            name: tool_name,
            description: self::DESCRIPTION,
            inputSchema: {
              type: "object",
              properties: properties,
              required: self::REQUIRED.map(&:to_s),
              additionalProperties: false
            },
            annotations: { readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false }
          }
        end
      end

      def initialize(site:, arguments:)
        @site = site
        @arguments = arguments.respond_to?(:to_unsafe_h) ? arguments.to_unsafe_h : arguments.to_h
        @arguments = @arguments.deep_symbolize_keys
      end

      def call
        problems = unknown_arguments
        return Failure(invalid: problems) if problems.any?

        checked = self.class::CONTRACT.new.call(@arguments)
        return Failure(invalid: checked.errors.to_h) if checked.failure?

        @args = checked.to_h
        run
      end

      private

      attr_reader :site, :args

      def run = raise(NotImplementedError)

      # A misspelt argument is dropped by dry-schema without a word, and for a
      # filter that means a report that runs UNFILTERED and is presented as
      # filtered. Refusing it is the only honest answer.
      def unknown_arguments
        problems = {}
        (@arguments.keys - self.class.properties.keys).each { |name| problems[name] = ["is not an argument of this tool"] }

        filters = @arguments[:filters]
        if filters.is_a?(Hash)
          unknown = filters.keys.map(&:to_s) - Analytics::Filters::DIMENSIONS.keys
          problems[:filters] = ["has unknown keys: #{unknown.join(', ')}"] if unknown.any?
        end
        problems
      end

      def period
        @period ||= Analytics::Period.parse(args[:period], site: site, from: args[:from], to: args[:to])
      end

      def filters = @filters ||= Analytics::Filters.new(args[:filters] || {})

      def zone = site.timezone

      def iso(time) = time&.in_time_zone(zone)&.iso8601

      # Both ends as the site's own dates, because `to` is exclusive midnight
      # internally and an agent told "to: 2026-03-02T00:00" would reasonably
      # believe the second was included.
      def period_data
        {
          preset: period.key,
          label: period.label,
          first_day: period.from.in_time_zone(zone).to_date.iso8601,
          last_day: (period.to - 1.second).in_time_zone(zone).to_date.iso8601,
          timezone: zone,
          bucket: period.interval
        }
      end

      def filters_data = filters.each.to_h

      def result(data, notes = [])
        Success(Mcp::ToolResult.new(data: data, notes: notes))
      end
    end
  end
end
