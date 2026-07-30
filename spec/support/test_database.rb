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
