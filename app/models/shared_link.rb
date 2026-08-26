class SharedLink < ApplicationRecord
  include PubliclyIdentified
  public_identifier

  SLUG_LENGTH = 24

  has_secure_password :password, validations: false

  belongs_to :site
  # NULL means "the default dashboard". When a dashboard is deleted its links
  # are destroyed with it (see Dashboard#shared_links) — never pointed back at
  # the default, which would widen what an already-distributed URL exposes.
  belongs_to :dashboard, optional: true

  validates :name, presence: true, uniqueness: { scope: :site_id }, length: { maximum: 120 }
  validates :slug, presence: true, uniqueness: true, length: { is: SLUG_LENGTH }
  validate :dashboard_belongs_to_same_site, if: -> { dashboard_id.present? }
  validate :named_dashboard_was_found

  before_validation :assign_slug, on: :create

  scope :active, -> { where("expires_at IS NULL OR expires_at > ?", Time.current) }

  def expired?
    expires_at.present? && expires_at <= Time.current
  end

  def password_protected?
    password_digest.present?
  end

  # The form's <select> carries public_ids, never primary keys — the same rule
  # as every routed identifier (see PubliclyIdentified). Same-site enforcement
  # lives in the validation rather than the setter, so assignment order cannot
  # matter.
  #
  # THE ATTEMPTED VALUE IS KEPT, and that is what closes a fail-open. The setter
  # resolves a public_id to a Dashboard or to nil, and nil is not an error
  # condition here — a NULL dashboard_id is the ordinary way of saying "the
  # default dashboard", which is the whole site. So an id that resolved to
  # nothing (a typo, a stale id, a dashboard deleted since the form was opened,
  # an id copied from another account) used to save cleanly as a link to
  # EVERYTHING, when what was asked for was a link to one curated dashboard.
  #
  # Nothing on the screen said so. The failure direction is the wrong way round
  # for the highest-risk surface in the application: this link goes to people
  # with no account at all, and the mistake widens what they see rather than
  # narrowing it. Compare the deliberate decision one line up — when a dashboard
  # is deleted its links are destroyed rather than re-pointed at the default,
  # explicitly so an already-distributed URL cannot grow.
  #
  # So the raw value is remembered and `named_dashboard_was_found` refuses the
  # save. "Nothing was named" and "something was named and is not there" become
  # different answers, which is the distinction that was missing.
  def dashboard_public_id
    @dashboard_public_id.presence || dashboard&.public_id
  end

  def dashboard_public_id=(value)
    @dashboard_public_id = value.is_a?(String) ? value.strip.presence : nil
    self.dashboard = @dashboard_public_id ? Dashboard.find_by(public_id: @dashboard_public_id) : nil
  end

  def record_view!
    # touch-style update: a shared dashboard can be polled frequently and this
    # must never become a write hotspot, so it deliberately skips validations
    # and callbacks.
    self.class.where(id: id).update_all(
      "view_count = view_count + 1, last_viewed_at = CURRENT_TIMESTAMP"
    )
  end

  private

  # This slug is the only thing protecting an unlisted dashboard, so it comes
  # from SecureRandom and is never derived from the site, name, or id.
  # 24 chars of urlsafe base64 ≈ 143 bits.
  def assign_slug
    self.slug ||= SecureRandom.urlsafe_base64(18).tr("-_", "xy").first(SLUG_LENGTH)
  end

  def dashboard_belongs_to_same_site
    return if dashboard.site_id == site_id

    errors.add(:base, "The dashboard must be one of this site's own dashboards.")
  end

  # A dashboard was named and could not be found. See dashboard_public_id= for
  # why this is an error rather than a silent fall back to the default.
  def named_dashboard_was_found
    return if @dashboard_public_id.blank?
    return if dashboard.present?

    errors.add(:base, "That dashboard no longer exists. Pick one from the list, or share the " \
                      "whole site's default dashboard instead.")
  end
end
