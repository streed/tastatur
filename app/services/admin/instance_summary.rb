module Admin
  # The numbers on the admin overview.
  #
  # Deliberately about the INSTANCE — accounts, users, sites, whether the moving
  # parts are moving — and never about anybody's audience. There is no visitor
  # figure here, no country, no page. The one event number is a total row count,
  # which is an operational capacity question rather than a fact about anyone.
  class InstanceSummary < ApplicationService
    Counts = Struct.new(:users, :admins, :accounts, :sites, :events_24h,
                        :signups_7d, :unconfirmed, :locked, :sites_awaiting_data,
                        keyword_init: true)

    Health = Struct.new(:geoip, :salt, :buffer_depth, :queues, keyword_init: true)

    Summary = Struct.new(:counts, :health, :recent_users, keyword_init: true)

    RECENT = 10

    def call
      Success(Summary.new(counts: counts, health: health, recent_users: recent_users))
    end

    private

    def counts
      Counts.new(
        users: User.count,
        admins: User.administrators.count,
        accounts: Account.count,
        sites: Site.count,
        events_24h: events_since(24.hours.ago),
        signups_7d: User.where(created_at: 7.days.ago..).count,
        unconfirmed: User.where(confirmed_at: nil).count,
        locked: User.where.not(locked_at: nil).count,
        sites_awaiting_data: Site.where(first_event_at: nil).count
      )
    end

    # A bounded count over the hypertable. `COUNT(*)` across all chunks on a busy
    # instance is a table scan nobody asked for, so this is scoped to the window
    # the number claims to describe and rides the time partitioning.
    def events_since(time)
      ActiveRecord::Base.connection.select_value(
        ActiveRecord::Base.sanitize_sql_array(
          ["SELECT COUNT(*) FROM events WHERE occurred_at >= ?", time]
        )
      ).to_i
    end

    def health
      Health.new(
        geoip: Ingest::Geolocation.available?,
        salt: salt_store_reachable,
        buffer_depth: buffer_depth,
        queues: queue_depths
      )
    end

    # Both of these talk to Redis, and Redis being down is exactly the condition
    # an operator opens this page to diagnose. A page that 500s in that state is
    # useless precisely when it is needed, so a failure reports itself as a value
    # the view can render rather than as an exception.
    #
    # This is not a `rescue => e` that hides a problem: the same outage is
    # reported to Sentry from the ingest path, where it is an incident. Here it is
    # the thing being displayed.
    def buffer_depth
      Ingest::WriteBuffer.depth
    rescue *Ingest::RecordEvent::STORAGE_FAILURES
      :unavailable
    end

    # Reachability, not presence. Salts are per site and are minted on that site's
    # first event of its local day, so on a quiet instance there may legitimately
    # be none — which is not a fault and must not be reported as one. What an
    # operator opens this page to learn is whether the privacy Redis is up, since
    # if it is not then no event can be identified and ingest is dropping
    # everything.
    def salt_store_reachable
      Ingest::SaltStore.available?
    rescue *Ingest::RecordEvent::STORAGE_FAILURES
      false
    end

    def queue_depths
      Sidekiq::Queue.all.to_h { |queue| [queue.name, queue.size] }
    rescue *Ingest::RecordEvent::STORAGE_FAILURES
      :unavailable
    end

    def recent_users
      User.by_recency.limit(RECENT).includes(:accounts)
    end
  end
end
