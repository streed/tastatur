# The money table: one row per source/medium/campaign per day, carrying traffic
# and revenue side by side.
#
# WHY THIS IS A ROLLUP AND NOT A QUERY. Every other breakdown in this application
# scans raw events, deliberately (§12) — the aggregates carry no dimension
# columns because a wide one would be roughly one row per event. This report
# cannot be built that way, because it is a join across the two ingestion paths:
# `visitors` comes from the events hypertable, and everything to the right of it
# comes from `customers` and `revenue_events` in ordinary PostgreSQL. Doing that
# per page load means a hypertable scan joined against a customer table, per
# request, on the screen people leave open.
#
# WHY IT IS AN ORDINARY TABLE AND NOT A CONTINUOUS AGGREGATE. A continuous
# aggregate can only read one hypertable. This row is a join, so it is computed by
# a nightly job — which also means the same job is where "a customer signed up on
# the 3rd and paid on the 17th" is resolved to a single attributed row, and that
# is application logic rather than something SQL should be deciding.
#
# THE DATE IS THE SITE'S LOCAL DATE, not UTC. A day on every other screen in this
# product is a day in `site.timezone` (§13 explains why the salt rotates the same
# way), and a revenue table that disagreed with the traffic table about where
# Tuesday ends would make the two halves of the flagship screen not add up.
class CreateAttributionRollups < ActiveRecord::Migration[8.1]
  def change
    create_table :attribution_rollups do |t|
      t.references :site, null: false, foreign_key: true

      t.date :date, null: false

      # NOT NULL with a "(none)" sentinel rather than nullable.
      #
      # These three are the unique key, and in PostgreSQL `NULL` is distinct from
      # `NULL` in a unique index — so a nullable campaign would let the job insert
      # an unlimited number of "direct traffic" rows for the same day, each
      # believing it was the first. The upsert would never conflict and would
      # never update. Measured on the first draft of this table: eleven identical
      # rows for one day, and a chart that multiplied revenue by eleven.
      # The defaults match Revenue::Channel's sentinels exactly. "Direct" rather
      # than "(direct)" because the events pipeline already writes that spelling
      # into `referrer_source`, and a second spelling for the same channel splits
      # every direct-traffic row of this report in two — half the visitors on one,
      # all the money on the other.
      t.string :source, null: false, default: "Direct"
      t.string :medium, null: false, default: "(none)"
      t.string :campaign, null: false, default: "(none)"

      # --- Traffic, from the events hypertable ------------------------------
      t.integer :visitors, null: false, default: 0

      # --- The funnel, from customers ---------------------------------------
      # A signup is an identified customer. A trial is one whose subscription
      # entered `trialing`. A conversion is one who paid — `converted_at`.
      t.integer :signups, null: false, default: 0
      t.integer :trials, null: false, default: 0
      t.integer :conversions, null: false, default: 0

      # --- Money, from revenue_events ---------------------------------------
      # Split rather than netted, because "we grew $4k and churned $3k" and "we
      # grew $1k" are the same net number and completely different businesses.
      t.integer :new_mrr_cents, null: false, default: 0
      t.integer :expansion_mrr_cents, null: false, default: 0
      t.integer :contraction_mrr_cents, null: false, default: 0
      t.integer :churned_mrr_cents, null: false, default: 0
      t.integer :net_mrr_cents, null: false, default: 0

      # Every dollar ever collected from customers attributed to this row, as of
      # the night this was computed. NOT a sum over the date range — lifetime
      # value is a property of the customer, so summing this column across days
      # counts the same customer once per day. The report reads it from the most
      # recent row only, exactly as §8 forbids summing a distinct count across
      # buckets, and for the same reason.
      t.bigint :lifetime_revenue_cents, null: false, default: 0

      # Revenue this row could not convert into the site's base currency, because
      # no rate was available. Surfaced on the screen rather than folded into the
      # total: a report that silently treats an unconvertible €40 as £0 is worse
      # than one that says it could not convert it. See Revenue::Normalize.
      t.integer :unconverted_events, null: false, default: 0

      t.timestamps
    end

    add_index :attribution_rollups, %i[site_id date source medium campaign],
              unique: true, name: "idx_attr_rollups_unique"

    # The screen's own query: one site, a date range, ordered by money.
    add_index :attribution_rollups, %i[site_id date], name: "idx_attr_rollups_range"
  end
end
