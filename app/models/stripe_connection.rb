# A site's link to the customer's own Stripe account.
#
# HOLDS NO CREDENTIAL. The OAuth access token Stripe returns is used to confirm
# the grant and then discarded; every later API call is made with the platform's
# own secret key plus a `Stripe-Account` header, which reaches exactly the same
# data. See the migration, and Revenue::StripeAccount for the one place that
# builds those options.
class StripeConnection < ApplicationRecord
  include PubliclyIdentified
  public_identifier

  # What the Stripe App token exchange reports as `scope`, kept on the row as a
  # record of what was granted. The *_read-only-ness* no longer lives in a scope
  # string: a Stripe App declares a permission list in
  # stripe-app/stripe-app.json, Stripe's review approves it, and the customer
  # sees it item by item on the install screen. Every permission there ends in
  # `_read`, and keeping it that way is the point.
  #
  # There is no code path in this application that writes to a connected account,
  # and there must not be. An analytics tool holding write access to its
  # customers' payment processor is a liability with no matching benefit.
  SCOPE = "stripe_apps".freeze

  belongs_to :site
  has_many :connect_events, through: :site

  validates :stripe_account_id, presence: true
  validates :connected_at, presence: true
  validate  :one_live_connection_per_site, on: :create

  scope :live, -> { where(revoked_at: nil) }

  def live? = revoked_at.nil?
  def revoked? = !live?
  def backfilled? = backfilled_at.present?

  # Test-mode connections are accepted and then labelled everywhere they appear,
  # rather than refused. Refusing them would make the integration untestable by
  # the person installing it, which is when they most want to see it work.
  def test_mode? = !livemode

  def revoke!
    update!(revoked_at: Time.current)
  end

  private

  # The partial unique index is the real guarantee; this exists so the failure is
  # a validation error on a form rather than a RecordNotUnique 500.
  def one_live_connection_per_site
    return if site.nil?
    return unless StripeConnection.live.exists?(site_id: site_id)

    errors.add(:base, "#{site.domain} is already connected to a Stripe account. Disconnect it first.")
  end
end
