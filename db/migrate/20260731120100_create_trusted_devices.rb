# Devices that may skip the emailed code for a while.
#
# Without this, two-factor authentication costs a daily user an email round trip
# every single morning, and the predictable outcome is that they turn it off.
# The trade is explicit: thirty days on a browser that has already answered a
# challenge, revocable from the account page at any time, and revoked wholesale
# the moment two-factor is switched off or a device is lost.
#
# WHAT IS DELIBERATELY NOT STORED HERE.
#
# No user-agent, no IP address, no "Chrome on macOS · Berlin" label. Those are
# what every other product puts on this screen, and they are genuinely useful for
# spotting a session that is not yours — but this codebase tells customers it
# does not keep either one, and a device list is a poor place to start making an
# exception. `spec/privacy_invariants_spec.rb` fails a migration that adds such a
# column, on purpose. A device is identified to its owner by when it was trusted
# and when it was last used, which is enough to answer "is this the laptop I set
# up last Tuesday, or something else?".
#
# THE TOKEN IS HASHED WITH SHA-256, NOT BCRYPT, and the difference is not
# laziness. The cookie holds 32 bytes from SecureRandom, so there is no keyspace
# to grind and a slow hash buys nothing; what it would cost is the ability to
# find the row by digest, turning every request that presents a cookie into a
# full table scan of bcrypt comparisons.
class CreateTrustedDevices < ActiveRecord::Migration[8.1]
  def change
    create_table :trusted_devices do |t|
      t.references :user, null: false, foreign_key: true

      # Routed by public_id, never by id: the revoke button's URL would
      # otherwise disclose roughly how many devices exist across the instance.
      # See PubliclyIdentified.
      t.uuid :public_id, null: false, default: -> { "gen_random_uuid()" }

      # SHA-256 of the value in the cookie. The raw token is shown to the
      # browser once, at creation, and is not recoverable from here.
      t.string :token_digest, null: false

      t.datetime :expires_at, null: false
      t.datetime :last_used_at

      t.timestamps
    end

    add_index :trusted_devices, :public_id, unique: true
    add_index :trusted_devices, :token_digest, unique: true

    # The sweep that removes expired rows, and the account page's list.
    add_index :trusted_devices, %i[user_id expires_at]
  end
end
