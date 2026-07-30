module Ingest
  # Buffers events in Redis and writes them to PostgreSQL in batches.
  #
  # WHY NOT INSERT DIRECTLY: the ingest endpoint is called once per pageview on
  # every customer site at once, and it must answer in single-digit
  # milliseconds or it becomes a visible part of their page load. A per-event
  # round trip to PostgreSQL puts a transaction, a WAL flush and an fsync on
  # that path. Batching a few hundred events into one multi-row INSERT turns
  # hundreds of transactions into one, which is the difference between a few
  # hundred and several thousand events per second on modest hardware.
  #
  # THE TRADE: events live in Redis for up to FLUSH_INTERVAL before they are
  # durable. If the process dies in that window those events are lost. For
  # analytics that is the right trade — a handful of missing pageviews is
  # invisible in aggregate, while making every pageview durable-on-arrival
  # would cost an order of magnitude in throughput. It is written down here
  # because it is a real trade and not an oversight; anything that must not be
  # lost does not belong in this table.
  module WriteBuffer
    PENDING_KEY = "tastatur:ingest:pending".freeze

    # Flush when the buffer reaches this many events...
    FLUSH_SIZE = Integer(ENV.fetch("INGEST_FLUSH_SIZE", "250"))
    # ...or when this much time has passed, whichever comes first. The cron
    # entry in config/schedule.yml provides the time-based trigger.
    FLUSH_INTERVAL = Integer(ENV.fetch("INGEST_FLUSH_INTERVAL_SECONDS", "10")).seconds

    # Hard cap so one flush cannot try to build an unbounded INSERT if the
    # buffer has backed up badly.
    MAX_BATCH = 5_000

    # Rows PostgreSQL will never accept are moved here rather than being returned
    # to the buffer. Capped and expiring, because this is a diagnostic aid and not
    # a second database. Contains event rows only, so no IP and no user-agent.
    QUARANTINE_KEY = "tastatur:ingest:quarantine".freeze
    QUARANTINE_LIMIT = 500
    QUARANTINE_TTL = 7.days

    # Belt to the contract's braces. Any string wider than this is truncated
    # rather than allowed to bloat an INSERT; the contract already bounds every
    # field it knows about, so reaching this means a new field arrived without one.
    MAX_TEXT_BYTES = 4_096

    # Failures that will plausibly succeed on the next attempt. These are the only
    # ones for which returning the batch to the buffer and re-raising is correct.
    #
    # Everything else is treated as a property of the data, because the
    # alternative is what used to happen: a row PostgreSQL structurally cannot
    # store was pushed back onto the shared buffer and retried forever, so a
    # single event stopped writes for every site on the instance. A NUL byte in an
    # event name did it, and so did a revenue value above 2^31-1.
    TRANSIENT_ERRORS = [
      ActiveRecord::ConnectionNotEstablished,
      ActiveRecord::ConnectionFailed,
      ActiveRecord::StatementTimeout,
      ActiveRecord::LockWaitTimeout,
      ActiveRecord::Deadlocked,
      ActiveRecord::SerializationFailure,
      ConnectionPool::TimeoutError
    ].freeze

    # Column order is fixed here and used to build the INSERT. It must match
    # the events hypertable; a mismatch is caught by the spec in
    # spec/lib/ingest/write_buffer_spec.rb rather than at 3am.
    COLUMNS = %i[
      occurred_at site_id event_name visitor_hash session_hash is_entry
      hostname path referrer_host referrer_source
      utm_source utm_medium utm_campaign utm_term utm_content
      country_code browser browser_version os os_version device_type screen_class
      revenue_cents currency props
    ].freeze

    module_function

    # Called on the request path. Must stay cheap: one Redis round trip and
    # nothing else.
    def push(row)
      payload = Oj.dump(serialize(row), mode: :compat)

      depth = REDIS_POOL.with { |redis| redis.rpush(PENDING_KEY, payload) }

      # Size-based trigger. The job is idempotent and cheap when the buffer is
      # already empty, so an extra enqueue under a burst costs nothing.
      FlushEventBufferJob.perform_later if depth >= FLUSH_SIZE

      depth
    end

    # Drains up to MAX_BATCH events into PostgreSQL. Returns the number written.
    def flush!
      total = 0

      loop do
        batch = pop(FLUSH_SIZE)
        break if batch.empty?

        written, unwritten, transient = write_batch(batch)
        total += written

        if transient
          # A real database problem. Hand back everything that did not land and
          # let it raise, so Sidekiq retries and Sentry sees it.
          restore(unwritten)
          raise transient
        end

        break if total >= MAX_BATCH
      end

      total
    end

    # Writes a batch, isolating any row the database structurally refuses.
    #
    # Returns [rows_written, rows_not_written, transient_error_or_nil].
    #
    # On a non-transient failure the batch is halved and each half retried, which
    # narrows a poison row in log2(n) attempts without needing to know in advance
    # what makes it poison. A single row that still fails is quarantined and the
    # rest of the batch proceeds — the whole point being that one unstorable event
    # must not be able to stop everyone else's.
    #
    # A transient error stops the bisection immediately and reports the untried
    # remainder upward, so a database outage part-way through cannot silently
    # discard the rows that were never attempted.
    def write_batch(rows)
      # Each attempt gets its own savepoint.
      #
      # Without one, a server-side rejection — a revenue value past the int4
      # ceiling, say — aborts the surrounding transaction, and PostgreSQL then
      # refuses every following statement with "current transaction is aborted".
      # The bisection below would fail on all halves and quarantine the entire
      # batch instead of the one bad row. That is invisible in production, where
      # each INSERT is its own implicit transaction, and immediately visible under
      # RSpec's transactional fixtures — which is how it was caught.
      #
      # A NUL byte does not need this (libpq raises client-side before sending
      # anything, so there is nothing to abort), which is exactly why testing only
      # the NUL case would have looked fine.
      ActiveRecord::Base.connection.transaction(requires_new: true) { insert_all(rows) }
      [rows.size, [], nil]
    rescue *TRANSIENT_ERRORS => e
      [0, rows, e]
    rescue StandardError => e
      return [quarantine(rows.first, e), [], nil] if rows.one?

      middle = rows.size / 2
      first_written, first_left, first_error = write_batch(rows[0...middle])
      return [first_written, first_left + rows[middle..], first_error] if first_error

      second_written, second_left, second_error = write_batch(rows[middle..])
      [first_written + second_written, first_left + second_left, second_error]
    end

    # Sets a row aside and reports it. Returns 0, since nothing was written.
    def quarantine(row, error)
      Rails.logger.error(
        "[tastatur] quarantined an unstorable event for site #{row&.dig("site_id").inspect}: " \
        "#{error.class}: #{error.message.lines.first.to_s.strip}"
      )

      REDIS_POOL.with do |redis|
        redis.rpush(QUARANTINE_KEY, Oj.dump({ error: error.class.name, row: row }, mode: :compat))
        redis.ltrim(QUARANTINE_KEY, -QUARANTINE_LIMIT, -1)
        redis.expire(QUARANTINE_KEY, QUARANTINE_TTL.to_i)
      end

      0
    rescue StandardError => e
      # Never let the quarantine itself break the flush.
      Rails.logger.error("[tastatur] could not quarantine an event: #{e.message}")
      0
    end

    def quarantine_depth
      REDIS_POOL.with { |redis| redis.llen(QUARANTINE_KEY) }
    end

    def depth
      REDIS_POOL.with { |redis| redis.llen(PENDING_KEY) }
    end

    def clear!
      REDIS_POOL.with { |redis| redis.del(PENDING_KEY) }
    end

    # -- internals ------------------------------------------------------------

    def pop(count)
      raw = REDIS_POOL.with { |redis| redis.lpop(PENDING_KEY, count) }
      Array(raw).map { |json| Oj.load(json, mode: :compat) }
    end

    def restore(rows)
      payloads = rows.map { |row| Oj.dump(row, mode: :compat) }
      REDIS_POOL.with { |redis| redis.lpush(PENDING_KEY, payloads.reverse) }
    rescue StandardError => e
      # If we cannot even hand them back, say so loudly — this is the one path
      # where events are definitely lost.
      Rails.logger.error("[tastatur] lost #{rows.size} buffered events: #{e.message}")
    end

    # Binary columns travel through Redis as hex so the payload stays valid
    # JSON, and are converted back on the way into PostgreSQL.
    #
    # Text is scrubbed here, on the request path, because this is the last point
    # at which a bad value can be corrected rather than merely rejected. The
    # contract already refuses a NUL byte or invalid UTF-8 in the fields it knows
    # about; this catches anything derived afterwards (a scrubbed path, a referrer
    # host parsed out of a URL) and anything added to the row later by someone who
    # did not know this constraint existed.
    def serialize(row)
      scrub_values(
        row.merge(
          visitor_hash: row[:visitor_hash].unpack1("H*"),
          session_hash: row[:session_hash].unpack1("H*"),
          occurred_at: row[:occurred_at].utc.iso8601(3)
        )
      )
    end

    def scrub_values(value)
      case value
      when String
        scrub_text(value)
      when Hash
        # Symbol keys stay symbols. Only props arrives with string keys, and only
        # those can carry hostile bytes, so there is no reason to rewrite the
        # row's own key type on the way past.
        value.to_h { |key, nested| [key.is_a?(String) ? scrub_text(key) : key, scrub_values(nested)] }
      when Array
        value.map { |nested| scrub_values(nested) }
      else
        value
      end
    end

    # Makes a string storable in a PostgreSQL `text` column.
    #
    # Both of these raise on INSERT rather than being coerced, and libpq raises for
    # the NUL before the query is even sent, so neither is catchable as a database
    # error you can inspect and skip.
    def scrub_text(text)
      text = text.dup.force_encoding(Encoding::UTF_8) unless text.encoding == Encoding::UTF_8
      text = text.scrub("") unless text.valid_encoding?
      text = text.delete("\u0000") if text.include?("\u0000")
      return text if text.bytesize <= MAX_TEXT_BYTES

      # byteslice can cut a multi-byte character in half, so scrub again after.
      text.byteslice(0, MAX_TEXT_BYTES).to_s.scrub("")
    end

    def insert_all(rows)
      connection = ActiveRecord::Base.connection
      values = rows.map { |row| "(#{COLUMNS.map { |c| quote(connection, c, row) }.join(',')})" }

      connection.execute(<<~SQL.squish)
        INSERT INTO events (#{COLUMNS.join(', ')}) VALUES #{values.join(', ')}
      SQL
    end

    def quote(connection, column, row)
      value = row[column.to_s]

      case column
      when :visitor_hash, :session_hash
        # to_hex round-trips to bytea via PostgreSQL's \x literal form.
        connection.quote(ActiveRecord::Type::Binary::Data.new([value.to_s].pack("H*")))
      when :props
        value.blank? ? "NULL" : connection.quote(Oj.dump(value, mode: :compat)) + "::jsonb"
      when :occurred_at
        "#{connection.quote(value)}::timestamptz"
      when :is_entry
        value ? "TRUE" : "FALSE"
      else
        value.nil? ? "NULL" : connection.quote(value)
      end
    end
  end
end
