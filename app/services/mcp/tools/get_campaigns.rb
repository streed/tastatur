module Mcp
  module Tools
    class GetCampaigns < Base
      NAME = "get_campaigns".freeze
      DESCRIPTION = "Traffic from UTM-tagged campaigns: per-campaign totals, and the individual source / medium / " \
                    "campaign / term / content combinations underneath. Traffic only; for money use " \
                    "get_revenue_attribution.".freeze
      PROPERTIES = Base::PERIOD_PROPERTIES
      REQUIRED = [].freeze
      CONTRACT = McpPeriodContract

      private

      def run
        case Analytics::CampaignReport.call(site: site, period: period)
        in Success(report)
          result(
            {
              period: period_data,
              campaigns: report.campaign_performance.rows.map { |row| totals_data(row) },
              links: report.rows.map { |row| link_data(row) },
              withheld: {
                rows: report.suppressed_rows, visitors: report.suppressed_visitors,
                reason: "Combinations with fewer than #{report.threshold} visitors are withheld to keep visitors anonymous."
              },
              truncated: report.truncated?
            },
            ["Add up `campaigns` figures only as given: a campaign's visitors are counted once there, while " \
             "summing its `links` rows counts anybody who followed two links twice."]
          )
        end
      end

      def totals_data(row)
        { campaign: row.utm_campaign.presence || "(none)", visitors: row.visitors, visits: row.visits, pageviews: row.pageviews }
      end

      def link_data(row)
        {
          source: row.utm_source, medium: row.utm_medium, campaign: row.campaign,
          term: row.utm_term, content: row.utm_content,
          visitors: row.visitors, visits: row.visits, pageviews: row.pageviews
        }
      end
    end
  end
end
