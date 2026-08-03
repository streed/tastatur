module Tastatur
  # Truncation helper for specs that cannot run inside a transaction.
  #
  # Specs tagged `:continuous_aggregate` need to call
  # `refresh_continuous_aggregate()`, which TimescaleDB refuses to run inside a
  # transaction block. Those examples therefore run without the usual
  # transactional rollback and clean up here instead.
  module TestDatabase
    module_function

    # Hypertable chunks and continuous-aggregate materializations live in
    # TimescaleDB's internal schemas and must never be truncated directly —
    # truncating the parent hypertable cascades to its chunks correctly, and
    # refreshing the aggregate afterwards clears the materialization.
    def truncatable_tables
      @truncatable_tables ||= begin
        conn = ActiveRecord::Base.connection
        internal = conn.select_values(<<~SQL)
          SELECT format('%I.%I', hypertable_schema, hypertable_name)
          FROM timescaledb_information.continuous_aggregates
        SQL

        (conn.tables - %w[schema_migrations ar_internal_metadata] - internal).sort
      end
    end

    def truncate!
      return if truncatable_tables.empty?

      ActiveRecord::Base.connection.execute(
        "TRUNCATE TABLE #{truncatable_tables.join(', ')} RESTART IDENTITY CASCADE"
      )
    end

    # Materialized aggregate rows survive `truncate!` — the internal
    # materialization hypertables are excluded from it above, and the supported
    # way to clear them is to re-refresh over an emptied raw table, which no
    # transactional spec can do (refresh_continuous_aggregate refuses to run
    # inside a transaction).
    #
    # So they accumulate, and that is a problem for exactly one kind of report. A
    # `:continuous_aggregate` example materializes rows, truncates, and RESTARTS
    # THE ID SEQUENCE, so the next factory-built site gets an id whose buckets are
    # already sitting in the aggregate. Anything bounded by a period never asks
    # for those buckets; an ALL-TIME query (Analytics::SiteTotals) has no window
    # to exclude them with and reads a stranger's leftovers as its own site's
    # traffic. Measured: 30 rows dated ~200 days back, for site ids 1 and 2, left
    # behind by spec/services/sites/delete_spec.rb.
    #
    # A DELETE is safe where the TRUNCATE warned about above is not: it is
    # ordinary DML inside the calling example's transaction, so it rolls back with
    # everything else and the rows are still there for whatever spec runs next.
    def clear_materialized_aggregates!
      materialization_tables.each do |table|
        ActiveRecord::Base.connection.execute("DELETE FROM #{table}")
      end
    end

    def materialization_tables
      @materialization_tables ||= ActiveRecord::Base.connection.select_values(<<~SQL)
        SELECT format('%I.%I', materialization_hypertable_schema, materialization_hypertable_name)
        FROM timescaledb_information.continuous_aggregates
      SQL
    end

    # Materialize a continuous aggregate over the whole time range so specs can
    # assert on rolled-up numbers. Must not be called inside a transaction.
    def refresh_aggregate!(name, from: nil, to: nil)
      ActiveRecord::Base.connection.execute(
        ActiveRecord::Base.sanitize_sql_array(
          ["CALL refresh_continuous_aggregate(?::regclass, ?, ?)", name.to_s, from, to]
        )
      )
    end
  end
end
