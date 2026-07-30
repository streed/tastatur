# The table that makes webhook handling idempotent.
#
# Stripe delivers at least once, not exactly once. It retries for up to three
# days on any non-2xx, it can deliver the same event twice after a network blip,
# and the CLI replays events by hand during development. A handler that is not
# idempotent therefore does its work more than once — and the work here is
# "change which plan this account is on", so doing it twice out of order is how
# an account that upgraded ends up back on free.
#
# WHAT IS DELIBERATELY NOT STORED: the payload. A Stripe event body carries the
# customer's email, address, card brand and last four digits. None of that is
# needed to answer "have I already handled this?", and this codebase does not
# keep personal data it has no use for. If a payload needs inspecting, it is in
# the Stripe dashboard, which is the system of record for it.
#
# `provider` is not speculative generality — the same de-duplication is needed by
# any future callback source, and a table called processed_webhook_events with a
# hardcoded assumption that events are Stripe's would be renamed the first time
# that happened.
class CreateProcessedWebhookEvents < ActiveRecord::Migration[8.1]
  def change
    create_table :processed_webhook_events do |t|
      t.string :provider, null: false, default: "stripe"

      # Stripe's `evt_...` id. The unique index below is the actual idempotency
      # guarantee: two concurrent deliveries of the same event both try to insert,
      # one wins, and the loser gets RecordNotUnique and stops. A Ruby-level
      # `exists?` check would not survive that race, and concurrent delivery of a
      # retry alongside the original is exactly when it happens.
      t.string :event_id, null: false
      t.string :event_type, null: false

      # When we finished handling it, which is what makes the row a receipt rather
      # than a claim. Written after the handler succeeds.
      t.datetime :processed_at, null: false

      t.timestamps
    end

    add_index :processed_webhook_events, %i[provider event_id], unique: true

    # Pruning reads this. Stripe stops retrying after three days, so anything
    # older than the prune window cannot be redelivered and the row has no job
    # left to do.
    add_index :processed_webhook_events, :processed_at
  end
end
