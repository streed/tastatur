module Mcp
  module Tools
    class GetRevenueAttribution < Base
      NAME = "get_revenue_attribution".freeze
      DESCRIPTION = "Which channels (source / medium / campaign) produced paying customers: visitors, signups, trials, " \
                    "conversions and recurring revenue movements per channel, ranked by money rather than traffic. " \
                    "Amounts are integers in the smallest currency unit (cents).".freeze
      PROPERTIES = Base::PERIOD_PROPERTIES.merge(
        sort: { type: "string", enum: Revenue::AttributionReport::SORTS.keys, description: "Default \"revenue\"." },
        limit: { type: "integer", minimum: McpRevenueContract::LIMIT.min, maximum: McpRevenueContract::LIMIT.max,
                 description: "Channels to return, default 25." }
      ).freeze
      REQUIRED = [].freeze
      CONTRACT = McpRevenueContract

      # Dark until Stripe Connect is configured (§18); an unavailable tool is neither
      # listed nor callable.
      def self.available? = Tastatur.revenue_enabled?

      private

      def run
        case Revenue::AttributionReport.call(site: site, period: period, sort: args[:sort] || "revenue", limit: args.fetch(:limit, 25))
        in Success(report)
          result(
            {
              period: period_data, sort: report[:sort], truncated: report[:truncated],
              data_as_of: iso(report[:stale_since]),
              totals: report[:totals],
              channels: report[:rows].map { |row| row_data(row) }
            },
            ["`lifetime_revenue_cents` is a snapshot of everything a channel has ever produced, not revenue in this " \
             "period. Never add it across periods or to the MRR columns.",
             "`conversion_rate_percent` is null for a channel with conversions but no recorded visitors (imported " \
             "customers, ad blockers). That is missing traffic, not a 0% rate."]
          )
        end
      end

      def row_data(row)
        rate = row.conversion_rate
        {
          channel: row.channel_label, source: row.source, medium: row.medium, campaign: row.campaign,
          visitors: row.visitors, signups: row.signups, trials: row.trials, conversions: row.conversions,
          conversion_rate_percent: rate && (rate * 100).round(2),
          new_mrr_cents: row.new_mrr_cents, expansion_mrr_cents: row.expansion_mrr_cents,
          contraction_mrr_cents: row.contraction_mrr_cents, churned_mrr_cents: row.churned_mrr_cents,
          net_mrr_cents: row.net_mrr_cents, lifetime_revenue_cents: row.lifetime_revenue_cents,
          revenue_per_visitor_cents: row.value_per_visitor_cents
        }
      end
    end
  end
end
