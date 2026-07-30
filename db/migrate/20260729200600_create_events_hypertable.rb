class CreateEventsHypertable < ActiveRecord::Migration[8.1]
  # `create_hypertable` itself is transaction-safe, but keeping this migration
  # outside a transaction means a failure part-way leaves a diagnosable state
  # rather than a silent rollback of a partially-converted table.
  disable_ddl_transaction!

  def up
    create_table :events, id: false do |t|
      # --- Partitioning key -------------------------------------------------
      # Always UTC. Per-site reporting timezones are applied at query time via
      # time_bucket(..., timezone), never by storing local time.
      t.timestamptz :occurred_at, null: false

      t.bigint :site_id, null: false

      # "pageview" for page views; any other value is a custom event sent via
      # tastatur('event', 'Name'). Not a foreign key to goals — goals are
      # defined after the fact and match against this string.
      t.text :event_name, null: false, default: "pageview"

      # --- Cookieless identity ---------------------------------------------
      # SHA-256(daily_salt || ip || user_agent || site_id), truncated to 16
      # bytes. The salt is destroyed every 24h, so these are unlinkable across
      # days by construction — nobody, including us, can rejoin them.
      #
      # Truncation is deliberate: 128 bits is far beyond collision risk for a
      # single day of one site's traffic, and holding less of the digest means
      # holding less of a re-identification handle.
      #
      # The raw IP and user-agent are NEVER written to this table, or anywhere
      # else. They exist only as local variables during hashing.
      t.binary :visitor_hash, null: false, limit: 16
      t.binary :session_hash, null: false, limit: 16

      # True for the first event of a session. Lets entry-page and bounce
      # metrics be computed without re-deriving session boundaries at query
      # time.
      t.boolean :is_entry, null: false, default: false

      # --- Page -------------------------------------------------------------
      t.text :hostname
      # Query strings are stripped before storage; only allowlisted params
      # (the utm_* set) survive, into their own columns below.
      t.text :path, null: false

      # --- Acquisition ------------------------------------------------------
      t.text :referrer_host          # "news.ycombinator.com"
      t.text :referrer_source        # grouped: "Hacker News", "Google", "Direct"
      t.text :utm_source
      t.text :utm_medium
      t.text :utm_campaign
      t.text :utm_term
      t.text :utm_content

      # --- Coarse environment ----------------------------------------------
      # Country only. No region, no city, no coordinates — city-level geo plus
      # a device profile is identifying in low-population areas, which is
      # exactly what we promise not to collect.
      # text, not varchar(2): TimescaleDB warns that varchar columns do not
      # follow best practice because they compress less predictably in the
      # columnstore. Length is enforced by a check constraint instead.
      t.text :country_code

      t.text :browser
      t.text :browser_version        # major version only, e.g. "127"
      t.text :os
      t.text :os_version
      t.text :device_type            # desktop | mobile | tablet

      # Bucketed, never the raw viewport. Exact screen dimensions are one of
      # the highest-entropy fingerprinting signals; six buckets are enough to
      # answer "is my site used on mobile" and carry almost no entropy.
      t.text :screen_class           # xs | sm | md | lg | xl

      # --- Conversion value -------------------------------------------------
      t.integer :revenue_cents
      t.text    :currency

      # Custom event properties. JSONB rather than an EAV side table: props are
      # read as a whole, are small, and a join per event on a hypertable this
      # size would be far more expensive than the storage saved.
      t.jsonb :props
    end

    # A hypertable cannot have a plain `id` primary key — any unique index must
    # include the partitioning column (verified: "cannot create a unique index
    # without the column occurred_at (used in partitioning)"). We do not need
    # row identity here, so the table has no primary key at all.
    #
    # 7-day chunks: small installs get a handful of chunks rather than hundreds
    # of near-empty daily ones, and a busy site still lands well inside the
    # "recent chunks should fit in memory" guidance.
    execute <<~SQL
      SELECT create_hypertable(
        'events',
        by_range('occurred_at', INTERVAL '7 days'),
        create_default_indexes => false,
        if_not_exists          => true
      );
    SQL

    # Every dashboard query filters by site first, then by time. The default
    # time-only index Timescale would have created is pure write overhead for
    # this access pattern, which is why it was suppressed above.
    add_index :events, %i[site_id occurred_at], order: { occurred_at: :desc },
                       name: "idx_events_site_time"

    # Funnels and sessionisation walk one visitor's events in order.
    add_index :events, %i[site_id visitor_hash occurred_at],
                       name: "idx_events_site_visitor_time"

    # Goal matching and custom-event breakdowns filter on the event name.
    # Partial: "pageview" is the overwhelming majority of rows and is never
    # looked up this way, so excluding it keeps the index small.
    add_index :events, %i[site_id event_name occurred_at],
                       order: { occurred_at: :desc },
                       where: "event_name <> 'pageview'",
                       name: "idx_events_site_custom_event_time"

    add_check_constraint :events, "country_code ~ '^[A-Z]{2}$'",
                         name: "events_country_code_check", validate: false
    add_check_constraint :events, "currency ~ '^[A-Z]{3}$'",
                         name: "events_currency_check", validate: false

    # --- Columnstore ------------------------------------------------------
    # Analytics rows are written once and then only ever scanned in bulk, so
    # older chunks are converted to columnar storage. Segmenting by site_id
    # means a single tenant's data stays contiguous within a chunk.
    execute <<~SQL
      ALTER TABLE events SET (
        timescaledb.enable_columnstore = true,
        timescaledb.segmentby          = 'site_id',
        timescaledb.orderby            = 'occurred_at DESC'
      );
    SQL

    # NOTE: add_columnstore_policy is a PROCEDURE — `SELECT` raises
    # "add_columnstore_policy(...) is a procedure".
    execute <<~SQL
      CALL add_columnstore_policy('events', after => INTERVAL '14 days', if_not_exists => true);
    SQL

    # Backstop retention. Per-account limits are usually shorter and are
    # enforced separately by EnforceDataRetention; this only guarantees that
    # nothing survives past the longest retention we ever offer.
    execute <<~SQL
      SELECT add_retention_policy('events', drop_after => INTERVAL '400 days', if_not_exists => true);
    SQL
  end

  def down
    execute "SELECT remove_retention_policy('events', if_exists => true);"
    execute "CALL remove_columnstore_policy('events', if_exists => true);"
    drop_table :events
  end
end
