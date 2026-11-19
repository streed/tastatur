class CreateWaitlistSignups < ActiveRecord::Migration[8.1]
  # Somewhere to hold an address for a feature that is not built yet.
  #
  # This is the second place in the codebase that stores data about an
  # identifiable person, after the revenue tables, and unlike those it holds
  # people who are not customers and have no account. That is worth being strict
  # about, so the shape encodes the promises:
  #
  #   confirmed_at        NULL until the address proves it wants to be here, and
  #                       only a confirmed row is a list member. An unconfirmed
  #                       one is a claim somebody made about a mailbox they may
  #                       not own.
  #   confirmation_sent_at  the resend cooldown. Without it the form is a way to
  #                       have this instance mail a stranger on demand.
  #   token_digest        SHA-256 of a 32-byte token, never the token. Same
  #                       reasoning as TrustedDevice: there is no keyspace to
  #                       grind, so a digest is a lookup key, not a password.
  #
  # There is deliberately NO unsubscribed_at and no suppression list. Leaving
  # deletes the row — see Waitlist::Leave. A product that argues for storing as
  # little as possible does not get to keep an address specifically because
  # somebody asked it not to have one.
  def change
    create_table :waitlist_signups do |t|
      t.string :email, null: false
      t.string :feature, null: false, default: "revenue_attribution"

      # Which surface the person joined from. Not personal data and not
      # analytics about them — it answers "is the pricing page worth the space
      # this costs", which is otherwise unanswerable.
      t.string :source

      t.string   :token_digest, null: false
      t.datetime :confirmed_at
      t.datetime :confirmation_sent_at

      t.timestamps
    end

    # One row per address per feature. Addresses are normalised to lowercase by
    # the model, so this index is the real uniqueness guarantee rather than a
    # near-miss that lets Foo@ and foo@ both sit on the list.
    add_index :waitlist_signups, %i[feature email], unique: true
    add_index :waitlist_signups, :token_digest, unique: true

    # Pinned in three places like Account::PLANS, so a feature nobody added to
    # the catalogue cannot arrive through a form field.
    add_check_constraint :waitlist_signups, "feature IN ('revenue_attribution')",
                         name: "waitlist_signups_feature_check"
  end
end
