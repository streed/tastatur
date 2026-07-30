# Retention defaults, aligned with the compliance position rather than a number
# somebody picked.
#
# WHAT WAS WRONG, in two parts.
#
# 1. The default was 400 days. That was arbitrary — roughly 13 months, chosen for
#    year-over-year margin — and more permissive than the compliance research
#    recommends for a data-minimisation product. The default is now 365 days
#    (12 months), with the configurable range capped at 25 months, which is
#    CNIL's stated ceiling for audience-measurement data.
#
# 2. The global TimescaleDB retention policy dropped chunks after 400 days while
#    Account#data_retention_days allowed up to five years. Anything above 400 was
#    therefore a lie: a customer setting 24-month retention lost their data at
#    400 days to a chunk drop, with nothing in the UI or the logs to say so. The
#    backstop is now set ABOVE the configurable maximum, so the per-account sweep
#    is always the thing that actually enforces retention and the chunk-drop
#    policy only catches data belonging to no account at all.
class AlignRetentionDefaults < ActiveRecord::Migration[8.1]
  # 25 months, CNIL's ceiling for audience-measurement data.
  MAX_RETENTION_DAYS = 760
  # Comfortably above the maximum any account can choose, so it never pre-empts
  # a legitimate per-account setting.
  BACKSTOP_DAYS = 790

  disable_ddl_transaction!

  def up
    change_column_default :accounts, :data_retention_days, from: 400, to: 365

    # Anything still sitting on the old arbitrary default moves to the new one.
    # An account that deliberately chose 400 is indistinguishable from one that
    # never touched it, and 365 is the safer reading of an untouched setting.
    execute "UPDATE accounts SET data_retention_days = 365 WHERE data_retention_days = 400"

    # Nobody can be left above the new ceiling.
    execute "UPDATE accounts SET data_retention_days = #{MAX_RETENTION_DAYS} " \
            "WHERE data_retention_days > #{MAX_RETENTION_DAYS}"

    reset_retention("events", BACKSTOP_DAYS)
    # These hold per-visitor and per-session rows, so they follow the raw-event
    # window rather than the longer aggregate one.
    reset_retention("visitor_days", BACKSTOP_DAYS)
    reset_retention("session_days", BACKSTOP_DAYS)
    # events_by_hour holds no identifiers of any kind and is what long-range
    # charts read, so it keeps its five years.
  end

  def down
    change_column_default :accounts, :data_retention_days, from: 365, to: 400
    %w[events visitor_days session_days].each { |relation| reset_retention(relation, 400) }
  end

  private

  # A retention policy cannot be altered in place; it is removed and re-added.
  def reset_retention(relation, days)
    execute "SELECT remove_retention_policy('#{relation}', if_exists => true);"
    execute "SELECT add_retention_policy('#{relation}', drop_after => INTERVAL '#{days} days', if_not_exists => true);"
  end
end
