# Crediting the monthly allowance back is arithmetic, not a task, so it lives in a
# module rather than as a bare `def` in this file — a top-level `def` in a .rake
# file, including inside a `namespace` block, defines a private method on Object.
module TastaturEventPurge
  module_function

  # How many of the events about to be deleted fall inside the CURRENT calendar
  # month, which is the only counter still being enforced.
  #
  # Counted before the DELETE, because afterwards there is nothing left to count and
  # the total is no help: a purge window can span months, and crediting the whole of
  # it would hand back allowance for a month whose counter is not the one refusing
  # today's traffic.
  def current_month_count(where_sql, binds)
    month_start, month_end = Billing::UsageMeter.period_bounds
    overlap_from = [binds[1], month_start].max
    overlap_to = [binds[2], month_end].min
    return 0 if overlap_from >= overlap_to

    ActiveRecord::Base.connection.select_value(
      ActiveRecord::Base.sanitize_sql_array(
        ["SELECT COUNT(*) FROM events WHERE #{where_sql}", binds[0], overlap_from, overlap_to, *binds[3..]]
      )
    ).to_i
  end
end

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

      # Counted first: after the DELETE there is nothing left to count, and the
      # allowance can only be credited for the month whose counter is in force.
      creditable = TastaturEventPurge.current_month_count(sql, binds)

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

      # And give the allowance back, or this stops being an undo.
      #
      # Fabricated events consume the account's monthly allowance exactly like real
      # ones — the quota gate cannot tell them apart, which is the whole reason this
      # task exists. Deleting the rows without crediting the meter would leave the
      # victim's month spent and their genuine traffic refused until the 1st, so the
      # documented remedy would fix the reports and not the damage.
      #
      # Only the part of the purge inside the current month can be credited: the
      # meter is per calendar month and an older month's counter has already expired
      # or is no longer the one being enforced.
      if creditable.positive? && site.account.billable?
        Billing::UsageMeter.credit(site.account_id, count: creditable)
        Billing::EventQuota.forget(site.account_id)
        puts "Credited #{creditable} events back to #{site.account.name}'s monthly allowance " \
             "(now #{Billing::UsageMeter.used(site.account_id)})."
      end

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
