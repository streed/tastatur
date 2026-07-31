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
  def dashboard_public_id
    dashboard&.public_id
  end

  def dashboard_public_id=(value)
    self.dashboard = value.present? ? Dashboard.find_by(public_id: value) : nil
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
end
