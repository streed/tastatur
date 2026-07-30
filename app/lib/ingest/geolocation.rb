module Ingest
  # Country-level IP geolocation, and nothing finer.
  #
  # We resolve to an ISO country code and stop. No region, no city, no
  # coordinates, no ASN. This is a deliberate product limit, not a gap:
  # city-level location combined with a device profile and a visit time is
  # identifying for a person in a small town, which is precisely the kind of
  # inference this product exists to avoid. A country code shared with millions
  # of people is not.
  #
  # The database file is not bundled. It is a separate download under its own
  # licence (see docs/self-hosting/geolocation.md), and until it is present
  # this returns nil for everything — geolocation is an optional enrichment, so
  # a fresh install works immediately and simply shows no country breakdown.
  module Geolocation
    DEFAULT_PATH = Rails.root.join("db/geoip/country.mmdb").freeze

    class << self
      def available?
        reader.present?
      end

      def path
        Pathname.new(ENV.fetch("GEOIP_DB_PATH") { DEFAULT_PATH.to_s })
      end

      # Returns a two-letter uppercase country code, or nil.
      def country_code(ip)
        return nil if ip.blank?
        return nil unless available?

        record = reader.get(ip)
        code = record&.dig("country", "iso_code") || record&.dig("registered_country", "iso_code")
        code&.upcase&.presence
      rescue IPAddr::InvalidAddressError, ArgumentError
        # A malformed address from a spoofed header is not an error worth
        # raising — the event is still perfectly usable without a country.
        nil
      end

      # The reader mmaps the database once per process and is thread-safe for
      # reads, so a lookup costs no allocation and no I/O syscall in the steady
      # state. Memoized on nil as well, so a missing file is not re-checked on
      # every request.
      def reader
        return @reader if defined?(@reader)

        @reader = if path.exist?
                    MaxMind::DB.new(path.to_s, mode: MaxMind::DB::MODE_MEMORY)
        else
                    Rails.logger.info(
                      "[tastatur] No GeoIP database at #{path} — country reporting is disabled. " \
                      "Run `rails tastatur:geoip:download` to enable it."
                    )
                    nil
        end
      end

      # Used by the download task and by specs.
      def reload!
        remove_instance_variable(:@reader) if defined?(@reader)
        reader
      end
    end
  end
end
