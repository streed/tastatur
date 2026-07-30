# A receipt proving one webhook event has already been handled.
#
# THE ROW MEANS "THIS WAS APPLIED", not "this was seen". That distinction is the
# whole design: `claim` inserts it before the work so a concurrent duplicate is
# turned away, and the caller destroys it again if the work fails — because a
# receipt left behind for work that did not happen makes Stripe's retry, the only
# thing that would have fixed it, look like a duplicate and get discarded.
class ProcessedWebhookEvent < ApplicationRecord
  STRIPE = "stripe".freeze

  # Stripe stops retrying after three days. A receipt older than that can no
  # longer be matched against anything and is only taking up space.
  RETENTION = 30.days

  validates :provider, presence: true
  validates :event_id, presence: true
  validates :event_type, presence: true

  # Returns the receipt, or nil when this event has already been handled.
  #
  # THE UNIQUE INDEX IS THE GUARANTEE, not this method's return value. An
  # `exists?` check followed by a create would let two concurrent deliveries of
  # the same event both pass the check — and concurrent delivery of a retry
  # alongside the original is precisely when duplicates arrive. Here the database
  # arbitrates: both insert, one raises RecordNotUnique, and that one stops.
  def self.claim(event_id:, event_type:, provider: STRIPE)
    create!(provider: provider, event_id: event_id, event_type: event_type, processed_at: Time.current)
  rescue ActiveRecord::RecordNotUnique
    nil
  end

  def self.prune!(before: RETENTION.ago)
    where(processed_at: ...before).delete_all
  end
end
