# One precomputed row of the attribution report: a source/medium/campaign on a
# site-local day, with traffic and revenue side by side.
#
# Written only by Revenue::RollupAttribution. Read only by
# Revenue::AttributionReport. Nothing else should touch it — a second writer is
# how a rollup and its source data start disagreeing.
class AttributionRollup < ApplicationRecord
  belongs_to :site

  # The upsert's conflict target. Named here so the job and any future backfill
  # cannot drift from the index the migration created.
  CONFLICT_KEYS = %i[site_id date source medium campaign].freeze

  # Columns the upsert overwrites on conflict. Deliberately every value column: a
  # re-run for a day must REPLACE that day, not add to it. An `ON CONFLICT DO
  # NOTHING` here would make the nightly re-run of yesterday a no-op, so a day
  # computed while events were still arriving would stay half-counted forever.
  VALUE_COLUMNS = %i[
    visitors signups trials conversions
    new_mrr_cents expansion_mrr_cents contraction_mrr_cents churned_mrr_cents net_mrr_cents
    lifetime_revenue_cents unconverted_events
  ].freeze

  scope :in_period, ->(range) { where(date: range) }
  scope :by_revenue, -> { order(net_mrr_cents: :desc, visitors: :desc) }

  def channel
    [source, medium, campaign]
  end

  # "google / cpc / spring-sale", collapsed to just the parts that say anything.
  def channel_label
    parts = [source]
    parts << medium unless medium == Customer::NONE
    parts << campaign unless campaign == Customer::NONE
    parts.join(" / ")
  end
end
