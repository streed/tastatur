# A user-composed report page: a named, ordered list of widgets over one
# site's data. The default dashboard (Analytics::Dashboard + sites#show) is
# untouched by this — a custom dashboard is a separate page with its own URL.
#
# NOTE ON THE NAME: `Analytics::Dashboard` is the service that composes the
# DEFAULT dashboard, and every reference to it is fully qualified. A bare
# `Dashboard` inside an `Analytics::` module would still resolve to the
# service; everywhere else it is this model.
class Dashboard < ApplicationRecord
  include PubliclyIdentified
  public_identifier

  MIN_WIDGETS = 1
  MAX_WIDGETS = 12
  MAX_PER_SITE = 20

  belongs_to :site
  has_many :dashboard_widgets, -> { order(:position) }, dependent: :destroy, inverse_of: :dashboard

  # dependent: :destroy, deliberately, and the direction matters. A share link
  # pointed at this dashboard was scoped to exactly what its widgets show;
  # letting it survive and fall back to the default dashboard would silently
  # WIDEN what an already-distributed URL exposes. Revoking the link is the
  # safe way for a deletion to fail a reader.
  has_many :shared_links, dependent: :destroy

  # No reject_if, unlike Funnel: every widget row is meaningful by construction
  # (kind and metric are selects that always submit a value), and the form
  # renders no spare blank rows for a blank-detection rule to ignore.
  accepts_nested_attributes_for :dashboard_widgets, allow_destroy: true

  # Positions come out contiguous regardless of which rows were removed, so
  # ordering never depends on the shape of the form. Same trick as
  # Funnel#renumber_steps, for the same reason.
  before_validation :renumber_widgets

  validates :name, presence: true, uniqueness: { scope: :site_id }, length: { maximum: 120 }
  validate :has_enough_widgets
  # `on: :create` only, mirroring Site#account_within_site_limit: a cap governs
  # adding, never keeping — renaming dashboard twenty-one must not 422 with a
  # message about limits.
  validate :site_within_dashboard_limit, on: :create

  scope :ordered, -> { order(:name) }

  private

  def renumber_widgets
    dashboard_widgets.reject(&:marked_for_destruction?)
                     .each_with_index { |widget, index| widget.position = index + 1 }
  end

  def has_enough_widgets
    live = dashboard_widgets.reject(&:marked_for_destruction?)
    return if live.size.between?(MIN_WIDGETS, MAX_WIDGETS)

    errors.add(:dashboard_widgets, "must have between #{MIN_WIDGETS} and #{MAX_WIDGETS} widgets")
  end

  def site_within_dashboard_limit
    return if site.nil?
    return if site.dashboards.count < MAX_PER_SITE

    errors.add(:base, "This site already has #{MAX_PER_SITE} dashboards. " \
                      "Delete one you no longer use first.")
  end
end
