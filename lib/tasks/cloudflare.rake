# Cloudflare's edge ranges, which decide whose IP address a request belongs to.
#
# See config/initializers/trusted_proxies.rb for why the ranges are an allowlist
# rather than a trusted CF-Connecting-IP header, and why getting this wrong costs
# far more than a country column.
namespace :tastatur do
  namespace :cloudflare do
    SOURCES = { "v4" => "https://www.cloudflare.com/ips-v4",
                "v6" => "https://www.cloudflare.com/ips-v6" }.freeze

    desc "Refresh config/cloudflare_ips.yml from Cloudflare's published ranges"
    task refresh: :environment do
      require "open-uri"

      fetched = SOURCES.transform_values do |url|
        puts "Fetching #{url}"
        URI.parse(url).open(&:read).split("\n").map(&:strip).reject(&:blank?)
      end

      # Parse before writing. A bad response — a captive portal, an error page —
      # would otherwise be written straight over a working list, and the failure
      # would not appear until boot.
      fetched.each_value do |ranges|
        ranges.each { |cidr| IPAddr.new(cidr) }
      end

      target = TrustedProxies::CLOUDFLARE_IPS_FILE
      previous = target.exist? ? YAML.safe_load_file(target) : {}

      body = <<~YAML
        # Cloudflare's published edge ranges, from #{SOURCES['v4']}
        # and #{SOURCES['v6']}.
        #
        # Used only when TRUST_CLOUDFLARE is enabled. See
        # config/initializers/trusted_proxies.rb for why this is an allowlist of ranges
        # rather than simply believing the CF-Connecting-IP header.
        #
        # Refresh with:  bin/rails tastatur:cloudflare:refresh
        #
        # Cloudflare changes these rarely, and a stale list fails in the visible
        # direction: a range we do not know about is treated as the client, so countries
        # go wrong again rather than silently going right.
        fetched_on: "#{Time.current.to_date.iso8601}"

        v4:
        #{fetched['v4'].map { |r| "  - #{r}" }.join("\n")}

        v6:
        #{fetched['v6'].map { |r| "  - #{r}" }.join("\n")}
      YAML

      target.write(body)

      added = fetched.values.flatten - previous.values_at("v4", "v6").compact.flatten
      removed = previous.values_at("v4", "v6").compact.flatten - fetched.values.flatten

      puts
      puts "Wrote #{target} (#{fetched['v4'].size} IPv4, #{fetched['v6'].size} IPv6)"
      puts "  added:   #{added.join(', ')}" if added.any?
      puts "  removed: #{removed.join(', ')}" if removed.any?
      puts "  no change" if added.empty? && removed.empty?
      puts
      puts "This only takes effect where TRUST_CLOUDFLARE is set. Redeploy to apply it."
    end

    desc "Report how the request chain will be resolved"
    task status: :environment do
      puts "TRUST_CLOUDFLARE:      #{TrustedProxies.cloudflare? ? 'on' : 'off'}"
      puts "TRUSTED_PROXY_RANGES:  #{ENV['TRUSTED_PROXY_RANGES'].presence || '(unset)'}"
      puts "trusted ranges total:  #{TrustedProxies.list.size}"

      if TrustedProxies.cloudflare?
        config = YAML.safe_load_file(TrustedProxies::CLOUDFLARE_IPS_FILE)
        puts "cloudflare list:       fetched #{config['fetched_on']}"
      end

      # The chain this deployment actually has, worked through end to end, so the
      # answer is demonstrated rather than asserted.
      client = "24.48.0.1"
      env = Rack::MockRequest.env_for("https://example.com/")
      env["REMOTE_ADDR"] = "100.64.0.5"
      env["HTTP_X_FORWARDED_FOR"] = "#{client}, 172.71.150.22"
      ActionDispatch::RemoteIp.new(->(_e) { [200, {}, []] }, true, TrustedProxies.list).call(env)
      resolved = ActionDispatch::Request.new(env).remote_ip

      puts
      puts "Worked example — client #{client} via Cloudflare 172.71.150.22 via CGNAT 100.64.0.5:"
      puts "  resolves to:  #{resolved}"
      puts "  country:      #{Ingest::Geolocation.country_code(resolved).inspect}"
      puts(resolved == client ? "  correct." : "  WRONG — this is a proxy address, not the visitor.")
    end
  end
end
