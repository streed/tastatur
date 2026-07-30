# A browser that has already passed a two-factor challenge and may skip the next
# one until it expires.
#
# The row holds a digest; the raw token lives only in a cookie on the device it
# was issued to. That asymmetry is the whole design — a dump of this table lets
# nobody skip a challenge.
class TrustedDevice < ApplicationRecord
  include PubliclyIdentified
  public_identifier

  # Thirty days. Long enough that a daily user is not challenged twice in a
  # working week, short enough that a laptop sold, lost or handed on stops being
  # trusted without anyone having to remember to say so.
  TRUST_DURATION = 30.days

  # 32 bytes from SecureRandom. Nothing about it is derived from the user, so a
  # token discloses nothing even before it is hashed.
  TOKEN_BYTES = 32

  belongs_to :user

  validates :token_digest, presence: true, uniqueness: true
  validates :expires_at, presence: true

  scope :active, -> { where(expires_at: Time.current..) }
  scope :expired, -> { where(expires_at: ...Time.current) }
  scope :by_recency, -> { order(created_at: :desc) }

  # SHA-256, hex. Deterministic on purpose: this is a lookup key, not a password
  # digest. See the migration for why bcrypt would be the wrong tool here.
  def self.digest_for(token)
    OpenSSL::Digest::SHA256.hexdigest(token.to_s)
  end

  def self.new_token
    SecureRandom.urlsafe_base64(TOKEN_BYTES)
  end

  # The device this raw cookie value names, if it is still trusted.
  #
  # Returns nil for a blank token rather than digesting the empty string and
  # matching a row that happened to be created from one — which cannot happen
  # today, and is exactly the kind of thing that stops being true later.
  def self.find_active(token)
    return nil if token.blank?

    active.find_by(token_digest: digest_for(token))
  end

  def expired?
    expires_at <= Time.current
  end

  # Not `touch`, which would also bump updated_at and say nothing more. Skips
  # validations and callbacks because it runs on every sign-in that skips a
  # challenge and has nothing to validate.
  def record_use!
    self.class.where(id: id).update_all(last_used_at: Time.current)
  end
end
