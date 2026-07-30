class FunnelStep < ApplicationRecord
  KINDS = Goal::KINDS
  MATCH_TYPES = Goal::MATCH_TYPES

  belongs_to :funnel

  validates :name, presence: true, length: { maximum: 120 }
  # No uniqueness validation on position, deliberately.
  #
  # Position is not user input any more: Funnel#renumber_steps assigns 1..n over
  # the surviving steps before validation, so contiguity and uniqueness are
  # guaranteed by construction.
  #
  # A uniqueness validation here actively broke step removal. Validation runs
  # BEFORE Rails deletes the records marked for destruction, so removing step 2
  # of 3 renumbered step 3 to position 2 and the validator compared it against
  # the step 2 still sitting in the database. Every removal failed with a
  # position-taken error that named a row the user had just asked to delete.
  #
  # The unique index on (funnel_id, position) remains as the backstop. It does
  # not trip, because autosave destroys marked records before it saves the rest.
  validates :position, numericality: { greater_than: 0 }
  validates :kind, inclusion: { in: KINDS }
  validates :match_type, inclusion: { in: MATCH_TYPES }
  validates :match_value, presence: true, length: { maximum: 500 }

  def pageview?
    kind == "pageview"
  end

  def match_column
    pageview? ? :path : :event_name
  end

  def matcher
    Analytics::PathPattern.new(match_value, match_type: match_type)
  end
end
