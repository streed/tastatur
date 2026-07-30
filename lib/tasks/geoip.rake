# The country database is not bundled with Tastatur.
#
# It is a third-party dataset with its own licence and its own update cadence,
# and vendoring a 10 MB binary into the repository would mean shipping a stale
# copy forever. This task fetches the current one.
#
# DB-IP IP-to-Country Lite is used rather than MaxMind GeoLite2 because it can be
# downloaded and redistributed under CC BY 4.0 with attribution, and needs no
# account, no licence key and no EULA acceptance. GeoLite2 has required an
# account since December 2019, and redistribution needs a paid licence, which
# breaks both "set up in minutes" and self-hostability.
namespace :tastatur do
  namespace :geoip do
    DB_IP_TEMPLATE = "https://download.db-ip.com/free/dbip-country-lite-%<year>d-%<month>02d.mmdb.gz".freeze

    desc "Download the DB-IP IP-to-Country Lite database (country-level geolocation)"
    task download: :environment do
      require "open-uri"
      require "zlib"

      target = Ingest::Geolocation.path
      FileUtils.mkdir_p(target.dirname)

      # DB-IP publishes monthly and removes old files, so fall back a month if
      # the current one is not up yet.
      urls = [Time.current, 1.month.ago].map do |time|
        format(DB_IP_TEMPLATE, year: time.year, month: time.month)
      end

      downloaded = urls.find do |url|
        puts "Fetching #{url}"
        begin
          URI.parse(url).open do |gz|
            File.open(target, "wb") { |out| out.write(Zlib::GzipReader.new(gz).read) }
          end
          true
        rescue OpenURI::HTTPError => e
          puts "  not available (#{e.message})"
          false
        end
      end

      abort "Could not download a country database. Tried:\n  #{urls.join("\n  ")}" unless downloaded

      Ingest::Geolocation.reload!

      puts
      puts "Wrote #{target} (#{ActiveSupport::NumberHelper.number_to_human_size(target.size)})"
      puts "Country reporting is now enabled. Sanity check: 1.1.1.1 resolves to " \
           "#{Ingest::Geolocation.country_code('1.1.1.1').inspect}"
      puts
      puts "ATTRIBUTION IS REQUIRED. CC BY 4.0 obliges you to credit DB-IP wherever"
      puts "this data is surfaced. Tastatur already does so on /privacy; if you"
      puts "remove that, add the credit somewhere else."
    end

    desc "Report whether country geolocation is configured"
    task status: :environment do
      if Ingest::Geolocation.available?
        path = Ingest::Geolocation.path
        puts "Enabled. Database: #{path} " \
             "(#{ActiveSupport::NumberHelper.number_to_human_size(path.size)}, " \
             "updated #{path.mtime.to_date})"
        %w[1.1.1.1 8.8.8.8 2001:4860:4860::8888].each do |ip|
          puts "  #{ip.ljust(22)} -> #{Ingest::Geolocation.country_code(ip).inspect}"
        end
      else
        puts "Disabled. No database at #{Ingest::Geolocation.path}."
        puts "Country breakdowns will be empty; everything else works normally."
        puts "Run `rails tastatur:geoip:download` to enable it."
      end
    end
  end

  namespace :privacy do
    desc "Destroy all visitor salts immediately, making stored hashes permanently unlinkable"
    task purge_salts: :environment do
      Ingest::SaltStore.destroy_all!
      puts "All visitor salts destroyed."
      puts "Every stored visitor hash is now permanently unlinkable to any future observation."
      puts "Visitors currently browsing will be counted as new visitors."
    end

    desc "Enforce per-account data retention now instead of waiting for the nightly job"
    task enforce_retention: :environment do
      report = Privacy::EnforceDataRetention.call.value!
      puts "Deleted #{report.events_deleted} events across #{report.accounts_processed} accounts."
    end
  end
end
