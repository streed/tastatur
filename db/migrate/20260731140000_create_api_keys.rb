# The credential a customer's own SERVER uses to talk to us.
#
# WHY THIS IS NOT THE SITE TOKEN, which already exists and is already sent on
# every request. The site token is public by construction — it sits in a script
# tag on every page of the customer's website, and §12 of CLAUDE.md is an
# argument for keeping it that way. Everything it authorizes is therefore
# deliberately harmless to forge: an anonymous pageview, rate-limited, refused if
# the hostname is wrong, and worth nothing to an attacker beyond polluting
# somebody's traffic chart.
#
# `/api/v1/identify` is a different kind of endpoint. It attaches a name to a
# visitor — an external user id, a Stripe customer id, a hashed email — and that
# association is the one thing in this product that cannot be reconstructed from
# anonymous data and cannot be undone by a salt rotation. A public token must
# never be able to write it, or anyone who views source on a customer's homepage
# can assert that visitor X is user Y.
#
# So identity and revenue writes need a real secret, held server-side, revocable
# on its own without disturbing measurement.
class CreateApiKeys < ActiveRecord::Migration[8.1]
  def change
    create_table :api_keys do |t|
      t.references :site, null: false, foreign_key: true

      # What it is for, in the customer's words: "production", "staging worker".
      # A key nobody can identify is a key nobody dares revoke.
      t.string :name, null: false

      # Every request on the API path does one lookup by prefix and then ONE
      # bcrypt comparison. Without a way to find the candidate row first,
      # authentication would have to bcrypt-compare the presented token against
      # every key in the table — which is not merely slow, it is a
      # denial-of-service endpoint: bcrypt is expensive on purpose, and an
      # unauthenticated caller would get to choose how many times we pay for it.
      #
      # So a key is `tk_<prefix>_<secret>`. The prefix identifies, the secret
      # authenticates; leaking the prefix reveals nothing, because it is not a
      # credential.
      t.string :token_prefix, null: false, limit: 12

      # bcrypt, via has_secure_password. NOT a SHA-256 digest, which is what
      # TrustedDevice uses and is right there — the difference is keyspace. A
      # trusted-device token is 32 bytes of SecureRandom with nothing to grind, so
      # a fast digest is a lookup key and bcrypt would buy nothing. This token is
      # also random, but it is pasted into deploy scripts, CI configuration and
      # .env files by hand, and those leak. bcrypt is what makes a leaked *digest*
      # worthless on its own.
      t.string :token_digest, null: false

      # The last four characters of the plaintext, shown in the list so somebody
      # holding three keys can tell which is which. Four characters of a 32-byte
      # secret is not a meaningful head start for anyone.
      t.string :last_four, null: false, limit: 4

      # Populated on use, at most once a minute — see ApiKey#note_use for why the
      # write is throttled rather than done on every request. This is what makes
      # "is anything still using this key?" answerable before revoking it.
      t.datetime :last_used_at

      # Revocation is a timestamp, not a deletion. A key that is destroyed takes
      # the answer to "when did this stop working, and was that before or after
      # the incident?" with it.
      t.datetime :revoked_at

      t.uuid :public_id, default: -> { "gen_random_uuid()" }, null: false

      t.timestamps
    end

    add_index :api_keys, :public_id, unique: true
    add_index :api_keys, %i[site_id name], unique: true

    # Unique across the whole table, not scoped to a site: the prefix is the only
    # thing a request presents before we know which site it belongs to, so it has
    # to resolve to exactly one row on its own.
    add_index :api_keys, :token_prefix, unique: true
  end
end
