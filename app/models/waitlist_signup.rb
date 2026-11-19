# An address waiting for a feature that has not shipped.
#
# Thin by the usual rule: issuing a token, sending the mail and deciding whether
# a resend is allowed all live in Waitlist::Join, because they are one operation
# with failure modes worth returning rather than raising.
class WaitlistSignup < ApplicationRecord
  # The catalogue. A form field cannot introduce a feature that is not here, and
  # neither can a console typo — the CHECK constraint in the migration says the
  # same thing to the database.
  FEATURES = %w[revenue_attribution].freeze

  # How long before the same address may be mailed again. The form is public and
  # takes an address the sender does not have to own, so without a cooldown it
  # is a button that delivers our mail to a stranger as fast as anybody likes.
  # Five minutes is long enough to be useless for that and short enough that
  # somebody who genuinely lost the email is not stuck.
  RESEND_INTERVAL = 5.minutes

  # An address that never confirms is one we were never given permission to
  # hold. It is swept rather than kept — see PurgeUnconfirmedWaitlistSignupsJob.
  PENDING_LIFETIME = 7.days

  # Rails normalises on assignment, so `find_by(email:)` normalises its argument
  # too and a lookup cannot miss a row because of case. That matters here: the
  # unique index is on the stored value, and a comparison that disagreed with it
  # would produce a duplicate-key error instead of a resend.
  normalizes :email, with: ->(email) { email.to_s.strip.downcase }

  validates :email, presence: true, length: { maximum: 320 },
                    format: { with: URI::MailTo::EMAIL_REGEXP, message: "does not look like an email address" },
                    uniqueness: { scope: :feature, case_sensitive: false }
  validates :feature, inclusion: { in: FEATURES }
  validates :token_digest, presence: true

  scope :confirmed, -> { where.not(confirmed_at: nil) }
  scope :pending, -> { where(confirmed_at: nil) }

  # The token is 32 random bytes and is shown once, in one email. SHA-256 rather
  # than bcrypt for the reason TrustedDevice gives: there is nothing to grind,
  # and this digest is a lookup key that has to be found in one indexed query.
  def self.digest(token)
    Digest::SHA256.hexdigest(token.to_s)
  end

  def self.find_by_token(token)
    return if token.blank?

    find_by(token_digest: digest(token))
  end

  def confirmed?
    confirmed_at.present?
  end

  def resend_allowed?
    confirmation_sent_at.nil? || confirmation_sent_at <= RESEND_INTERVAL.ago
  end
end
