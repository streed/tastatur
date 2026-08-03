class FunnelStep < ApplicationRecord
  # A step is satisfied by any ONE of its conditions. One is the ordinary case;
  # the cap is here for the same reason MAX_STEPS is — a step matching fifteen
  # things is a question nobody can read off the report, and every condition is
  # another OR branch in the funnel's chained CTE.
  MIN_CONDITIONS = 1
  MAX_CONDITIONS = 5

  belongs_to :funnel
  has_many :conditions, -> { order(:position) },
           class_name: "FunnelStepCondition", dependent: :destroy, inverse_of: :funnel_step

  # Same reasoning as Funnel's own nested attributes: the form renders spare
  # blank rows, and a blank one must be ignored rather than failing the save. A
  # condition row arrives with `kind` and `match_type` already set by its
  # selects, so the match value is the only thing that says it was filled in.
  accepts_nested_attributes_for :conditions,
                                allow_destroy: true,
                                reject_if: ->(attrs) { attrs["match_value"].blank? }

  before_validation :renumber_conditions

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
  validate :has_conditions

  def live_conditions
    conditions.reject(&:marked_for_destruction?)
  end

  # How the step reads on a report and in a list: "/pricing or event: Signup".
  def summary
    live_conditions.map(&:label).join(" or ")
  end

  private

  def renumber_conditions
    live_conditions.each_with_index { |condition, index| condition.position = index + 1 }
  end

  def has_conditions
    return if live_conditions.size.between?(MIN_CONDITIONS, MAX_CONDITIONS)

    errors.add(:conditions, "must match between #{MIN_CONDITIONS} and #{MAX_CONDITIONS} things")
  end
end
