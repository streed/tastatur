# Which addresses in front of us are proxies, and which one is the visitor.
#
# `request.remote_ip` is the single input to two things this product is built on:
# the country breakdown, and the visitor identity itself — `Ingest::Identifier`
# mixes the address into the HMAC. So when Rails picks the wrong address out of
# the forwarding chain, the damage is not a cosmetic country column. Every
# visitor arriving through the same proxy hashes to the SAME visitor, on a site
# where counting distinct people is the entire product.
#
# Rails' default trusted list is loopback and the RFC 1918 private ranges, and it
# takes the right-most address that is not in it. That is correct for one private
# reverse proxy and wrong for a public edge:
#
#   client → Cloudflare → Railway → app
#   X-Forwarded-For: 24.48.0.1, 172.71.150.22
#                    ^ the visitor  ^ Cloudflare, a PUBLIC address
#
# Cloudflare's edge is not in any private range, so Rails stops there and reports
# 172.71.150.22 — measured, not assumed: it resolves to "US" for every visitor on
# earth, and gives every one of them an identical visitor hash. When the platform
# hop is carrier-grade NAT (100.64.0.0/10) or an IPv6 ULA instead, the same
# mistake resolves to no country at all and the breakdown reads "Unknown" for
# everything, which is how this was noticed.
#
# Two additions, for two different reasons:
#
# RFC 6598 (100.64.0.0/10) and IPv6 ULA (fd00::/8) are added unconditionally.
# Neither is routable on the public internet, so neither can ever be a real
# visitor's address; they only ever appear here as platform plumbing. Rails omits
# them because they postdate its list, not because trusting them is a judgement
# call.
#
# TRUST_CLOUDFLARE covers the common case, because only the operator knows what
# sits in front of them and "Cloudflare" is what sits in front of most people. It
# loads Cloudflare's published ranges from config/cloudflare_ips.yml.
#
# It is an allowlist of ranges rather than simply believing the CF-Connecting-IP
# header, which is the more usual advice and is wrong here: the platform's origin
# URL stays reachable directly, so a header trusted unconditionally is a header
# anyone can set — and forging it would let someone choose their own country,
# their own visitor identity, and their own rate-limit bucket. Trusting the range
# instead means a forged X-Forwarded-For entry is just another untrusted hop to
# the LEFT of the real client, which is exactly where Rails' right-most rule
# ignores it.
#
# It is opt-in rather than always-on because Cloudflare's ranges are also the
# exit addresses of Cloudflare WARP. On an install that is NOT behind Cloudflare,
# trusting them would discard the real address of every WARP user and take
# whatever sat to their left.
#
# TRUSTED_PROXY_RANGES is the escape hatch for everything else — another CDN, a
# corporate load balancer, a bastion.
module TrustedProxies
  # Never routable, so never a visitor. See RFC 6598 and RFC 4193.
  PLATFORM_INTERNAL = %w[100.64.0.0/10 fd00::/8].freeze

  CLOUDFLARE_IPS_FILE = Rails.root.join("config/cloudflare_ips.yml")

  def self.cloudflare?
    ActiveModel::Type::Boolean.new.cast(ENV["TRUST_CLOUDFLARE"]).present?
  end

  def self.cloudflare_ranges
    return [] unless cloudflare?

    unless CLOUDFLARE_IPS_FILE.exist?
      raise "TRUST_CLOUDFLARE is set but #{CLOUDFLARE_IPS_FILE} is missing. " \
            "Run `bin/rails tastatur:cloudflare:refresh`."
    end

    config = YAML.safe_load_file(CLOUDFLARE_IPS_FILE)
    parse(config.values_at("v4", "v6").compact.flatten.join(","))
  end

  # A typo here would silently drop a range and quietly restore the bug, so an
  # unparseable entry stops boot instead. This runs once at startup.
  def self.parse(value)
    value.to_s.split(/[,\s]+/).reject(&:blank?).map do |cidr|
      IPAddr.new(cidr)
    rescue IPAddr::InvalidAddressError, IPAddr::InvalidPrefixError => e
      raise "TRUSTED_PROXY_RANGES contains #{cidr.inspect}, which is not a valid CIDR (#{e.message})"
    end
  end

  def self.list
    ActionDispatch::RemoteIp::TRUSTED_PROXIES +
      parse(PLATFORM_INTERNAL.join(",")) +
      cloudflare_ranges +
      parse(ENV["TRUSTED_PROXY_RANGES"])
  end
end

Rails.application.config.action_dispatch.trusted_proxies = TrustedProxies.list
