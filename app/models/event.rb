class Event < ApplicationRecord
  # The events hypertable has no primary key: TimescaleDB requires any unique
  # index to include the partitioning column, and there is no reason to give an
  # analytics event a durable identity. Tell ActiveRecord so it does not invent
  # an `id` column.
  self.primary_key = nil

  # With no primary key, ActiveRecord has nothing to order `first`/`last` by
  # and raises MissingRequiredOrderError. The partitioning column is the
  # natural ordering for a timeseries table anyway.
  self.implicit_order_column = "occurred_at"

  PAGEVIEW = "pageview".freeze
  DEVICE_TYPES = %w[desktop mobile tablet].freeze
  SCREEN_CLASSES = %w[xs sm md lg xl].freeze

  belongs_to :site

  # Writes go through Ingest::WriteBuffer, which issues batched multi-row
  # INSERTs. Creating events one at a time through ActiveRecord would be an
  # order of magnitude slower and is never what you want.
  def readonly?
    true
  end

  scope :pageviews, -> { where(event_name: PAGEVIEW) }
  scope :custom, -> { where.not(event_name: PAGEVIEW) }
  scope :for_site, ->(site) { where(site_id: site.id) }
  scope :between, ->(from, to) { where(occurred_at: from...to) }
  # Not `entries` — ActiveRecord::Relation already defines that method, and
  # Rails raises rather than letting a scope shadow it.
  scope :session_entries, -> { where(is_entry: true) }

  # Aggregate-backed reads. These are plain SQL views from ActiveRecord's point
  # of view; each is a TimescaleDB continuous aggregate. See
  # db/migrate/*_create_analytics_aggregates.rb for why only these three exist.
  class ByHour < ApplicationRecord
    self.table_name = "events_by_hour"
    self.primary_key = nil
    def readonly? = true
  end

  class VisitorDay < ApplicationRecord
    self.table_name = "visitor_days"
    self.primary_key = nil
    def readonly? = true
  end

  class SessionDay < ApplicationRecord
    self.table_name = "session_days"
    self.primary_key = nil
    def readonly? = true
  end
end
