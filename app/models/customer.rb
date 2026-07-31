# A person the customer's own application has told us about.
#
# See the CreateRevenueTables migration for why this table is identifiable while
# `events` is not, and why the two never join on `visitor_hash`.
class Customer < ApplicationRecord
  include PubliclyIdentified
  public_identifier

  # The channel vocabulary lives in Revenue::Channel, which is shared with the
  # events side of the report — see that module for why one spelling in two places
  # would split every row of the flagship screen in two. Re-exported here only so
  # existing call sites read naturally.
  DIRECT = Revenue::Channel::DIRECT
  NONE = Revenue::Channel::NONE
  PRE_INSTALL = Revenue::Channel::PRE_INSTALL

  belongs_to :site
  has_many :customer_subscriptions, dependent: :destroy
  has_many :revenue_events, dependent: :destroy

  validates :external_id, uniqueness: { scope: :site_id }, allow_nil: true
  validates :stripe_customer_id, uniqueness: { scope: :site_id }, allow_nil: true
  validate  :has_at_least_one_identifier

  scope :identified, -> { where.not(identified_at: nil) }
  scope :converted, -> { where.not(converted_at: nil) }
  scope :ordered, -> { order(current_mrr_cents: :desc, lifetime_revenue_cents: :desc, id: :asc) }

  # The three columns the attribution report groups by, with sentinels applied.
  # One method so that every consumer — the rollup, the customers screen, the
  # single-customer page — agrees about what "no campaign" is called.
  def attribution
    Revenue::Channel.normalize(
      source: attribution_source, medium: attribution_medium,
      campaign: attribution_campaign, referrer_host: attribution_referrer_host
    )
  end

  def converted? = converted_at.present?
  def churned? = churned_at.present?
  def identified? = identified_at.present?

  # Live means paying or about to. Mirrors Billing::SyncSubscription::ENTITLING_STATUSES
  # in spirit but is deliberately its own list: that one decides what WE are owed,
  # this one describes what our customer is owed, and a change to one is not
  # automatically right for the other.
  def active_subscriptions
    customer_subscriptions.where(status: CustomerSubscription::LIVE_STATUSES)
  end

  # SHA-256 of the normalised address, with no salt.
  #
  # Unsalted is deliberate and is explained in the migration: this value exists
  # solely to be compared against another hash of the same address, so a per-site
  # salt would make the only operation it supports impossible. It is a join key
  # that happens not to be readable, not a password.
  def self.hash_email(email)
    normalised = email.to_s.strip.downcase
    return nil if normalised.blank?

    Digest::SHA256.hexdigest(normalised)
  end

  private

  # A row with no external id, no Stripe id and no email hash is unreachable: it
  # can never be matched to anything again, so it can only ever accumulate. This
  # catches the bug that produces one — a webhook handler that creates before it
  # has decided what it is looking at.
  def has_at_least_one_identifier
    return if external_id.present? || stripe_customer_id.present? || email_hash.present?

    errors.add(:base, "needs an external id, a Stripe customer id or an email hash")
  end
end
