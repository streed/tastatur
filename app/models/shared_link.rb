class SharedLink < ApplicationRecord
  include PubliclyIdentified
  public_identifier

  SLUG_LENGTH = 24

  has_secure_password :password, validations: false

  belongs_to :site

  validates :name, presence: true, uniqueness: { scope: :site_id }, length: { maximum: 120 }
  validates :slug, presence: true, uniqueness: true, length: { is: SLUG_LENGTH }

  before_validation :assign_slug, on: :create

  scope :active, -> { where("expires_at IS NULL OR expires_at > ?", Time.current) }

  def expired?
    expires_at.present? && expires_at <= Time.current
  end

  def password_protected?
    password_digest.present?
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
end
