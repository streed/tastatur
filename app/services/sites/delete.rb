module Sites
  # Deletes a site and every event ever recorded for it.
  #
  # The event rows are NOT covered by the foreign key that removes goals and
  # funnels: the events hypertable has no foreign key to sites at all, because a
  # per-row constraint check on the ingest path would be a needless cost on the
  # hottest write in the system. So they are removed explicitly here.
  #
  # This doubles as the erasure mechanism for a controller who has been asked to
  # delete their analytics — see docs/privacy/data-requests.md — which is why the
  # continuous aggregates are reconciled too. Deleting the raw rows alone leaves
  # every one of them in all three aggregates, including the visitor-grain one,
  # and the scheduled refresh policies never look back far enough to notice.
  class Delete < ApplicationService
    def initialize(site:)
      @site = site
    end

    def call
      site_id = @site.id
      token = @site.public_token

      # Captured BEFORE the delete, because afterwards there is nothing left to
      # derive the range from, and reconciling the aggregates needs to know which
      # window to recompute.
      window = event_window(site_id)

      ActiveRecord::Base.transaction do
        # Raw DELETE rather than Event.where(...).delete_all so the hypertable is
        # addressed directly and no ActiveRecord model instantiation happens for
        # what may be millions of rows.
        ActiveRecord::Base.connection.execute(
          ActiveRecord::Base.sanitize_sql_array(["DELETE FROM events WHERE site_id = ?", site_id])
        )
        @site.destroy!
      end

      # The ingest path caches token -> site for a minute; drop it now so a
      # deleted site stops collecting immediately rather than at TTL.
      Rails.cache.delete("site/token/#{token}")

      # Enqueued rather than inline for two reasons: refresh_continuous_aggregate
      # cannot run inside a transaction, and recomputing a multi-year window
      # touches every site's buckets in it, which does not belong in a web
      # request. The job runs immediately, so the gap is seconds.
      ReconcileAggregatesJob.perform_later(window[:from], window[:to]) if window

      Success(site_id)
    end

    private

    def event_window(site_id)
      row = ActiveRecord::Base.connection.select_one(
        ActiveRecord::Base.sanitize_sql_array(
          ["SELECT MIN(occurred_at) AS f, MAX(occurred_at) AS t FROM events WHERE site_id = ?", site_id]
        )
      )
      return nil if row.nil? || row["f"].nil?

      { from: row["f"], to: row["t"] }
    end
  end
end
