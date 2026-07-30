namespace :tastatur do
  namespace :events do
    desc "Delete events for a site in a time window (SITE=token FROM=iso TO=iso [PATH=/x] [DRY_RUN=1])"
    task purge: :environment do
      # The reversal half of the anti-poisoning story.
      #
      # Hostname validation and the Origin check stop most abuse, and the rate
      # limits bound the rest, but someone spoofing a site's real domain from a
      # script cannot be prevented — only detected and undone. This is the undo.
      #
      # Scoped by site_id, which is the columnstore `segmentby` key, so the DELETE
      # only decompresses that site's segments rather than the whole hypertable.
      # An unscoped DELETE over compressed chunks fails outright with
      # "tuple decompression limit exceeded".
      token = ENV["SITE"] or abort "SITE=<public_token> is required"
      site = Site.find_by(public_token: token) or abort "No site with token #{token}"

      from = ENV["FROM"] ? Time.zone.parse(ENV["FROM"]) : abort("FROM=<iso8601> is required")
      to   = ENV["TO"]   ? Time.zone.parse(ENV["TO"])   : abort("TO=<iso8601> is required")
      abort "FROM must be before TO" if from >= to

      sql = +"site_id = ? AND occurred_at >= ? AND occurred_at < ?"
      binds = [site.id, from, to]
      if ENV["PATH_PREFIX"].present?
        sql << " AND path LIKE ?"
        binds << "#{ENV['PATH_PREFIX'].gsub(/[\\%_]/) { |c| "\\#{c}" }}%"
      end

      count = ActiveRecord::Base.connection.select_value(
        ActiveRecord::Base.sanitize_sql_array(["SELECT COUNT(*) FROM events WHERE #{sql}", *binds])
      ).to_i

      puts "Site:    #{site.domain} (#{site.public_token})"
      puts "Window:  #{from.iso8601} .. #{to.iso8601}"
      puts "Filter:  path LIKE #{ENV['PATH_PREFIX']}%" if ENV["PATH_PREFIX"].present?
      puts "Matches: #{count} events"

      if ENV["DRY_RUN"] == "1"
        puts "\nDRY_RUN=1, nothing deleted. Re-run without it to proceed."
        next
      end
      if count.zero?
        puts "\nNothing to do."
        next
      end

      deleted = ActiveRecord::Base.connection.exec_delete(
        ActiveRecord::Base.sanitize_sql_array(["DELETE FROM events WHERE #{sql}", *binds]),
        "PurgeEvents"
      )
      puts "Deleted #{deleted} events."

      # Deleting raw rows does NOT remove them from the continuous aggregates, and
      # the refresh policies only look back 3 to 10 days, so without this the
      # purged events keep appearing in every report. See
      # docs/architecture/aggregates.md.
      print "Reconciling aggregates... "
      Analytics::ReconcileAggregates.call(from: from, to: to)
      puts "done."
      puts "\nReports for this window now reflect the purge."
    end

    desc "Show ingest rejections for a site (SITE=token)"
    task rejections: :environment do
      token = ENV["SITE"] or abort "SITE=<public_token> is required"
      site = Site.find_by(public_token: token) or abort "No site with token #{token}"

      counts = site.rejection_counts
      puts "Rejected ingest for #{site.domain}, last 7 days:"
      counts.each { |reason, n| puts format("  %-20s %d", reason, n) }

      hosts = site.rejected_hostnames(limit: 10)
      if hosts.any?
        puts "\nMost-refused hostnames:"
        hosts.each { |host, n| puts format("  %-40s %d", host, n) }
        puts "\nIf one of these is yours, add it under Site settings -> additional hostnames."
        puts "If none of them are, someone is using your site key. The numbers you see are"
        puts "the real ones; the rejected traffic was never recorded."
      else
        puts "\nNo rejected hostnames recorded."
      end
    end
  end
end
