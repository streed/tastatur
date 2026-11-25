module Mcp
  module Tools
    class ListSites < Base
      NAME = "list_sites".freeze
      DESCRIPTION = "The sites this key can read: domain, token and timezone. Every other tool takes one of " \
                    "them as `site`, so call this first when the account has more than one.".freeze
      PROPERTIES = {}.freeze
      REQUIRED = [].freeze
      CONTRACT = McpEmptyContract

      def self.needs_site? = false

      private

      def run
        sites = account.sites.order(:domain)

        result(
          { account: account.name, sites: sites.map { |site| { domain: site.domain, token: site.public_token, timezone: site.timezone } } },
          ["Pass a domain or token as `site` to any other tool. With only one site you may omit it."]
        )
      end
    end
  end
end
