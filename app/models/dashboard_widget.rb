# One widget on a custom dashboard: what to show (kind), how it is configured
# (metric / dimension / funnel / row_limit), and the filters the dashboard's
# author saved onto it.
#
# The per-kind configuration lives in real columns so each can carry its own
# CHECK constraint; only `filters` is jsonb, because its keys are
# Analytics::Filters' vocabulary plus customer-chosen property names, which no
# column set can enumerate. `normalize_filters` below is what keeps that one
# open-shaped column honest.
class DashboardWidget < ApplicationRecord
  include PubliclyIdentified
  public_identifier

  KINDS = %w[stat timeseries breakdown goals funnel].freeze

  # Widget vocabulary => Analytics::Summary::Metrics reader. The widget speaks
  # the dashboard's language ("visits"), Metrics speaks the query's
  # ("sessions"); this is the one translation table.
  METRIC_READERS = {
    "visitors" => :visitors,
    "pageviews" => :pageviews,
    "visits" => :sessions,
    "bounce_rate" => :bounce_rate,
    "visit_duration" => :avg_duration
  }.freeze
  METRICS = METRIC_READERS.keys.freeze

  METRIC_LABELS = {
    "visitors" => "Unique visitors",
    "pageviews" => "Pageviews",
    "visits" => "Visits",
    "bounce_rate" => "Bounce rate",
    "visit_duration" => "Visit duration"
  }.freeze

  # A breakdown widget's default title is the DEFAULT DASHBOARD'S name for the
  # same panel — "Top pages", not the filter vocabulary's "Page" — so the same
  # table is called the same thing on both screens. Dimensions the default
  # dashboard has no panel for fall back to their filter label.
  BREAKDOWN_TITLES = Analytics::Dashboard::PANELS
                     .to_h { |panel| [panel[:dimension], panel[:title]] }.freeze

  belongs_to :dashboard, inverse_of: :dashboard_widgets
  belongs_to :funnel, optional: true

  validates :kind, inclusion: { in: KINDS }
  # No uniqueness validation on position — Dashboard#renumber_widgets assigns
  # 1..n before validation, and FunnelStep documents why validating it anyway
  # breaks row removal. The unique index remains the backstop.
  validates :position, numericality: { greater_than: 0 }
  validates :title, length: { maximum: 120 }
  validates :metric, inclusion: { in: METRICS }, if: :stat?
  validates :dimension, inclusion: { in: Analytics::Filters::DIMENSIONS.keys }, if: -> { breakdown? && !property_dimension? }
  validate :property_dimension_is_well_formed, if: -> { breakdown? && property_dimension? }
  validates :row_limit, numericality: { in: 1..50 }

  # Presence is gated on the funnel CHANGING (or the row being new, or the kind
  # having just become "funnel"), not on the stored state — the same pattern as
  # Site's HOSTNAMES_CHANGED validations. A widget whose funnel was deleted has
  # funnel_id nullified by the FK; that is a legitimate row rendering an
  # explanatory empty state, and it must not block re-saving the rest of the
  # dashboard.
  validates :funnel, presence: true,
                     if: -> { funnel_widget? && (new_record? || funnel_id_changed? || kind_changed?) }
  validate :funnel_belongs_to_same_site, if: -> { funnel_id.present? }

  # The no-JS form submits every per-kind field regardless of the chosen kind
  # (the sections are merely hidden), so whatever the kind does not use is
  # cleared rather than stored — stored config must mean what the kind says.
  before_validation :store_property_dimension
  before_validation :clear_irrelevant_config
  before_validation :normalize_filters

  # The form's one extra choice on a breakdown widget: group by a custom event
  # property rather than a fixed dimension. Stored in `dimension` as
  # "props:<name>", the same spelling Analytics::Filters uses, so there is one
  # vocabulary and no new column. The key is the customer's own and cannot be
  # listed in a <select>, so the form offers PROPERTY_CHOICE and a text field.
  PROPERTY_CHOICE = "property".freeze

  attr_writer :property_name

  def property_dimension? = Analytics::Filters.property?(dimension)

  def property_name
    property_dimension? ? dimension.delete_prefix(Analytics::Filters::PROPERTY_PREFIX) : @property_name
  end

  def stat? = kind == "stat"
  def breakdown? = kind == "breakdown"
  def timeseries? = kind == "timeseries"
  def goals? = kind == "goals"
  def funnel_widget? = kind == "funnel"

  # The stored hash, as the value object every Analytics service takes. The
  # stored shape is exactly Filters#to_param's shape (flat dimensions plus a
  # nested "props" hash), so this round-trips without an adapter.
  def saved_filters
    Analytics::Filters.new(filters)
  end

  def display_title
    return title if title.present?

    case kind
    when "stat" then METRIC_LABELS.fetch(metric, "Stat")
    when "timeseries" then "Traffic"
    when "breakdown"
      return property_name if property_dimension?

      BREAKDOWN_TITLES[dimension] ||
        Analytics::Filters::HUMAN_LABELS.fetch(dimension) { dimension.to_s.humanize }
    when "goals" then "Goal conversions"
    when "funnel" then funnel&.name || "Funnel"
    end
  end

  # --- Routed-identifier plumbing for the form ------------------------------
  # The funnel <select> carries public_ids, never primary keys — §10's rule
  # applied to option values, so a posted integer has no path into this model.
  # Same-site enforcement lives in the validation rather than the setter, so
  # assignment order cannot matter.
  def funnel_public_id
    funnel&.public_id
  end

  def funnel_public_id=(value)
    self.funnel = value.present? ? Funnel.find_by(public_id: value) : nil
  end

  # --- Filters, as the form edits them --------------------------------------
  # The form edits the jsonb hash as a list of (dimension, value) pairs. These
  # are value objects rebuilt wholesale from every submission, not child
  # records — there is no id and no _destroy; a removed pair is simply absent.
  class FilterPair
    include ActiveModel::Model
    attr_accessor :dimension, :value
  end

  def filter_pairs
    saved_filters.applied.map { |dimension, value| FilterPair.new(dimension: dimension, value: value) }
  end

  # Rebuilds the whole hash from the submission. The form always includes a
  # blank sentinel pair, so this writer runs even when every real pair was
  # removed — otherwise deleting the last filter would silently keep it.
  # Analytics::Filters is the boundary: unknown dimension keys and blank
  # values are dropped there and can never reach the column.
  def filter_pairs_attributes=(attrs)
    pairs = attrs.to_h.values.filter_map do |pair|
      pair = pair.to_h.stringify_keys
      [pair["dimension"], pair["value"]] if pair["dimension"].present?
    end

    self.filters = Analytics::Filters.new(pairs.to_h).to_param
  end

  private

  def store_property_dimension
    return unless breakdown? && dimension == PROPERTY_CHOICE

    self.dimension = "#{Analytics::Filters::PROPERTY_PREFIX}#{@property_name.to_s.strip}"
  end

  # A property belongs to an event: `plan` on Signup and `plan` on Cancelled are
  # different facts, so a widget pooling them would show rows nobody can
  # interpret. The dashboard enforces the same thing by only offering property
  # panels once an event is chosen (Analytics::Dashboard#properties).
  def property_dimension_is_well_formed
    name = property_name.to_s
    if name.empty? || name.length > Analytics::Filters::MAX_PROPERTY_KEY
      errors.add(:property_name, "must be 1 to #{Analytics::Filters::MAX_PROPERTY_KEY} characters")
    elsif saved_filters["event"].blank?
      errors.add(:dimension, "needs an Event filter: a property belongs to one event")
    end
  end

  def clear_irrelevant_config
    self.metric = nil unless stat?
    self.dimension = nil unless breakdown?
    self.funnel = nil unless funnel_widget?
  end

  def normalize_filters
    self.filters = Analytics::Filters.new(filters).to_param
  end

  def funnel_belongs_to_same_site
    return if dashboard.nil?
    return if funnel.site_id == dashboard.site_id

    errors.add(:funnel, "must belong to the same site as the dashboard")
  end
end
