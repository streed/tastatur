class Goal < ApplicationRecord
  include PubliclyIdentified
  public_identifier

  KINDS = %w[pageview event].freeze
  MATCH_TYPES = %w[exact prefix wildcard].freeze

  belongs_to :site

  validates :name, presence: true, uniqueness: { scope: :site_id }, length: { maximum: 120 }
  validates :kind, inclusion: { in: KINDS }
  validates :match_type, inclusion: { in: MATCH_TYPES }
  validates :match_value, presence: true, length: { maximum: 500 }
  validates :currency, allow_blank: true, format: { with: /\A[A-Z]{3}\z/ }
  validates :default_value_cents, allow_nil: true, numericality: { greater_than_or_equal_to: 0 }

  validate :pageview_goals_match_a_path

  scope :pageviews, -> { where(kind: "pageview") }
  scope :events, -> { where(kind: "event") }

  def pageview?
    kind == "pageview"
  end

  # The column this goal matches against in the events hypertable.
  def match_column
    pageview? ? :path : :event_name
  end

  def matcher
    Analytics::PathPattern.new(match_value, match_type: match_type)
  end

  private

  def pageview_goals_match_a_path
    return unless pageview?
    return if match_value.blank? || match_value.start_with?("/")

    errors.add(:match_value, "must start with / for a pageview goal")
  end
end
