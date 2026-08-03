class Funnel < ApplicationRecord
  include PubliclyIdentified
  public_identifier

  MIN_STEPS = 2
  MAX_STEPS = 8

  belongs_to :site
  has_many :funnel_steps, -> { order(:position) }, dependent: :destroy, inverse_of: :funnel

  # Nullify, not destroy: deleting a funnel must not silently reshape a
  # dashboard someone curated. The widget stays, with no funnel, and renders an
  # explanatory empty state offering the dashboard's edit page. The FK's
  # on_delete: :nullify is the backstop; this keeps in-memory associations
  # agreeing with it.
  has_many :dashboard_widgets, dependent: :nullify

  # The form renders spare blank rows so a step can be added without any
  # JavaScript. Those rows have to be ignored when left untouched, or every save
  # fails on the blank one — which is what happened before this: submitting the
  # edit form produced "name can't be blank" for the spare row, so neither
  # adding a step NOR removing one could ever be saved.
  #
  # `:all_blank` is not enough, because the spare rows arrive with `kind`,
  # `match_type` and `position` already populated by the selects and the hidden
  # field. A row is only meaningfully filled in if it has a name or a match value.
  #
  # The match values now live one level further down, in the step's conditions,
  # so the emptiness test has to reach into them. Looking only at the step's own
  # attributes would call every spare row filled in — a step's own fields are
  # just a name — and the blank-row bug this exists to prevent would come back.
  accepts_nested_attributes_for :funnel_steps,
                                allow_destroy: true,
                                reject_if: ->(attrs) {
                                  attrs["name"].blank? &&
                                    Funnel.blank_conditions?(attrs["conditions_attributes"])
                                }

  # True when a step row carries no match value at all. Accepts what a form
  # actually submits — a hash keyed by row index — as well as a plain array, so
  # a caller building attributes in Ruby is not a special case.
  def self.blank_conditions?(rows)
    return true if rows.blank?

    (rows.respond_to?(:values) ? rows.values : rows).all? { |row| row["match_value"].blank? }
  end

  # Positions come out contiguous regardless of which rows were left blank or
  # ticked for removal, so ordering never depends on the shape of the form.
  before_validation :renumber_steps

  validates :name, presence: true, uniqueness: { scope: :site_id }, length: { maximum: 120 }
  validates :window_seconds, numericality: { in: 60..2_592_000 }
  validate :has_enough_steps

  scope :ordered, -> { order(:name) }

  def window
    window_seconds.seconds
  end

  # Without a persistent identifier a visitor cannot be followed past the daily
  # salt rotation, so a funnel window longer than a day cannot be honoured in
  # full. We allow it, but the UI says so plainly rather than quietly reporting
  # a number that undercounts.
  def window_exceeds_identity_lifetime?
    window_seconds > 1.day.to_i
  end

  private

  def renumber_steps
    funnel_steps.reject(&:marked_for_destruction?)
                .each_with_index { |step, index| step.position = index + 1 }
  end

  def has_enough_steps
    live = funnel_steps.reject(&:marked_for_destruction?)
    return if live.size.between?(MIN_STEPS, MAX_STEPS)

    errors.add(:funnel_steps, "must have between #{MIN_STEPS} and #{MAX_STEPS} steps")
  end
end
