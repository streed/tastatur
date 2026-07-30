class EnableTimescaledb < ActiveRecord::Migration[8.1]
  def up
    enable_extension "timescaledb" unless extension_enabled?("timescaledb")

    version = select_value("SELECT extversion FROM pg_extension WHERE extname = 'timescaledb'")
    say "TimescaleDB #{version} enabled"

    # 2.13 introduced the `by_range()` dimension builder and 2.18 renamed
    # compression to the columnstore API. Both are used by later migrations,
    # so fail loudly here rather than midway through creating hypertables.
    if Gem::Version.new(version) < Gem::Version.new("2.18")
      raise "Tastatur requires TimescaleDB >= 2.18 (found #{version}). " \
            "The columnstore and hypertable APIs used by later migrations do not exist in this version."
    end
  end

  def down
    # Intentionally not dropping the extension: it would cascade into every
    # hypertable and continuous aggregate in the database.
    raise ActiveRecord::IrreversibleMigration
  end
end
