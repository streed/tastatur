module Analytics
  # Lifetime totals for a LIST of sites, in one query — what the sites index
  # shows above and beside the list.
  #
  # Read from events_by_hour rather than the raw hypertable, and that is what
  # makes an all-time number affordable at all: the aggregate holds 24 rows per
  # site per day whatever the traffic, so summing every bucket a site has ever
  # had is a few thousand rows, while COUNT(*) over `events` with no time bound
  # is a scan of every chunk on the instance. That is the trap
  # Admin::InstanceSummary avoids by bounding its own event count to 24 hours,
  # and this avoids by never touching the raw table.
  #
  # ONE QUERY FOR THE WHOLE LIST, not one per site. A site limit of 20 would
  # otherwise make the index twenty round trips that each look cheap.
  #
  # EVERY COLUMN HERE IS A PLAIN COUNT, which is the other half of why this is
  # allowed at all: counts sum across buckets. `visitors` and `sessions` are
  # distinct counts and must never be summed (CLAUDE.md §8), so they are absent —
  # and an all-time unique visitor number could not be honest even taken exactly
  # from visitor_days, because the salt rotates at each site's local midnight and
  # the same person is a new visitor tomorrow. Summed over a year it would be a
  # count of visitor-days wearing the word "visitors".
  #
  # `entries` is neither of those things and is safe: it is
  # COUNT(*) FILTER (WHERE is_entry), and a session's entry event happens exactly
  # once, so summing it counts visits STARTED rather than counting anybody twice.
  # It is a hair's breadth from the dashboard's "Visits", which reads session_days
  # and therefore splits a session that crosses UTC midnight in two — the known
  # asymmetry in docs/architecture/aggregates.md. Different windows, so the two
  # numbers are never on screen together.
  #
  # WHAT "ALL TIME" MEANS IS BOUNDED BY RETENTION, deliberately.
  # Privacy::EnforceDataRetention deletes events past each account's window and
  # reconciles the aggregates behind it, so these totals describe what the
  # instance still holds rather than everything it ever received. That is the
  # honest number to show a customer who has just shortened their retention.
  class SiteTotals < ApplicationService
    class Totals < Dry::Struct
      transform_keys(&:to_sym)

      attribute :pageviews,     Types::Strict::Integer
      attribute :custom_events, Types::Strict::Integer
      attribute :visits,        Types::Strict::Integer
    end

    ZERO = Totals.new(pageviews: 0, custom_events: 0, visits: 0).freeze

    class Result < Dry::Struct
      transform_keys(&:to_sym)

      attribute :by_site_id, Types::Hash.map(Types::Strict::Integer, Totals)
      attribute :total,      Totals

      # Zero-filled. A site that has never received an event has no buckets at
      # all, so its row has to be told what to show rather than left to a nil.
      def for_site(site)
        by_site_id.fetch(site.id, ZERO)
      end
    end

    def initialize(sites:)
      @site_ids = sites.map(&:id)
    end

    def call
      totals = totals_by_site_id

      Success(Result.new(by_site_id: totals, total: sum_of(totals.values)))
    end

    private

    def totals_by_site_id
      return {} if @site_ids.empty?

      rows.to_h do |row|
        [
          row["site_id"],
          Totals.new(
            pageviews: row["pageviews"].to_i,
            custom_events: row["custom_events"].to_i,
            visits: row["visits"].to_i
          )
        ]
      end
    end

    def rows
      ActiveRecord::Base.connection.select_all(
        ActiveRecord::Base.sanitize_sql_array(
          [<<~SQL, @site_ids]
            SELECT site_id,
                   SUM(pageviews)     AS pageviews,
                   SUM(custom_events) AS custom_events,
                   SUM(entries)       AS visits
            FROM events_by_hour
            WHERE site_id IN (?)
            GROUP BY site_id
          SQL
        )
      ).to_a
    end

    # Summed in Ruby rather than by a second GROUP BY: the rows are already
    # loaded, there are at most a plan's worth of them, and a second query could
    # disagree with the first about a site that received an event between them.
    def sum_of(totals)
      Totals.new(
        pageviews: totals.sum(&:pageviews),
        custom_events: totals.sum(&:custom_events),
        visits: totals.sum(&:visits)
      )
    end
  end
end
