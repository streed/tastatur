class Account < ApplicationRecord
  include PubliclyIdentified
  public_identifier

  PLANS = %w[free starter growth business self_hosted].freeze

  has_many :memberships, dependent: :destroy
  has_many :users, through: :memberships
  has_many :sites, dependent: :destroy

  validates :name, presence: true, length: { maximum: 120 }
  validates :slug, presence: true, uniqueness: true,
                   format: { with: /\A[a-z0-9][a-z0-9-]{1,48}[a-z0-9]\z/,
                             message: "must be lowercase letters, numbers and hyphens" }
  validates :plan, inclusion: { in: PLANS }
  validates :monthly_event_limit, numericality: { greater_than_or_equal_to: 0 }
  # Retention is a compliance control, so the range is bounded by what can be
  # defended rather than by what the column can hold.
  #
  # 25 months is CNIL's stated ceiling for audience-measurement data, and the
  # TimescaleDB backstop policy is set above it so a per-account choice is always
  # honoured. It previously allowed five years while the backstop dropped chunks
  # at 400 days, which meant any setting above 400 silently did not work.
  MAX_RETENTION_DAYS = 760
  DEFAULT_RETENTION_DAYS = 365

  # Offered in the UI. Discrete options rather than a free number field, because
  # this is a decision to be made deliberately, not a dial to nudge.
  RETENTION_OPTIONS = [
    ["3 months", 90],
    ["6 months", 180],
    ["12 months (recommended)", 365],
    ["24 months", 730],
    ["25 months (maximum)", MAX_RETENTION_DAYS]
  ].freeze

  validates :data_retention_days, numericality: { in: 1..MAX_RETENTION_DAYS }

  before_validation :generate_slug, on: :create

  def owner
    memberships.find_by(role: "owner")&.user
  end

  # On a self-hosted install there is no billing and no meaningful event cap.
  # Everything that would otherwise gate on plan asks this instead, so the
  # self-hosted path never depends on Stripe being configured.
  def billable?
    !Tastatur.self_hosted?
  end

  def event_limit
    billable? ? monthly_event_limit : Float::INFINITY
  end

  private

  def generate_slug
    return if slug.present? || name.blank?

    base = name.parameterize.presence || "account"
    base = base.first(48)
    candidate = base
    suffix = 1
    candidate = "#{base}-#{suffix += 1}" while Account.exists?(slug: candidate)
    self.slug = candidate
  end
end
