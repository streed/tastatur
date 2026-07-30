module Ingest
  # Classifies where a visit came from.
  #
  # Two things come out of this: a `source` (what a human wants to read —
  # "Google", "Hacker News", "example.com") and a `channel` (how a marketer
  # wants to group it — search, social, referral, direct, email).
  #
  # UTM parameters win over the referrer header when both are present, because
  # a UTM tag is an explicit statement of intent by whoever built the link and
  # the referrer is only ever a guess.
  #
  # Only the referrer's HOST is ever kept. The full referring URL can contain
  # search terms, session tokens, or a path that identifies an individual (a
  # password-reset link, a private document). The host is the part that answers
  # "where did they come from" and none of the part that does not.
  class Referrer
    DIRECT = "Direct".freeze

    CHANNELS = {
      "search" => "Organic Search",
      "social" => "Social",
      "email" => "Email",
      "referral" => "Referral",
      "direct" => "Direct",
      "paid" => "Paid"
    }.freeze

    class << self
      def sources
        @sources ||= begin
          raw = YAML.load_file(Rails.root.join("config/referrer_sources.yml"))
          raw.each_with_object({}) do |(channel, hosts), index|
            hosts.each { |host, name| index[host] = [name, channel] }
          end.freeze
        end
      end

      def reload!
        @sources = nil
        sources
      end
    end

    def initialize(referrer_url, utm: {}, site_domain: nil)
      @referrer_url = referrer_url.to_s
      @utm = utm || {}
      @site_domain = site_domain.to_s
    end

    # The host of the referring page, or nil for direct traffic and self-referrals.
    def host
      @host ||= begin
        uri = URI.parse(@referrer_url)
        value = uri.host&.downcase&.sub(/\Awww\./, "")
        # A link from one page of the site to another is not a traffic source;
        # counting it as one would make every site's top referrer itself.
        value.presence if value.present? && !same_site?(value)
      rescue URI::InvalidURIError
        nil
      end
    end

    def source
      return @utm[:utm_source].to_s.strip if @utm[:utm_source].present?
      return DIRECT if host.nil?

      known_source || host
    end

    def channel
      return CHANNELS["paid"] if paid?
      return CHANNELS[@utm[:utm_medium].to_s] if CHANNELS.key?(@utm[:utm_medium].to_s)
      return CHANNELS["direct"] if host.nil? && @utm[:utm_source].blank?

      CHANNELS[known_channel || "referral"]
    end

    def to_h
      { referrer_host: host, referrer_source: source }
    end

    private

    # A subdomain belongs to whoever owns the parent domain, so
    # news.google.com resolves to Google without needing its own entry.
    def lookup
      return @lookup if defined?(@lookup)
      return @lookup = nil if host.nil?

      @lookup = self.class.sources[host]
      return @lookup if @lookup

      parts = host.split(".")
      @lookup = (1...parts.length - 1).lazy
                                      .map { |i| self.class.sources[parts[i..].join(".")] }
                                      .find(&:itself)
    end

    def known_source = lookup&.first
    def known_channel = lookup&.last

    def paid?
      medium = @utm[:utm_medium].to_s.downcase
      medium.in?(%w[cpc ppc paid paidsearch paid-search cpm display banner paid_social paidsocial])
    end

    def same_site?(value)
      return false if @site_domain.blank?

      value == @site_domain || value.end_with?(".#{@site_domain}")
    end
  end
end
