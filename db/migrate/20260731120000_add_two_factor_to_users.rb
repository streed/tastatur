# Two-factor authentication by emailed code, opt-in per user.
#
# Email is the second factor rather than TOTP because it is the only one that
# works with no enrolment ceremony, no recovery-code storage, and no support
# burden when somebody replaces their phone. It is weaker than TOTP — an
# attacker who already owns the mailbox owns both factors — and the product
# says so on the settings screen rather than implying otherwise.
#
# WHY THE CODE IS A DIGEST. It is a credential, and a six-digit credential
# sitting in plaintext in a database backup is one `SELECT` away from being
# usable against anyone whose password has leaked. `has_secure_password
# :two_factor_code` gives it the same bcrypt treatment as a password, which
# also makes the 10^6 keyspace expensive to grind offline.
#
# `two_factor_code_expires_at` is stored rather than derived from
# `two_factor_code_sent_at` so the lifetime of a code that has already been
# issued cannot be changed retroactively by editing a constant.
class AddTwoFactorToUsers < ActiveRecord::Migration[8.1]
  def change
    change_table :users, bulk: true do |t|
      t.boolean  :two_factor_enabled, null: false, default: false
      t.string   :two_factor_code_digest
      t.datetime :two_factor_code_sent_at
      t.datetime :two_factor_code_expires_at

      # Guessing budget for the code currently outstanding, NOT for the account.
      # Devise's `failed_attempts` counts passwords and locks the account; this
      # counts codes and only invalidates the code, because locking somebody out
      # of an account for failing the step that proves they own it is a denial of
      # service anyone can trigger by knowing an email address.
      t.integer  :two_factor_failed_attempts, null: false, default: 0
    end
  end
end
