# An inbound Stripe Connect delivery, stored before it is interpreted.
#
# THE RECEIPT IS `processed_at`, NOT THE ROW. §14 states the rule for our own
# webhooks and it applies identically here: a row written on arrival and treated
# as the receipt makes Stripe's retry look like a duplicate, so a delivery that
# failed halfway through is discarded and the change is lost with nothing to show
# for it. The row means "received". Only `processed_at` means "applied".
class ConnectEvent < ApplicationRecord
  # Everything we act on. An event not on this list is answered 200 and never
  # stored — Stripe sends a great deal we have no use for, and storing all of it
  # would mean a customer's payload history growing without bound for no benefit.
  #
  # `checkout.session.completed` is what carries the attribution metadata the SDK
  # attaches, which is why it is here even though the subscription events that
  # follow it carry the money.
  HANDLED = %w[
    customer.created
    customer.updated
    customer.subscription.created
    customer.subscription.updated
    customer.subscription.deleted
    checkout.session.completed
    invoice.paid
    invoice.payment_failed
    charge.refunded
    charge.dispute.created
  ].freeze

  # How many times a failed event is retried by the sweep before it is left alone.
  # Not a column: the sweep counts by looking at `error` being present and the row
  # being old, because an event that has failed for a day is not going to start
  # working, and re-running it hourly forever hides the fact that it never will.
  RETRY_WINDOW = 24.hours

  belongs_to :site

  validates :stripe_event_id, presence: true, uniqueness: { scope: :site_id }
  validates :event_type, :occurred_at, presence: true

  scope :unprocessed, -> { where(processed_at: nil) }
  scope :retryable, -> { unprocessed.where(occurred_at: RETRY_WINDOW.ago..) }
  scope :ordered, -> { order(:occurred_at, :id) }

  def processed? = processed_at.present?
  def failed? = error.present? && !processed?

  # Applied successfully. Clears any earlier error so a row that failed once and
  # then succeeded does not read as broken forever.
  def mark_processed!
    update!(processed_at: Time.current, error: nil)
  end

  # NOT `update!` — a validation failure here would raise inside the rescue that
  # called it and replace the real exception with a useless one. `update_columns`
  # writes the diagnosis and nothing else.
  def mark_failed!(message)
    update_columns(error: message.to_s.truncate(1000), updated_at: Time.current)
  end

  # The event object as the handlers want it: symbol keys, all the way down.
  # `payload` comes back from jsonb with string keys, and a handler reaching for
  # `object[:id]` on a string-keyed hash gets nil rather than an error, which is
  # the kind of bug that reports zero revenue silently.
  def object
    payload.dig("data", "object")&.deep_symbolize_keys || {}
  end

  def stripe_account_id
    payload["account"]
  end
end
