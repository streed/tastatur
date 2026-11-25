module Mcp
  module Tools
    # One MCP tool: validates its arguments, runs one existing report service
    # against ONE site, and returns a typed Mcp::ToolResult.
    #
    # THE ACCOUNT IS NOT AN ARGUMENT; THE SITE IS, AND IT CAN ONLY BE ONE OF THE
    # ACCOUNT'S. A key belongs to an account (its maker's access, which is
    # account-wide) and every tool is constructed with that account, so there is no
    # `account_id` an agent could be talked into changing. `site` is looked up
    # THROUGH the account's own sites: a token or domain that belongs to somebody
    # else's account is simply not found, and the error names only this account's
    # sites. A prompt-injected page in a tool result can therefore redirect the
    # agent between sites it was already allowed to read, and nowhere else.
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
      SITE_PROPERTY = {
        site: {
          type: "string",
          description: "Which site, by domain (example.com) or site token. Optional when the account has " \
                       "exactly one site; otherwise required. list_sites shows the choices."
        }
      }.freeze

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

        # Every tool but list_sites says which site it means.
        def needs_site? = true

        def properties = needs_site? ? SITE_PROPERTY.merge(self::PROPERTIES) : self::PROPERTIES

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

      def initialize(account:, arguments:)
        @account = account
        @arguments = arguments.respond_to?(:to_unsafe_h) ? arguments.to_unsafe_h : arguments.to_h
        @arguments = @arguments.deep_symbolize_keys
      end

      def call
        problems = unknown_arguments
        return Failure(invalid: problems) if problems.any?

        checked = self.class::CONTRACT.new.call(@arguments)
        return Failure(invalid: checked.errors.to_h) if checked.failure?

        @args = checked.to_h

        if self.class.needs_site?
          case find_site(args[:site])
          in Success(found) then @site = found
          in Failure => failure then return failure
          end
        end

        run
      end

      private

      attr_reader :account, :site, :args

      SITE_CHOICES_SHOWN = 15

      # Resolved against THIS ACCOUNT'S sites only. A single-site account needs no
      # argument, which is the common case and the one a person trying it out is in.
      def find_site(wanted)
        sites = account.sites.order(:domain).to_a
        return Failure(invalid: { site: ["This account has no sites yet."] }) if sites.empty?

        if wanted.blank?
          return Success(sites.first) if sites.one?

          return Failure(invalid: { site: ["is required: this account has #{sites.size} sites. #{site_choices(sites)}"] })
        end

        matches = sites.select { |candidate| candidate.public_token == wanted || candidate.domain.casecmp?(wanted) }
        return Success(matches.first) if matches.one?

        Failure(invalid: { site: ["#{wanted.inspect} is not one of this account's sites. #{site_choices(sites)}"] })
      end

      def site_choices(sites)
        shown = sites.first(SITE_CHOICES_SHOWN).map(&:domain).join(", ")
        more = sites.size > SITE_CHOICES_SHOWN ? " and #{sites.size - SITE_CHOICES_SHOWN} more (see list_sites)" : ""
        "Pass `site` as one of: #{shown}#{more}."
      end

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
