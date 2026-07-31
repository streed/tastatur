# One thing that happened to money, as a signed ledger entry.
class RevenueEvent < ApplicationRecord
  # Kinds, and what each one means. Pinned here AND by a CHECK constraint in the
  # migration, exactly as Billing::Plan::KEYS is pinned three ways — a typo in a
  # kind string does not raise, it silently produces a row that every report
  # filters out.
  # --- Recurring revenue. `amount_cents` is an MRR DELTA. -------------------
  NEW = "new".freeze                    # first paid subscription for this customer
  EXPANSION = "expansion".freeze        # existing subscription worth more
  CONTRACTION = "contraction".freeze    # existing subscription worth less, still live
  CHURN = "churn".freeze                # subscription ended
  REACTIVATION = "reactivation".freeze  # previously churned customer paying again

  # --- Cash. `amount_cents` is what was actually charged or returned. --------
  PAYMENT = "payment".freeze            # an invoice was paid
  ONE_TIME = "one_time".freeze          # a charge with no subscription behind it
  REFUND = "refund".freeze
  DISPUTE = "dispute".freeze

  KINDS = [NEW, EXPANSION, CONTRACTION, CHURN, REACTIVATION,
           PAYMENT, ONE_TIME, REFUND, DISPUTE].freeze

  # THE TWO FAMILIES ARE NEVER SUMMED TOGETHER. An annual subscription writes a
  # `new` of 4,000 (its monthly worth) and a `payment` of 48,000 (what was
  # actually charged); adding those produces 52,000, which is not a number that
  # exists anywhere. Every consumer reads one list or the other — never `.all`.
  MRR_KINDS = [NEW, EXPANSION, CONTRACTION, CHURN, REACTIVATION].freeze
  CASH_KINDS = [PAYMENT, ONE_TIME, REFUND, DISPUTE].freeze

  belongs_to :site
  belongs_to :customer

  validates :kind, presence: true, inclusion: { in: KINDS }
  validates :amount_cents, presence: true
  validates :currency, presence: true, format: { with: /\A[A-Z]{3}\z/ }
  validates :occurred_at, presence: true

  scope :in_period, ->(range) { where(occurred_at: range) }
  scope :mrr_moving, -> { where(kind: MRR_KINDS) }

  # Whether this row's amount could be expressed in the site's base currency.
  # Distinguishable from zero on purpose — see Revenue::Normalize.
  def converted? = normalized_cents.present?
end
